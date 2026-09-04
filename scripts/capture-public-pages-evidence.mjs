#!/usr/bin/env node

import { createHash, randomBytes } from "node:crypto";
import { promises as dns } from "node:dns";
import { constants as fsConstants } from "node:fs";
import {
  link,
  lstat,
  mkdir,
  open,
  realpath,
  unlink,
} from "node:fs/promises";
import https from "node:https";
import net from "node:net";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const DEFAULT_PROJECT_ROOT = path.resolve(path.dirname(SCRIPT_PATH), "..");
const CONFIG_RELATIVE_PATH = "ApplePlatforms/iOS/Config/Project.xcconfig";
const MAC_CONFIG_RELATIVE_PATH = "ApplePlatforms/macOS/Config/Project.xcconfig";
const DEFAULT_OUTPUT_RELATIVE_PATH = ".release/public-pages-evidence.json";
const DEFAULT_IDENTITY_LOCK_RELATIVE_PATH = ".release/identity.lock.json";
const DEFAULT_SUBMISSION_MANIFEST_RELATIVE_PATH = ".release/app-store-submission.json";
const FIXED_ALLOWED_ORIGIN = "https://kiki-lgtm-dot.github.io";
const MAX_RESPONSE_BYTES = 1024 * 1024;
const MAX_EVIDENCE_BYTES = 1024 * 1024;
const DEFAULT_TIMEOUT_MS = 10_000;
const DEFAULT_MAX_REDIRECTS = 5;
const DEFAULT_MAX_AGE_SECONDS = 24 * 60 * 60;
const FUTURE_TOLERANCE_SECONDS = 5 * 60;

class PublicPagesEvidenceError extends Error {
  constructor(message) {
    super(message);
    this.name = "PublicPagesEvidenceError";
  }
}

const fail = message => {
  throw new PublicPagesEvidenceError(message);
};

const sha256 = value => createHash("sha256").update(value).digest("hex");
const isObject = value => value !== null && typeof value === "object" && !Array.isArray(value);
const unixMode = stats => stats.mode & 0o777;
const slashPath = value => value.split(path.sep).join("/");

function exactKeys(value, expected, label) {
  if (!isObject(value)) fail(`${label} must be an object`);
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (JSON.stringify(actual) !== JSON.stringify(wanted)) {
    fail(`${label} has an unsupported schema`);
  }
}

function canonicalJSON(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (isObject(value)) {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

// JSON.parse accepts duplicate members using "last value wins". Binding files
// are release authorities, so parse them with a small strict RFC 8259 parser.
function parseStrictJSON(source, label) {
  let index = 0;
  let depth = 0;
  const parseFailure = message => fail(`${label} is not strict JSON (${message})`);
  const whitespace = () => {
    while (index < source.length && /[\x20\t\r\n]/u.test(source[index])) index += 1;
  };
  const parseString = () => {
    const start = index;
    if (source[index] !== '"') parseFailure("expected a string");
    index += 1;
    while (index < source.length) {
      const character = source[index];
      if (character === '"') {
        index += 1;
        try {
          return JSON.parse(source.slice(start, index));
        } catch {
          parseFailure("invalid string encoding");
        }
      }
      if (character === "\\") {
        index += 1;
        if (index >= source.length || !/["\\/bfnrtu]/u.test(source[index])) {
          parseFailure("invalid escape sequence");
        }
        if (source[index] === "u") {
          if (!/^[0-9a-fA-F]{4}$/u.test(source.slice(index + 1, index + 5))) {
            parseFailure("invalid Unicode escape");
          }
          index += 4;
        }
      } else if (character.charCodeAt(0) <= 0x1f) {
        parseFailure("unescaped control character");
      }
      index += 1;
    }
    parseFailure("unterminated string");
  };
  const parseValue = location => {
    whitespace();
    if (depth > 100) parseFailure("maximum nesting depth exceeded");
    const character = source[index];
    if (character === "{") return parseObject(location);
    if (character === "[") return parseArray(location);
    if (character === '"') return parseString();
    for (const [literal, parsed] of [["true", true], ["false", false], ["null", null]]) {
      if (source.startsWith(literal, index)) {
        index += literal.length;
        return parsed;
      }
    }
    const number = source.slice(index).match(/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/u);
    if (number) {
      index += number[0].length;
      const parsed = Number(number[0]);
      if (!Number.isFinite(parsed)) parseFailure("non-finite number");
      return parsed;
    }
    parseFailure("unexpected token");
  };
  const parseObject = location => {
    depth += 1;
    index += 1;
    whitespace();
    const result = Object.create(null);
    const keys = new Set();
    if (source[index] === "}") {
      index += 1;
      depth -= 1;
      return result;
    }
    while (index < source.length) {
      whitespace();
      const key = parseString();
      if (keys.has(key)) parseFailure(`duplicate member in ${location}`);
      keys.add(key);
      whitespace();
      if (source[index] !== ":") parseFailure("expected a colon");
      index += 1;
      result[key] = parseValue(`${location}.${key}`);
      whitespace();
      if (source[index] === "}") {
        index += 1;
        depth -= 1;
        return result;
      }
      if (source[index] !== ",") parseFailure("expected a comma or closing brace");
      index += 1;
    }
    parseFailure("unterminated object");
  };
  const parseArray = location => {
    depth += 1;
    index += 1;
    whitespace();
    const result = [];
    if (source[index] === "]") {
      index += 1;
      depth -= 1;
      return result;
    }
    while (index < source.length) {
      result.push(parseValue(`${location}[${result.length}]`));
      whitespace();
      if (source[index] === "]") {
        index += 1;
        depth -= 1;
        return result;
      }
      if (source[index] !== ",") parseFailure("expected a comma or closing bracket");
      index += 1;
    }
    parseFailure("unterminated array");
  };
  const parsed = parseValue("$");
  whitespace();
  if (index !== source.length) parseFailure("trailing content");
  return parsed;
}

function assertSafePathText(value, label) {
  if (typeof value !== "string" || value.length === 0 || value.includes("\0") || /[\r\n]/.test(value)) {
    fail(`${label} path is invalid`);
  }
  const segments = value.replaceAll("\\", "/").split("/");
  if (segments.includes(".") || segments.includes("..")) fail(`${label} path is not canonical`);
}

function assertInsideRoot(root, target, label) {
  const relative = path.relative(root, target);
  if (relative === "" || relative.startsWith(`..${path.sep}`) || relative === ".." || path.isAbsolute(relative)) {
    fail(`${label} must be a file below the repository root`);
  }
}

async function canonicalProjectRoot(projectRoot) {
  const requested = path.resolve(projectRoot);
  let resolved;
  try {
    resolved = await realpath(requested);
  } catch {
    fail("repository root is unavailable");
  }
  if (resolved !== requested) fail("repository root must not be reached through a symlink");
  const stats = await lstat(resolved);
  if (!stats.isDirectory() || stats.isSymbolicLink()) fail("repository root is not a regular directory");
  return resolved;
}

async function existingRepositoryFile(root, inputPath, label) {
  assertSafePathText(inputPath, label);
  const target = path.isAbsolute(inputPath) ? path.resolve(inputPath) : path.resolve(root, inputPath);
  assertInsideRoot(root, target, label);
  let resolved;
  let stats;
  try {
    [resolved, stats] = await Promise.all([realpath(target), lstat(target)]);
  } catch {
    fail(`${label} is missing`);
  }
  if (resolved !== target || stats.isSymbolicLink() || !stats.isFile()) {
    fail(`${label} must be a regular file without symlink traversal`);
  }
  return {
    absolutePath: target,
    relativePath: slashPath(path.relative(root, target)),
  };
}

async function readStableFile(filePath, maximumBytes, label) {
  let handle;
  try {
    handle = await open(filePath, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
  } catch {
    fail(`${label} could not be opened safely`);
  }
  try {
    const before = await handle.stat();
    if (!before.isFile() || before.size <= 0 || before.size > maximumBytes) {
      fail(`${label} has an invalid size`);
    }
    const body = await handle.readFile();
    const after = await handle.stat();
    if (before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size ||
        before.mtimeMs !== after.mtimeMs || body.length !== after.size) {
      fail(`${label} changed while it was being read`);
    }
    return { body, stats: after, sha256: sha256(body) };
  } finally {
    await handle.close().catch(() => {});
  }
}

async function ensureSafeOutputParent(root, parent) {
  assertInsideRoot(root, path.join(parent, ".evidence-output"), "output");
  const relative = path.relative(root, parent);
  let current = root;
  for (const component of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    try {
      const stats = await lstat(current);
      if (stats.isSymbolicLink() || !stats.isDirectory()) {
        fail("output path must not traverse a symlink or non-directory");
      }
    } catch (error) {
      if (error instanceof PublicPagesEvidenceError) throw error;
      if (error?.code !== "ENOENT") fail("output parent could not be inspected");
      try {
        await mkdir(current, { mode: 0o700 });
      } catch (mkdirError) {
        if (mkdirError?.code !== "EEXIST") fail("output parent could not be created");
      }
      const created = await lstat(current);
      if (created.isSymbolicLink() || !created.isDirectory()) {
        fail("output path became unsafe while it was created");
      }
    }
  }
  let resolved;
  try {
    resolved = await realpath(parent);
  } catch {
    fail("output parent is unavailable");
  }
  if (resolved !== parent) fail("output path must not traverse a symlink parent");
}

async function resolveNewOutput(root, inputPath) {
  assertSafePathText(inputPath, "output");
  const target = path.isAbsolute(inputPath) ? path.resolve(inputPath) : path.resolve(root, inputPath);
  assertInsideRoot(root, target, "output");
  const parent = path.dirname(target);
  await ensureSafeOutputParent(root, parent);
  try {
    await lstat(target);
    fail("refusing to overwrite an existing public-pages evidence file");
  } catch (error) {
    if (error instanceof PublicPagesEvidenceError) throw error;
    if (error?.code !== "ENOENT") fail("output path could not be inspected");
  }
  return {
    absolutePath: target,
    relativePath: slashPath(path.relative(root, target)),
  };
}

async function publishAtomicReadOnly(output, bytes) {
  const parent = path.dirname(output.absolutePath);
  const temporary = path.join(
    parent,
    `.${path.basename(output.absolutePath)}.capture-${process.pid}-${randomBytes(8).toString("hex")}`,
  );
  let handle;
  let published = false;
  let temporaryStats;
  try {
    handle = await open(
      temporary,
      fsConstants.O_WRONLY | fsConstants.O_CREAT | fsConstants.O_EXCL | fsConstants.O_NOFOLLOW,
      0o600,
    );
    await handle.writeFile(bytes);
    await handle.sync();
    await handle.chmod(0o444);
    temporaryStats = await handle.stat();
    if (!temporaryStats.isFile() || temporaryStats.size !== bytes.length || unixMode(temporaryStats) !== 0o444) {
      fail("temporary public-pages evidence could not be sealed");
    }
    await handle.close();
    handle = undefined;
    try {
      await link(temporary, output.absolutePath);
      published = true;
    } catch (error) {
      if (error?.code === "EEXIST") fail("refusing to overwrite an existing public-pages evidence file");
      fail("public-pages evidence could not be atomically published");
    }
    const finalStats = await lstat(output.absolutePath);
    if (!finalStats.isFile() || finalStats.isSymbolicLink() || unixMode(finalStats) !== 0o444 ||
        finalStats.dev !== temporaryStats.dev || finalStats.ino !== temporaryStats.ino ||
        finalStats.size !== bytes.length) {
      fail("published public-pages evidence failed its integrity check");
    }
    await unlink(temporary);
    return sha256(bytes);
  } catch (error) {
    if (published) {
      try {
        const finalStats = await lstat(output.absolutePath);
        if (temporaryStats && finalStats.dev === temporaryStats.dev && finalStats.ino === temporaryStats.ino) {
          await unlink(output.absolutePath);
        }
      } catch {}
    }
    throw error;
  } finally {
    await handle?.close().catch(() => {});
    await unlink(temporary).catch(() => {});
  }
}

function xcconfigResolver(source) {
  const values = new Map();
  for (const rawLine of source.split(/\r?\n/u)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("//") || line.startsWith("#")) continue;
    const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/u);
    if (!match) continue;
    if (values.has(match[1])) fail("release xcconfig contains a duplicate assignment");
    values.set(match[1], match[2]);
  }
  const resolving = new Set();
  const resolveValue = key => {
    if (!values.has(key)) fail("release xcconfig is missing a required public-page setting");
    if (resolving.has(key)) fail("release xcconfig contains a recursive setting");
    resolving.add(key);
    const result = values.get(key).replace(/\$\(([A-Za-z_][A-Za-z0-9_]*)\)/gu, (_token, nested) => resolveValue(nested));
    resolving.delete(key);
    if (/\$\([^)]+\)/u.test(result)) fail("release xcconfig contains an unresolved public-page setting");
    return result.trim();
  };
  return resolveValue;
}

async function loadConfiguration(root) {
  const iosConfig = await existingRepositoryFile(root, CONFIG_RELATIVE_PATH, "iOS release xcconfig");
  const macConfig = await existingRepositoryFile(root, MAC_CONFIG_RELATIVE_PATH, "macOS release xcconfig");
  const [{ body: iosBody }, { body: macBody }] = await Promise.all([
    readStableFile(iosConfig.absolutePath, MAX_EVIDENCE_BYTES, "iOS release xcconfig"),
    readStableFile(macConfig.absolutePath, MAX_EVIDENCE_BYTES, "macOS release xcconfig"),
  ]);
  let iosSource;
  let macSource;
  try {
    const decoder = new TextDecoder("utf-8", { fatal: true });
    iosSource = decoder.decode(iosBody);
    macSource = new TextDecoder("utf-8", { fatal: true }).decode(macBody);
  } catch {
    fail("release xcconfig is not valid UTF-8");
  }
  const iosValue = xcconfigResolver(iosSource);
  const macValue = xcconfigResolver(macSource);
  const configuration = {
    productName: iosValue("AGENT_ISLAND_DISPLAY_NAME"),
    privacy: iosValue("AGENT_ISLAND_PRIVACY_POLICY_URL"),
    support: iosValue("AGENT_ISLAND_SUPPORT_URL"),
    teamIdentifier: iosValue("AGENT_ISLAND_DEVELOPMENT_TEAM"),
    iCloudContainerIdentifier: iosValue("AGENT_ISLAND_ICLOUD_CONTAINER_ID"),
    cloudKit: {
      recordType: iosValue("AGENT_ISLAND_CLOUDKIT_RECORD_TYPE"),
      recordName: iosValue("AGENT_ISLAND_CLOUDKIT_RECORD_NAME"),
      payloadField: iosValue("AGENT_ISLAND_CLOUDKIT_PAYLOAD_FIELD"),
    },
    macos: {
      bundleIdentifier: macValue("AGENT_ISLAND_MAC_APP_BUNDLE_ID"),
      version: macValue("MARKETING_VERSION"),
      build: macValue("CURRENT_PROJECT_VERSION"),
    },
    ios: {
      bundleIdentifier: iosValue("AGENT_ISLAND_APP_BUNDLE_ID"),
      widgetBundleIdentifier: iosValue("AGENT_ISLAND_WIDGET_BUNDLE_ID"),
      version: iosValue("MARKETING_VERSION"),
      build: iosValue("CURRENT_PROJECT_VERSION"),
    },
  };
  if (configuration.productName.length < 2 || configuration.productName.length > 100 ||
      /[\u0000-\u001f\u007f]/u.test(configuration.productName)) {
    fail("configured product name is invalid");
  }
  return configuration;
}

function assertPublicHostname(hostname, label) {
  const normalized = hostname.replace(/^\[|\]$/gu, "").toLowerCase();
  if (!normalized || net.isIP(normalized) !== 0 || !normalized.includes(".") ||
      normalized === "localhost" || normalized.endsWith(".localhost") ||
      normalized.endsWith(".local") || normalized.endsWith(".internal") ||
      normalized.endsWith(".home.arpa") || normalized.endsWith(".test") ||
      normalized.endsWith(".example") || normalized.endsWith(".invalid")) {
    fail(`${label} must use a public DNS hostname`);
  }
}

function parseSafeHTTPSURL(value, label) {
  let url;
  try {
    url = new URL(value);
  } catch {
    fail(`${label} is not a valid absolute URL`);
  }
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) {
    fail(`${label} must be credential-free HTTPS without a query or fragment`);
  }
  assertPublicHostname(url.hostname, label);
  return url;
}

function normalizeAllowedOrigins(explicitOrigins = []) {
  if (!Array.isArray(explicitOrigins)) fail("allowed origins must be an array");
  const origins = new Set([FIXED_ALLOWED_ORIGIN]);
  for (const value of explicitOrigins) {
    const url = parseSafeHTTPSURL(value, "allowed origin");
    if (url.pathname !== "/" || url.search) fail("allowed origin must contain only an HTTPS origin");
    origins.add(url.origin);
  }
  return [...origins].sort();
}

function validateConfiguredURLs(configuration, allowedOrigins) {
  const result = {};
  for (const kind of ["privacy", "support"]) {
    const url = parseSafeHTTPSURL(configuration[kind], `configured ${kind} URL`);
    if (!allowedOrigins.includes(url.origin)) {
      fail(`configured ${kind} URL origin is not allowlisted`);
    }
    result[kind] = url.href;
  }
  if (result.privacy === result.support) {
    fail("configured privacy and support URLs must be different");
  }
  return result;
}

function ipv4IsPublic(address) {
  const octets = address.split(".").map(Number);
  if (octets.length !== 4 || octets.some(value => !Number.isInteger(value) || value < 0 || value > 255)) return false;
  const [a, b] = octets;
  if (a === 0 || a === 10 || a === 127 || a >= 224) return false;
  if (a === 100 && b >= 64 && b <= 127) return false;
  if (a === 169 && b === 254) return false;
  if (a === 172 && b >= 16 && b <= 31) return false;
  if (a === 192 && (b === 0 || b === 168)) return false;
  if (a === 192 && b === 88) return false;
  if (a === 192 && b === 51) return false;
  if (a === 198 && (b === 18 || b === 19 || b === 51)) return false;
  if (a === 203 && b === 0) return false;
  return true;
}

function ipv6Value(address) {
  if (typeof address !== "string" || address.includes("%")) return null;
  let source = address.toLowerCase();
  const ipv4Match = source.match(/(?:^|:)([0-9]{1,3}(?:\.[0-9]{1,3}){3})$/u);
  if (ipv4Match) {
    if (net.isIP(ipv4Match[1]) !== 4) return null;
    const octets = ipv4Match[1].split(".").map(Number);
    const replacement = `${((octets[0] << 8) | octets[1]).toString(16)}:${((octets[2] << 8) | octets[3]).toString(16)}`;
    source = source.slice(0, source.length - ipv4Match[1].length) + replacement;
  }
  if ((source.match(/::/gu) ?? []).length > 1) return null;
  const [leftText, rightText] = source.split("::");
  const left = leftText ? leftText.split(":") : [];
  const right = rightText ? rightText.split(":") : [];
  if (left.some(part => !/^[0-9a-f]{1,4}$/u.test(part)) || right.some(part => !/^[0-9a-f]{1,4}$/u.test(part))) {
    return null;
  }
  const omitted = 8 - left.length - right.length;
  if ((source.includes("::") && omitted < 1) || (!source.includes("::") && omitted !== 0)) return null;
  const groups = [...left, ...Array(omitted).fill("0"), ...right];
  if (groups.length !== 8) return null;
  return groups.reduce((result, group) => (result << 16n) | BigInt(`0x${group}`), 0n);
}

function ipv6Prefix(value, prefix, bits) {
  const shift = 128n - BigInt(bits);
  return (value >> shift) === (prefix >> shift);
}

function embeddedIPv4(value, shift = 0n) {
  const numeric = Number((value >> shift) & 0xffff_ffffn);
  return `${numeric >>> 24}.${(numeric >>> 16) & 255}.${(numeric >>> 8) & 255}.${numeric & 255}`;
}

export function ipAddressIsPublic(address) {
  const family = net.isIP(address);
  if (family === 4) return ipv4IsPublic(address);
  if (family !== 6) return false;
  const value = ipv6Value(address);
  if (value === null || value === 0n || value === 1n) return false;
  const at = source => ipv6Value(source);
  const mapped = at("::ffff:0:0");
  const nat64 = at("64:ff9b::");
  const nat64Local = at("64:ff9b:1::");
  const sixToFour = at("2002::");
  if (ipv6Prefix(value, mapped, 96)) return ipv4IsPublic(embeddedIPv4(value));
  if (ipv6Prefix(value, nat64Local, 48)) return false;
  if (ipv6Prefix(value, nat64, 96)) return ipv4IsPublic(embeddedIPv4(value));
  if (ipv6Prefix(value, sixToFour, 16)) return ipv4IsPublic(embeddedIPv4(value, 80n));
  const denied = [
    ["100::", 64],
    ["2001::", 32],
    ["2001:2::", 48],
    ["2001:10::", 28],
    ["2001:20::", 28],
    ["2001:db8::", 32],
    ["fc00::", 7],
    ["fe80::", 10],
    ["fec0::", 10],
    ["ff00::", 8],
  ];
  if (denied.some(([prefix, bits]) => ipv6Prefix(value, at(prefix), bits))) return false;
  // Other ranges are not accepted merely because a platform parser knows
  // them. Native globally-routable unicast is currently 2000::/3.
  return ipv6Prefix(value, at("2000::"), 3);
}

async function publicAddressesFor(hostname) {
  let addresses;
  try {
    addresses = await dns.lookup(hostname, { all: true, verbatim: true });
  } catch {
    fail("HTTPS destination could not be resolved");
  }
  if (!addresses.length || addresses.some(({ address }) => !ipAddressIsPublic(address))) {
    fail("HTTPS destination did not resolve exclusively to public addresses");
  }
  return addresses;
}

export async function productionTransport(url, { signal, maxBytes }) {
  const addresses = await publicAddressesFor(url.hostname);
  if (signal.aborted) fail("HTTPS request timed out");
  const selected = addresses[0];
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      callback(value);
    };
    const request = https.request(url, {
      method: "GET",
      signal,
      family: selected.family,
      autoSelectFamily: false,
      lookup: (_hostname, _options, callback) => callback(null, selected.address, selected.family),
      headers: {
        Accept: "text/html,application/xhtml+xml;q=0.9",
        "Accept-Encoding": "identity",
        "Cache-Control": "no-cache",
        "User-Agent": "AgentIsland-Public-Pages-Evidence/1",
      },
    }, response => {
      const chunks = [];
      let size = 0;
      const lengthHeader = Array.isArray(response.headers["content-length"])
        ? response.headers["content-length"][0]
        : response.headers["content-length"];
      if (lengthHeader !== undefined && (!/^\d+$/u.test(lengthHeader) || Number(lengthHeader) > maxBytes)) {
        response.destroy();
        finish(reject, new PublicPagesEvidenceError("HTTPS response exceeds the 1 MiB limit"));
        return;
      }
      response.on("data", chunk => {
        size += chunk.length;
        if (size > maxBytes) {
          response.destroy();
          finish(reject, new PublicPagesEvidenceError("HTTPS response exceeds the 1 MiB limit"));
          return;
        }
        chunks.push(chunk);
      });
      response.once("end", () => finish(resolve, {
        status: response.statusCode,
        headers: response.headers,
        body: Buffer.concat(chunks),
      }));
      response.once("error", () => finish(reject, new PublicPagesEvidenceError("HTTPS response failed")));
    });
    request.once("socket", socket => {
      const validateConnectedAddress = () => {
        if (!ipAddressIsPublic(socket.remoteAddress ?? "")) {
          request.destroy(new PublicPagesEvidenceError("HTTPS connection reached a non-public address"));
        }
      };
      if (socket.connecting) socket.once("secureConnect", validateConnectedAddress);
      else validateConnectedAddress();
    });
    request.once("error", error => finish(
      reject,
      error instanceof PublicPagesEvidenceError
        ? error
        : new PublicPagesEvidenceError("HTTPS request failed"),
    ));
    request.end();
  });
}

function normalizedHeaders(headers) {
  const result = new Map();
  if (headers instanceof Map) {
    for (const [key, value] of headers) result.set(String(key).toLowerCase(), value);
  } else if (typeof headers?.entries === "function") {
    for (const [key, value] of headers.entries()) result.set(String(key).toLowerCase(), value);
  } else if (isObject(headers)) {
    for (const [key, value] of Object.entries(headers)) result.set(key.toLowerCase(), value);
  } else {
    fail("HTTPS response headers are invalid");
  }
  return result;
}

function singleHeader(headers, name) {
  const value = headers.get(name);
  if (value === undefined) return undefined;
  if (Array.isArray(value)) {
    if (value.length !== 1) fail(`HTTPS response ${name} header is ambiguous`);
    return String(value[0]);
  }
  return String(value);
}

async function invokeTransport(transport, url, kind, timeoutMs, deadline) {
  const remaining = Math.max(0, deadline - Date.now());
  if (remaining === 0) fail(`${kind} page request timed out`);
  const controller = new AbortController();
  let timer;
  try {
    const timeout = new Promise((_resolve, reject) => {
      timer = setTimeout(() => {
        controller.abort();
        reject(new PublicPagesEvidenceError(`${kind} page request timed out`));
      }, Math.min(timeoutMs, remaining));
    });
    return await Promise.race([
      Promise.resolve().then(() => transport(url, {
        signal: controller.signal,
        maxBytes: MAX_RESPONSE_BYTES,
      })),
      timeout,
    ]);
  } catch (error) {
    if (error instanceof PublicPagesEvidenceError) throw error;
    fail(`${kind} page HTTPS request failed`);
  } finally {
    clearTimeout(timer);
  }
}

function responseBodyBytes(value) {
  if (typeof value === "string") return Buffer.from(value, "utf8");
  if (Buffer.isBuffer(value)) return value;
  if (value instanceof Uint8Array) return Buffer.from(value);
  fail("HTTPS response body is invalid");
}

function checkedAtValue(clock) {
  let value;
  try {
    value = clock();
  } catch {
    fail("capture clock failed");
  }
  const date = value instanceof Date ? value : new Date(value);
  if (!Number.isFinite(date.getTime())) fail("capture clock is invalid");
  return date.toISOString().replace(/\.\d{3}Z$/u, "Z");
}

function decodeHTMLEntities(value) {
  const named = new Map([
    ["amp", "&"], ["apos", "'"], ["gt", ">"], ["lt", "<"], ["quot", '"'], ["nbsp", " "],
  ]);
  return value.replace(/&(?:#([0-9]{1,7})|#x([0-9a-f]{1,6})|([a-z]+));/giu, (token, decimal, hexadecimal, name) => {
    if (name) return named.get(name.toLowerCase()) ?? token;
    const codePoint = Number.parseInt(decimal ?? hexadecimal, decimal ? 10 : 16);
    if (!Number.isInteger(codePoint) || codePoint < 1 || codePoint > 0x10ffff ||
        (codePoint >= 0xd800 && codePoint <= 0xdfff)) return token;
    return String.fromCodePoint(codePoint);
  });
}

function parsedHTMLAttributes(source) {
  const attributes = new Map();
  const pattern = /([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/gu;
  for (const match of source.matchAll(pattern)) {
    const name = match[1].toLowerCase();
    if (attributes.has(name)) continue;
    attributes.set(name, decodeHTMLEntities(match[2] ?? match[3] ?? match[4] ?? ""));
  }
  return attributes;
}

const VOID_HTML_ELEMENTS = new Set([
  "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
  "param", "source", "track", "wbr",
]);
const NON_RENDERED_HTML_ELEMENTS = new Set([
  "head", "script", "style", "template", "title", "noscript",
]);

function inlineStyleHidesElement(style) {
  if (typeof style !== "string" || style.length === 0) return false;
  const withoutComments = style.replace(/\/\*[\s\S]*?\*\//gu, " ");
  // An unterminated CSS comment makes the declaration boundary ambiguous. A
  // static HTML renderability screen must not turn that ambiguity into a
  // positive visible-structure claim.
  if (withoutComments.includes("/*") || withoutComments.includes("*/")) return true;
  return withoutComments.split(";").some(declaration => {
    const colon = declaration.indexOf(":");
    if (colon < 0) return false;
    const property = declaration.slice(0, colon).trim().toLowerCase();
    const value = declaration.slice(colon + 1)
      .replace(/!\s*important\s*$/iu, "")
      .trim()
      .toLowerCase();
    return (property === "display" && value === "none") ||
      (property === "visibility" && (value === "hidden" || value === "collapse"));
  });
}

function elementIsHidden(name, attributes) {
  if (NON_RENDERED_HTML_ELEMENTS.has(name)) return true;
  if (attributes.has("hidden")) return true;
  if ((attributes.get("aria-hidden") ?? "").trim().toLowerCase() === "true") return true;
  if (inlineStyleHidesElement(attributes.get("style"))) return true;
  return name === "input" && (attributes.get("type") ?? "").trim().toLowerCase() === "hidden";
}

function findHTMLTagEnd(source, start) {
  let quote = null;
  for (let index = start; index < source.length; index += 1) {
    const character = source[index];
    if (quote !== null) {
      if (character === quote) quote = null;
      continue;
    }
    if (character === '"' || character === "'") {
      quote = character;
    } else if (character === ">") {
      return index;
    }
  }
  return -1;
}

// This is deliberately a static HTML renderability screen, not a browser
// rendering engine. It excludes semantic/inline hiding that can be established
// from the response HTML, but does not execute CSS layout or fetch stylesheets.
// Release staff must still confirm actual visibility in a browser.
function staticRenderableHTMLDocument(html) {
  const withoutComments = html.replace(/<!--[\s\S]*?(?:-->|$)/gu, " ");
  const source = withoutComments.replace(
    /<(script|style)\b[^>]*>[\s\S]*?(?:<\/\1\s*>|$)/giu,
    " ",
  );
  const elements = [];
  const textSegments = [];
  const stack = [];
  let cursor = 0;
  while (cursor < source.length) {
    const tagStart = source.indexOf("<", cursor);
    const textEnd = tagStart < 0 ? source.length : tagStart;
    if (!stack.at(-1)?.hidden && textEnd > cursor) textSegments.push(source.slice(cursor, textEnd));
    if (tagStart < 0) break;
    if (source.startsWith("<!--", tagStart)) {
      const commentEnd = source.indexOf("-->", tagStart + 4);
      cursor = commentEnd < 0 ? source.length : commentEnd + 3;
      continue;
    }
    const tagEnd = findHTMLTagEnd(source, tagStart + 1);
    if (tagEnd < 0) break;
    const token = source.slice(tagStart + 1, tagEnd);
    cursor = tagEnd + 1;
    if (/^\s*[!?]/u.test(token)) continue;
    const closing = token.match(/^\s*\/\s*([a-z][a-z0-9:-]*)/iu);
    if (closing) {
      const name = closing[1].toLowerCase();
      const matchingIndex = stack.map(item => item.name).lastIndexOf(name);
      if (matchingIndex >= 0) stack.splice(matchingIndex);
      continue;
    }
    const opening = token.match(/^\s*([a-z][a-z0-9:-]*)([\s\S]*?)\s*(\/?)\s*$/iu);
    if (!opening) continue;
    const name = opening[1].toLowerCase();
    const attributes = parsedHTMLAttributes(opening[2]);
    const hidden = Boolean(stack.at(-1)?.hidden) || elementIsHidden(name, attributes);
    if (!hidden) elements.push({ name, attributes });
    if (opening[3] !== "/" && !VOID_HTML_ELEMENTS.has(name)) stack.push({ name, hidden });
  }
  const text = decodeHTMLEntities(textSegments.join(" "))
    .replace(/\s+/gu, " ")
    .trim();
  return { elements, text };
}

function hasExactDeletionPath(elements, finalURL) {
  const validIDs = new Set(["delete-data", "delete-data-en"]);
  if (elements.some(({ attributes }) => validIDs.has(attributes.get("id") ?? ""))) return true;
  return elements.some(({ name, attributes }) => {
    if (name !== "a" || !attributes.has("href")) return false;
    let link;
    try {
      link = new URL(attributes.get("href"), finalURL);
    } catch {
      return false;
    }
    return link.protocol === "https:" && !link.username && !link.password && !link.search &&
      link.origin === new URL(finalURL).origin && validIDs.has(link.hash.slice(1));
  });
}

function hasRealSupportContact(elements, finalURL) {
  const emailPattern = /^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9.-]{0,251}[A-Z0-9])?\.[A-Z]{2,63}$/iu;
  return elements.some(({ name, attributes }) => {
    if (name !== "a" || !attributes.has("href")) return false;
    const href = attributes.get("href").trim();
    if (!href) return false;
    if (/^mailto:/iu.test(href)) {
      let decoded;
      try {
        decoded = decodeURIComponent(href.slice(7).split("?", 1)[0]);
      } catch {
        return false;
      }
      return emailPattern.test(decoded);
    }
    let link;
    try {
      link = new URL(href, finalURL);
    } catch {
      return false;
    }
    const final = new URL(finalURL);
    const distinctDestination = `${link.origin}${link.pathname}${link.search}` !==
      `${final.origin}${final.pathname}${final.search}`;
    const hostname = link.hostname.replace(/^\[|\]$/gu, "").toLowerCase();
    const publicHostname = net.isIP(hostname) === 0 && hostname.includes(".") &&
      hostname !== "localhost" && !hostname.endsWith(".localhost") && !hostname.endsWith(".local") &&
      !hostname.endsWith(".internal") && !hostname.endsWith(".home.arpa") &&
      !hostname.endsWith(".test") && !hostname.endsWith(".example") && !hostname.endsWith(".invalid");
    return link.protocol === "https:" && !link.username && !link.password && publicHostname && distinctDestination &&
      /(?:^|[/_.-])(?:contact|support|help|issues?)(?:[/_.-]|$)/iu.test(`${link.hostname}${link.pathname}`);
  });
}

function validateHTMLBody(body, productName, kind, finalURL) {
  let html;
  try {
    html = new TextDecoder("utf-8", { fatal: true }).decode(body);
  } catch {
    fail(`${kind} page is not valid UTF-8 HTML`);
  }
  const document = staticRenderableHTMLDocument(html);
  if (!document.text.includes(productName)) {
    fail(`${kind} page is missing the configured product name in the visible HTML structure`);
  }
  const languages = document.elements
    .map(({ attributes }) => attributes.get("lang")?.toLowerCase())
    .filter(Boolean);
  const chineseLanguage = languages.some(language => /^(?:zh|zh-cn|zh-hans)$/u.test(language));
  const englishLanguage = languages.some(language => /^en(?:-[a-z]{2,8})?$/u.test(language));
  if (!chineseLanguage || !englishLanguage) fail(`${kind} page is missing Chinese or English language markup`);
  const pagePurpose = kind === "privacy"
    ? /\bprivacy\b/iu.test(document.text) && document.text.includes("隐私")
    : /\b(?:support|help)\b/iu.test(document.text) && /(?:支持|帮助)/u.test(document.text);
  if (!pagePurpose) fail(`${kind} page is missing bilingual ${kind} purpose text in the visible HTML structure`);
  const contactOrDeletionPath = kind === "privacy"
    ? hasExactDeletionPath(document.elements, finalURL)
    : hasRealSupportContact(document.elements, finalURL);
  if (!contactOrDeletionPath) {
    fail(kind === "privacy"
      ? "privacy page is missing an exact delete-data entry in the visible HTML structure"
      : "support page is missing a real mailto or HTTPS support contact link in the visible HTML structure");
  }
  return {
    productName: true,
    bilingualLanguages: true,
    pagePurpose: true,
    contactOrDeletionPath: true,
  };
}

function validateHTMLContentType(contentType, kind) {
  if (typeof contentType !== "string" || !/^text\/html(?:\s*;|$)/iu.test(contentType)) {
    fail(`${kind} page content-type is not HTML`);
  }
  if (/charset\s*=\s*(?!["']?(?:utf-8|us-ascii)["']?(?:\s*;|\s*$))/iu.test(contentType)) {
    fail(`${kind} page declares an unsupported character encoding`);
  }
}

async function capturePage({ kind, configuredURL, productName, transport, timeoutMs, maxRedirects, clock }) {
  const initial = parseSafeHTTPSURL(configuredURL, `configured ${kind} URL`);
  let current = initial;
  let redirects = 0;
  const deadline = Date.now() + timeoutMs;
  while (true) {
    const raw = await invokeTransport(transport, current, kind, timeoutMs, deadline);
    if (!isObject(raw) || !Number.isInteger(raw.status) || raw.status < 100 || raw.status > 599) {
      fail(`${kind} page returned an invalid HTTPS response`);
    }
    const headers = normalizedHeaders(raw.headers);
    const body = responseBodyBytes(raw.body ?? Buffer.alloc(0));
    if (body.length > MAX_RESPONSE_BYTES) fail(`${kind} page response exceeds the 1 MiB limit`);
    if ([301, 302, 303, 307, 308].includes(raw.status)) {
      if (redirects >= maxRedirects) fail(`${kind} page exceeded the redirect limit`);
      const location = singleHeader(headers, "location");
      if (!location) fail(`${kind} page redirect is missing a location`);
      let destination;
      try {
        destination = new URL(location, current);
      } catch {
        fail(`${kind} page redirect location is invalid`);
      }
      destination = parseSafeHTTPSURL(destination.href, `${kind} page redirect`);
      if (destination.origin !== initial.origin) fail(`${kind} page attempted a cross-origin redirect`);
      current = destination;
      redirects += 1;
      continue;
    }
    if (raw.status < 200 || raw.status > 299) fail(`${kind} page did not return a 2xx status`);
    const contentType = singleHeader(headers, "content-type")?.trim() ?? "";
    validateHTMLContentType(contentType, kind);
    const encoding = singleHeader(headers, "content-encoding")?.trim().toLowerCase();
    if (encoding && encoding !== "identity") fail(`${kind} page returned an unsupported content encoding`);
    const validations = validateHTMLBody(body, productName, kind, current.href);
    return {
      kind,
      configuredURL: initial.href,
      finalURL: current.href,
      status: raw.status,
      contentType,
      bodySizeBytes: body.length,
      bodySHA256: sha256(body),
      redirectCount: redirects,
      checkedAt: checkedAtValue(clock),
      validations,
    };
  }
}

function strictJSONObject(snapshot, label) {
  let source;
  try {
    source = new TextDecoder("utf-8", { fatal: true }).decode(snapshot.body);
  } catch {
    fail(`${label} is not valid UTF-8`);
  }
  const value = parseStrictJSON(source, label);
  if (!isObject(value)) fail(`${label} must contain a JSON object`);
  return value;
}

function assertString(value, label, { minimum = 1, maximum = 4000, pattern } = {}) {
  if (typeof value !== "string" || value !== value.trim() ||
      Array.from(value).length < minimum || Array.from(value).length > maximum ||
      (pattern && !pattern.test(value))) {
    fail(`${label} is invalid`);
  }
}

function assertArray(value, label, minimum, maximum) {
  if (!Array.isArray(value) || value.length < minimum || value.length > maximum) {
    fail(`${label} has an invalid array shape`);
  }
}

function assertRepositoryPath(value, label) {
  assertSafePathText(value, label);
  if (typeof value !== "string" || path.posix.normalize(value) !== value || value.startsWith("./") ||
      value.startsWith("/") || value.endsWith("/") || value.split("/").some(component => !component)) {
    fail(`${label} must be a canonical repository-relative POSIX path`);
  }
}

function productionBundleIdentifier(value, label) {
  assertString(value, label, { maximum: 255, pattern: /^(?:[A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z0-9][A-Za-z0-9-]*$/u });
  if (/^(?:com\.example|com\.yourname)(?:\.|$)/iu.test(value)) fail(`${label} is a placeholder identifier`);
}

function validateCloudKitContract(value, configuration, label) {
  exactKeys(value, ["databaseScope", "environment", "recordType", "recordName", "payloadField"], label);
  const expected = {
    databaseScope: "private",
    environment: "Production",
    recordType: configuration.cloudKit.recordType,
    recordName: configuration.cloudKit.recordName,
    payloadField: configuration.cloudKit.payloadField,
  };
  if (Object.entries(expected).some(([key, expectedValue]) => value[key] !== expectedValue)) {
    fail(`${label} differs from the configured production contract`);
  }
}

async function validateIdentityLockDocument(root, snapshot, configuration) {
  const lock = strictJSONObject(snapshot, "identity lock");
  exactKeys(lock, [
    "schemaVersion", "firstAppliedAt", "identity", "provisioningProfile",
    "generatedEntitlements", "appliedFiles",
  ], "identity lock");
  if (lock.schemaVersion !== 1) fail("identity lock envelope schemaVersion must equal 1");
  parseTimestamp(lock.firstAppliedAt, "identity lock firstAppliedAt");

  const identity = lock.identity;
  if (!isObject(identity)) fail("identity lock identity must be an object");
  let normalizedIdentity;
  if (identity.schemaVersion === 1) {
    exactKeys(identity, [
      "schemaVersion", "primaryBundleIdentifier", "widgetBundleIdentifier", "teamIdentifier",
      "iCloudContainerIdentifier", "cloudKit",
    ], "identity lock legacy identity");
    productionBundleIdentifier(identity.primaryBundleIdentifier, "identity lock primary Bundle ID");
    if (identity.widgetBundleIdentifier !== `${identity.primaryBundleIdentifier}.liveactivity`) {
      fail("identity lock legacy Widget Bundle ID does not derive from its primary Bundle ID");
    }
    normalizedIdentity = {
      recordMode: "universal-purchase",
      macBundleIdentifier: identity.primaryBundleIdentifier,
      iosBundleIdentifier: identity.primaryBundleIdentifier,
      widgetBundleIdentifier: identity.widgetBundleIdentifier,
    };
  } else if (identity.schemaVersion === 2) {
    exactKeys(identity, [
      "schemaVersion", "appStoreRecordMode", "macOSAppBundleIdentifier", "iOSAppBundleIdentifier",
      "iOSWidgetBundleIdentifier", "teamIdentifier", "iCloudContainerIdentifier", "cloudKit",
    ], "identity lock identity");
    if (!["universal-purchase", "separate-records"].includes(identity.appStoreRecordMode)) {
      fail("identity lock App Store record mode is unsupported");
    }
    productionBundleIdentifier(identity.macOSAppBundleIdentifier, "identity lock macOS Bundle ID");
    productionBundleIdentifier(identity.iOSAppBundleIdentifier, "identity lock iOS Bundle ID");
    if (identity.iOSWidgetBundleIdentifier !== `${identity.iOSAppBundleIdentifier}.liveactivity`) {
      fail("identity lock Widget Bundle ID does not derive from its iOS Bundle ID");
    }
    if ((identity.appStoreRecordMode === "universal-purchase") !==
        (identity.macOSAppBundleIdentifier === identity.iOSAppBundleIdentifier)) {
      fail("identity lock record mode and primary Bundle IDs disagree");
    }
    normalizedIdentity = {
      recordMode: identity.appStoreRecordMode,
      macBundleIdentifier: identity.macOSAppBundleIdentifier,
      iosBundleIdentifier: identity.iOSAppBundleIdentifier,
      widgetBundleIdentifier: identity.iOSWidgetBundleIdentifier,
    };
  } else {
    fail("identity lock identity schemaVersion is unsupported");
  }
  assertString(identity.teamIdentifier, "identity lock Team ID", { maximum: 10, pattern: /^[A-Z0-9]{10}$/u });
  assertString(identity.iCloudContainerIdentifier, "identity lock iCloud container", {
    maximum: 255,
    pattern: /^iCloud\.(?:[A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z0-9][A-Za-z0-9-]*$/u,
  });
  validateCloudKitContract(identity.cloudKit, configuration, "identity lock CloudKit contract");
  if (normalizedIdentity.macBundleIdentifier !== configuration.macos.bundleIdentifier ||
      normalizedIdentity.iosBundleIdentifier !== configuration.ios.bundleIdentifier ||
      normalizedIdentity.widgetBundleIdentifier !== configuration.ios.widgetBundleIdentifier ||
      identity.teamIdentifier !== configuration.teamIdentifier ||
      identity.iCloudContainerIdentifier !== configuration.iCloudContainerIdentifier) {
    fail("identity lock identity differs from the current project configuration");
  }

  const dependencies = [];
  if ((lock.provisioningProfile === null) !== (lock.generatedEntitlements === null)) {
    fail("identity lock profile and generated entitlements must both be null or both be present");
  }
  if (lock.provisioningProfile !== null) {
    exactKeys(lock.provisioningProfile, [
      "sha256", "uuid", "name", "expiration", "applicationIdentifier", "appIDPrefix",
    ], "identity lock provisioning profile");
    if (!/^[0-9a-f]{64}$/u.test(lock.provisioningProfile.sha256 ?? "")) fail("identity lock profile SHA-256 is invalid");
    for (const field of ["uuid", "name", "applicationIdentifier", "appIDPrefix"]) {
      assertString(lock.provisioningProfile[field], `identity lock profile ${field}`, { maximum: 255 });
    }
    parseTimestamp(lock.provisioningProfile.expiration, "identity lock profile expiration");
    if (lock.provisioningProfile.applicationIdentifier !==
        `${lock.provisioningProfile.appIDPrefix}.${normalizedIdentity.macBundleIdentifier}`) {
      fail("identity lock profile application identifier is inconsistent");
    }
    exactKeys(lock.generatedEntitlements, ["path", "sha256"], "identity lock generated entitlements");
    if (lock.generatedEntitlements.path !== ".release/CloudKit.entitlements" ||
        !/^[0-9a-f]{64}$/u.test(lock.generatedEntitlements.sha256 ?? "")) {
      fail("identity lock generated entitlements record is invalid");
    }
    const entitlements = await existingRepositoryFile(root, lock.generatedEntitlements.path, "generated entitlements");
    const entitlementsSnapshot = await readStableFile(entitlements.absolutePath, MAX_EVIDENCE_BYTES, "generated entitlements");
    if (entitlementsSnapshot.sha256 !== lock.generatedEntitlements.sha256) {
      fail("identity lock generated entitlements SHA-256 is stale");
    }
    dependencies.push({ path: entitlements.relativePath, sha256: entitlementsSnapshot.sha256,
      dev: entitlementsSnapshot.stats.dev, ino: entitlementsSnapshot.stats.ino });
  }

  const expectedAppliedPaths = [
    "Resources/Info.plist",
    CONFIG_RELATIVE_PATH,
    MAC_CONFIG_RELATIVE_PATH,
  ];
  assertArray(lock.appliedFiles, "identity lock appliedFiles", expectedAppliedPaths.length, expectedAppliedPaths.length);
  for (let index = 0; index < expectedAppliedPaths.length; index += 1) {
    const record = lock.appliedFiles[index];
    exactKeys(record, ["path", "sha256"], `identity lock appliedFiles[${index}]`);
    if (record.path !== expectedAppliedPaths[index] || !/^[0-9a-f]{64}$/u.test(record.sha256 ?? "")) {
      fail("identity lock appliedFiles contract is invalid");
    }
    const applied = await existingRepositoryFile(root, record.path, "identity-applied file");
    const appliedSnapshot = await readStableFile(applied.absolutePath, MAX_EVIDENCE_BYTES, "identity-applied file");
    if (appliedSnapshot.sha256 !== record.sha256) fail("identity lock applied-file SHA-256 is stale");
    dependencies.push({ path: applied.relativePath, sha256: appliedSnapshot.sha256,
      dev: appliedSnapshot.stats.dev, ino: appliedSnapshot.stats.ino });
  }
  return { normalizedIdentity, identitySchemaVersion: identity.schemaVersion, dependencies };
}

function assertNoSubmissionPlaceholder(value, location = "submission manifest") {
  if (typeof value === "string" && /\[[A-Z][A-Z0-9 ._:/+-]{2,}\]/u.test(value)) {
    fail(`${location} contains an unresolved placeholder`);
  }
  if (Array.isArray(value)) {
    value.forEach((entry, index) => assertNoSubmissionPlaceholder(entry, `${location}[${index}]`));
  } else if (isObject(value)) {
    for (const [key, entry] of Object.entries(value)) assertNoSubmissionPlaceholder(entry, `${location}.${key}`);
  }
}

function validateContact(value, label) {
  exactKeys(value, ["firstName", "lastName", "email", "phone"], label);
  assertString(value.firstName, `${label}.firstName`, { maximum: 100 });
  assertString(value.lastName, `${label}.lastName`, { maximum: 100 });
  assertString(value.email, `${label}.email`, {
    maximum: 254,
    pattern: /^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9.-]{0,251}[A-Z0-9])?\.[A-Z]{2,63}$/iu,
  });
  assertString(value.phone, `${label}.phone`, { maximum: 16, pattern: /^\+[1-9][0-9]{7,14}$/u });
}

function validateLogin(value, label) {
  exactKeys(value, ["strategy", "credentialsSecretReference", "instructions"], label);
  if (!["no-login", "review-account", "custom-instructions"].includes(value.strategy)) fail(`${label}.strategy is unsupported`);
  assertString(value.instructions, `${label}.instructions`);
  if (value.strategy === "no-login") {
    if (value.credentialsSecretReference !== null) fail(`${label} no-login credentials reference must be null`);
  } else {
    assertString(value.credentialsSecretReference, `${label}.credentialsSecretReference`, {
      maximum: 220,
      pattern: /^(?:keychain|ci-secret):\/\/[A-Za-z0-9._/-]{2,200}$/u,
    });
  }
}

function validateVersion(value, expected, label) {
  exactKeys(value, ["versionString", "buildNumber", "releaseKind", "releaseMode", "scheduledReleaseAt", "copyright"], label);
  assertString(value.versionString, `${label}.versionString`, { maximum: 32, pattern: /^[0-9]+(?:\.[0-9]+){1,2}$/u });
  assertString(value.buildNumber, `${label}.buildNumber`, { maximum: 32, pattern: /^[1-9][0-9]*$/u });
  if (value.versionString !== expected.version || value.buildNumber !== expected.build) {
    fail(`${label} differs from the current project version`);
  }
  if (!["initial", "update"].includes(value.releaseKind)) fail(`${label}.releaseKind is unsupported`);
  if (!["manual", "automatic", "scheduled"].includes(value.releaseMode)) fail(`${label}.releaseMode is unsupported`);
  if (value.releaseMode === "scheduled") {
    if (parseTimestamp(value.scheduledReleaseAt, `${label}.scheduledReleaseAt`) <= Date.now()) {
      fail(`${label}.scheduledReleaseAt is not in the future`);
    }
  }
  else if (value.scheduledReleaseAt !== null) fail(`${label}.scheduledReleaseAt must be null for this release mode`);
  assertString(value.copyright, `${label}.copyright`, { maximum: 200 });
}

function validateCommerce(value, label) {
  exactKeys(value, [
    "ageRating", "madeForKids", "contentRights", "eula", "digitalServicesAct",
    "pricing", "exportCompliance",
  ], label);
  exactKeys(value.ageRating, ["questionnaireStatus", "declaredRating"], `${label}.ageRating`);
  if (value.ageRating.questionnaireStatus !== "complete" || !["4+", "9+", "13+", "16+", "18+"].includes(value.ageRating.declaredRating)) {
    fail(`${label}.ageRating is not a completed release decision`);
  }
  if (typeof value.madeForKids !== "boolean") fail(`${label}.madeForKids must be Boolean`);
  exactKeys(value.contentRights, ["status", "notes"], `${label}.contentRights`);
  if (!["does-not-use-third-party-content", "uses-third-party-content-rights-cleared"].includes(value.contentRights.status)) {
    fail(`${label}.contentRights status is not final`);
  }
  assertString(value.contentRights.notes, `${label}.contentRights.notes`);
  exactKeys(value.eula, ["type", "customText", "territories"], `${label}.eula`);
  if (value.eula.type === "apple-standard") {
    if (value.eula.customText !== null || !Array.isArray(value.eula.territories) || value.eula.territories.length !== 0) {
      fail(`${label}.eula Apple standard decision is inconsistent`);
    }
  } else if (value.eula.type === "custom") {
    assertString(value.eula.customText, `${label}.eula.customText`, { minimum: 100 });
    assertArray(value.eula.territories, `${label}.eula.territories`, 1, 175);
    if (new Set(value.eula.territories).size !== value.eula.territories.length ||
        value.eula.territories.some(territory => typeof territory !== "string" || !/^[A-Z]{3}$/u.test(territory))) {
      fail(`${label}.eula territories are invalid`);
    }
  } else {
    fail(`${label}.eula type is unsupported`);
  }
  exactKeys(value.digitalServicesAct, ["traderStatus", "verificationStatus"], `${label}.digitalServicesAct`);
  if (!["trader", "non-trader"].includes(value.digitalServicesAct.traderStatus) ||
      !["verified", "not-required"].includes(value.digitalServicesAct.verificationStatus) ||
      (value.digitalServicesAct.traderStatus === "trader" && value.digitalServicesAct.verificationStatus !== "verified")) {
    fail(`${label}.digitalServicesAct decision is not release-ready`);
  }
  exactKeys(value.pricing, ["model", "pricePointReference", "taxCategory", "availableTerritories"], `${label}.pricing`);
  if (!["free", "paid"].includes(value.pricing.model)) fail(`${label}.pricing model is unsupported`);
  if ((value.pricing.model === "free" && value.pricing.pricePointReference !== null) ||
      (value.pricing.model === "paid" && typeof value.pricing.pricePointReference !== "string")) {
    fail(`${label}.pricing price point is inconsistent`);
  }
  if (value.pricing.model === "paid") {
    assertString(value.pricing.pricePointReference, `${label}.pricing.pricePointReference`, {
      maximum: 100,
      pattern: /^[A-Za-z0-9._:-]{2,100}$/u,
    });
  }
  assertString(value.pricing.taxCategory, `${label}.pricing.taxCategory`, { maximum: 64, pattern: /^[A-Z][A-Z0-9_]{2,63}$/u });
  assertArray(value.pricing.availableTerritories, `${label}.pricing.availableTerritories`, 1, 175);
  if (new Set(value.pricing.availableTerritories).size !== value.pricing.availableTerritories.length ||
      value.pricing.availableTerritories.some(territory => typeof territory !== "string" || !/^[A-Z]{3}$/u.test(territory))) {
    fail(`${label}.pricing territories are invalid`);
  }
  exactKeys(value.exportCompliance, ["usesNonExemptEncryption", "status", "documentationReference"], `${label}.exportCompliance`);
  if (value.exportCompliance.usesNonExemptEncryption === false) {
    if (value.exportCompliance.status !== "exempt" || value.exportCompliance.documentationReference !== null) {
      fail(`${label}.exportCompliance exempt decision is inconsistent`);
    }
  } else if (value.exportCompliance.usesNonExemptEncryption === true) {
    if (value.exportCompliance.status !== "documentation-approved") {
      fail(`${label}.exportCompliance non-exempt decision is not approved`);
    }
    assertRepositoryPath(value.exportCompliance.documentationReference, `${label}.exportCompliance.documentationReference`);
  } else {
    fail(`${label}.exportCompliance usesNonExemptEncryption must be Boolean`);
  }
}

function validateLocalization(value, label, configuration, configuredURLs, allowedOrigins, releaseKind) {
  exactKeys(value, [
    "locale", "name", "subtitle", "promotionalText", "description", "keywords", "whatsNew",
    "privacyPolicyURL", "supportURL", "marketingURL",
  ], label);
  if (!["zh-Hans", "en-US"].includes(value.locale)) fail(`${label}.locale is unsupported`);
  if (value.name !== configuration.productName) fail(`${label}.name differs from the configured product name`);
  for (const field of ["subtitle", "promotionalText", "description", "keywords"]) {
    assertString(value[field], `${label}.${field}`, { minimum: field === "subtitle" || field === "promotionalText" ? 0 : 1,
      maximum: field === "subtitle" ? 30 : field === "promotionalText" ? 170 : field === "keywords" ? 100 : 4000 });
  }
  if (releaseKind === "initial") {
    if (value.whatsNew !== null) fail(`${label}.whatsNew must be null for an initial release`);
  } else {
    assertString(value.whatsNew, `${label}.whatsNew`, { maximum: 4000 });
  }
  if (value.privacyPolicyURL !== configuredURLs.privacy || value.supportURL !== configuredURLs.support) {
    fail(`${label} public-page URLs differ from current xcconfig`);
  }
  if (value.marketingURL !== null) {
    const marketing = parseSafeHTTPSURL(value.marketingURL, `${label}.marketingURL`);
    if (!allowedOrigins.includes(marketing.origin)) fail(`${label}.marketingURL origin is not allowlisted`);
  }
  return value.locale;
}

function validateScreenshotSets(value, label, platform) {
  assertArray(value, label, 2, 20);
  const locales = [];
  const allPaths = [];
  for (const [index, set] of value.entries()) {
    exactKeys(set, ["locale", "device", "orderedPaths"], `${label}[${index}]`);
    if (!["zh-Hans", "en-US"].includes(set.locale)) fail(`${label}[${index}].locale is unsupported`);
    assertString(set.device, `${label}[${index}].device`, { maximum: 80 });
    assertArray(set.orderedPaths, `${label}[${index}].orderedPaths`, 1, 10);
    for (const candidatePath of set.orderedPaths) {
      assertRepositoryPath(candidatePath, `${label}[${index}] screenshot`);
      if (!candidatePath.startsWith(`docs/release-assets/${platform}/${set.locale}/`) || !/\.(?:png|jpe?g)$/u.test(candidatePath)) {
        fail(`${label}[${index}] contains an unexpected screenshot path`);
      }
      allPaths.push(candidatePath);
    }
    if (new Set(set.orderedPaths).size !== set.orderedPaths.length) fail(`${label}[${index}] repeats a screenshot path`);
    locales.push(set.locale);
  }
  if (JSON.stringify([...new Set(locales)].sort()) !== JSON.stringify(["en-US", "zh-Hans"])) {
    fail(`${label} must cover exactly the required locales`);
  }
  if (new Set(allPaths).size !== allPaths.length) fail(`${label} repeats a screenshot path across sets`);
}

function validateTestFlight(value, label) {
  exactKeys(value, ["distribution", "feedbackEmail", "betaReviewContact", "betaReviewNotes", "login", "localizations"], label);
  if (!["internal-only", "external"].includes(value.distribution)) fail(`${label}.distribution is unsupported`);
  assertString(value.feedbackEmail, `${label}.feedbackEmail`, { maximum: 254,
    pattern: /^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9.-]+\.[A-Z]{2,63}$/iu });
  validateContact(value.betaReviewContact, `${label}.betaReviewContact`);
  assertString(value.betaReviewNotes, `${label}.betaReviewNotes`);
  validateLogin(value.login, `${label}.login`);
  assertArray(value.localizations, `${label}.localizations`, 2, 2);
  const locales = [];
  value.localizations.forEach((localization, index) => {
    exactKeys(localization, ["locale", "betaAppDescription", "whatToTest"], `${label}.localizations[${index}]`);
    if (!["zh-Hans", "en-US"].includes(localization.locale)) fail(`${label}.localizations locale is unsupported`);
    assertString(localization.betaAppDescription, `${label}.localizations betaAppDescription`);
    assertString(localization.whatToTest, `${label}.localizations whatToTest`);
    locales.push(localization.locale);
  });
  if (JSON.stringify([...new Set(locales)].sort()) !== JSON.stringify(["en-US", "zh-Hans"])) {
    fail(`${label}.localizations must cover exactly the required locales`);
  }
}

function validateSubmissionRecord(record, platform, configuration, configuredURLs, allowedOrigins) {
  const label = `submission manifest records.${platform}`;
  const keys = [
    "appResourceId", "bundleIdentifier", "sku", "primaryLocale", "version", "categories", "commerce",
    "review", "localizations", "screenshotSets",
  ];
  if (platform === "ios") keys.push("widgetBundleIdentifier", "testFlight");
  exactKeys(record, keys, label);
  assertString(record.appResourceId, `${label}.appResourceId`, { maximum: 20, pattern: /^[0-9]{8,20}$/u });
  productionBundleIdentifier(record.bundleIdentifier, `${label}.bundleIdentifier`);
  if (record.bundleIdentifier !== configuration[platform].bundleIdentifier) fail(`${label}.bundleIdentifier differs from current xcconfig`);
  assertString(record.sku, `${label}.sku`, { maximum: 64, pattern: /^[A-Za-z0-9._-]{2,64}$/u });
  if (!["zh-Hans", "en-US"].includes(record.primaryLocale)) fail(`${label}.primaryLocale is unsupported`);
  if (platform === "ios") {
    productionBundleIdentifier(record.widgetBundleIdentifier, `${label}.widgetBundleIdentifier`);
    if (record.widgetBundleIdentifier !== configuration.ios.widgetBundleIdentifier ||
        record.widgetBundleIdentifier !== `${record.bundleIdentifier}.liveactivity`) {
      fail(`${label}.widgetBundleIdentifier differs from the current derived identifier`);
    }
  }
  validateVersion(record.version, configuration[platform], `${label}.version`);
  exactKeys(record.categories, ["primary", "secondary"], `${label}.categories`);
  const categories = new Set([
    "books", "business", "developer-tools", "education", "entertainment", "finance", "food-drink",
    "games", "graphics-design", "health-fitness", "lifestyle", "magazines-newspapers", "medical", "music",
    "navigation", "news", "photography-video", "productivity", "reference", "shopping", "social-networking",
    "sports", "travel", "utilities", "weather",
  ]);
  if (!categories.has(record.categories.primary) ||
      (record.categories.secondary !== null && !categories.has(record.categories.secondary)) ||
      record.categories.secondary === record.categories.primary) {
    fail(`${label}.categories are invalid`);
  }
  validateCommerce(record.commerce, `${label}.commerce`);
  exactKeys(record.review, ["contact", "login", "notes"], `${label}.review`);
  validateContact(record.review.contact, `${label}.review.contact`);
  validateLogin(record.review.login, `${label}.review.login`);
  assertString(record.review.notes, `${label}.review.notes`);
  assertArray(record.localizations, `${label}.localizations`, 2, 2);
  const locales = record.localizations.map((localization, index) =>
    validateLocalization(localization, `${label}.localizations[${index}]`, configuration, configuredURLs,
      allowedOrigins, record.version.releaseKind));
  if (JSON.stringify([...new Set(locales)].sort()) !== JSON.stringify(["en-US", "zh-Hans"]) || !locales.includes(record.primaryLocale)) {
    fail(`${label}.localizations do not match the required locales`);
  }
  validateScreenshotSets(record.screenshotSets, `${label}.screenshotSets`, platform);
  if (platform === "ios") validateTestFlight(record.testFlight, `${label}.testFlight`);
}

async function validateSubmissionManifestDocument(root, snapshot, configuration, configuredURLs, allowedOrigins) {
  const manifest = strictJSONObject(snapshot, "submission manifest");
  exactKeys(manifest, [
    "schemaVersion", "productName", "recordMode", "identityLockSHA256",
    "screenshotEvidencePath", "screenshotEvidenceSHA256", "records",
  ], "submission manifest");
  assertNoSubmissionPlaceholder(manifest);
  if (manifest.schemaVersion !== 1) fail("submission manifest schemaVersion must equal 1");
  if (manifest.productName !== configuration.productName) fail("submission manifest product name differs from current xcconfig");
  if (!["universal-purchase", "separate-records"].includes(manifest.recordMode)) fail("submission manifest record mode is unsupported");
  if (!/^[0-9a-f]{64}$/u.test(manifest.identityLockSHA256 ?? "") ||
      !/^[0-9a-f]{64}$/u.test(manifest.screenshotEvidenceSHA256 ?? "")) {
    fail("submission manifest binding SHA-256 fields are invalid");
  }
  exactKeys(manifest.records, ["macos", "ios"], "submission manifest records");
  validateSubmissionRecord(manifest.records.macos, "macos", configuration, configuredURLs, allowedOrigins);
  validateSubmissionRecord(manifest.records.ios, "ios", configuration, configuredURLs, allowedOrigins);

  const mac = manifest.records.macos;
  const ios = manifest.records.ios;
  if (manifest.recordMode === "universal-purchase") {
    for (const field of ["appResourceId", "bundleIdentifier", "sku", "primaryLocale"]) {
      if (mac[field] !== ios[field]) fail(`submission manifest universal-purchase ${field} values differ`);
    }
    if (canonicalJSON(mac.categories) !== canonicalJSON(ios.categories) ||
        canonicalJSON(mac.commerce) !== canonicalJSON(ios.commerce)) {
      fail("submission manifest universal-purchase commerce or category decisions differ");
    }
    const macLocalizations = new Map(mac.localizations.map(localization => [localization.locale, localization]));
    const iosLocalizations = new Map(ios.localizations.map(localization => [localization.locale, localization]));
    for (const locale of ["zh-Hans", "en-US"]) {
      for (const field of ["name", "subtitle", "privacyPolicyURL", "supportURL", "marketingURL"]) {
        if (macLocalizations.get(locale)?.[field] !== iosLocalizations.get(locale)?.[field]) {
          fail(`submission manifest universal-purchase ${locale} ${field} values differ`);
        }
      }
    }
  } else {
    for (const field of ["appResourceId", "bundleIdentifier", "sku"]) {
      if (mac[field] === ios[field]) fail(`submission manifest separate-records ${field} values must differ`);
    }
  }

  const identityFile = await existingRepositoryFile(root, DEFAULT_IDENTITY_LOCK_RELATIVE_PATH, "submission identity lock");
  const identitySnapshot = await readStableFile(identityFile.absolutePath, MAX_EVIDENCE_BYTES, "submission identity lock");
  if ((identitySnapshot.stats.mode & 0o077) !== 0) fail("submission identity lock must not be accessible by group or other users");
  if (identitySnapshot.sha256 !== manifest.identityLockSHA256) fail("submission manifest identityLockSHA256 is stale");
  const identityValidation = await validateIdentityLockDocument(root, identitySnapshot, configuration);
  if (identityValidation.identitySchemaVersion !== 2) {
    fail("submission manifest binding requires a schemaVersion 2 release identity");
  }
  const identity = identityValidation.normalizedIdentity;
  if (identity.recordMode !== manifest.recordMode || identity.macBundleIdentifier !== mac.bundleIdentifier ||
      identity.iosBundleIdentifier !== ios.bundleIdentifier || identity.widgetBundleIdentifier !== ios.widgetBundleIdentifier) {
    fail("submission manifest record identity differs from the validated identity lock");
  }

  assertRepositoryPath(manifest.screenshotEvidencePath, "submission screenshotEvidencePath");
  if (!manifest.screenshotEvidencePath.startsWith(".release/")) {
    fail("submission screenshotEvidencePath must identify a private .release file");
  }
  const screenshotFile = await existingRepositoryFile(root, manifest.screenshotEvidencePath, "submission screenshot evidence");
  const screenshotSnapshot = await readStableFile(screenshotFile.absolutePath, MAX_EVIDENCE_BYTES, "submission screenshot evidence");
  if ((screenshotSnapshot.stats.mode & 0o222) !== 0 || screenshotSnapshot.sha256 !== manifest.screenshotEvidenceSHA256) {
    fail("submission screenshot evidence is not sealed to the manifest SHA-256");
  }
  return {
    dependencies: [
      { path: identityFile.relativePath, sha256: identitySnapshot.sha256,
        dev: identitySnapshot.stats.dev, ino: identitySnapshot.stats.ino },
      ...identityValidation.dependencies,
      { path: screenshotFile.relativePath, sha256: screenshotSnapshot.sha256,
        dev: screenshotSnapshot.stats.dev, ino: screenshotSnapshot.stats.ino },
    ],
  };
}

async function captureBinding(root, type, inputPath, configuration, configuredURLs, allowedOrigins) {
  if (type !== "identity-lock" && type !== "submission-manifest") fail("binding type is invalid");
  const expectedPath = type === "identity-lock"
    ? DEFAULT_IDENTITY_LOCK_RELATIVE_PATH
    : DEFAULT_SUBMISSION_MANIFEST_RELATIVE_PATH;
  const source = await existingRepositoryFile(root, inputPath, "binding source");
  if (source.relativePath !== expectedPath) fail(`${type} binding must use ${expectedPath}`);
  const snapshot = await readStableFile(source.absolutePath, MAX_EVIDENCE_BYTES, "binding source");
  if (type === "identity-lock" && (snapshot.stats.mode & 0o077) !== 0) {
    fail("identity lock binding must not be accessible by group or other users");
  }
  if (type === "submission-manifest" && (snapshot.stats.mode & 0o222) !== 0) {
    fail("submission manifest binding must be read-only");
  }
  const validation = type === "identity-lock"
    ? await validateIdentityLockDocument(root, snapshot, configuration)
    : await validateSubmissionManifestDocument(root, snapshot, configuration, configuredURLs, allowedOrigins);
  const dependencyFingerprint = sha256(Buffer.from(JSON.stringify(validation.dependencies), "utf8"));
  return {
    record: { type, path: source.relativePath, sha256: snapshot.sha256 },
    absolutePath: source.absolutePath,
    dev: snapshot.stats.dev,
    ino: snapshot.stats.ino,
    dependencyFingerprint,
    root,
    configuration,
    configuredURLs,
    allowedOrigins,
  };
}

async function assertBindingUnchanged(binding) {
  const current = await captureBinding(
    binding.root,
    binding.record.type,
    binding.record.path,
    binding.configuration,
    binding.configuredURLs,
    binding.allowedOrigins,
  );
  if (current.dev !== binding.dev || current.ino !== binding.ino ||
      current.record.sha256 !== binding.record.sha256 ||
      current.dependencyFingerprint !== binding.dependencyFingerprint) {
    fail("binding source or a bound dependency changed during public-page capture");
  }
}

function parseTimestamp(value, label) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/u.test(value)) {
    fail(`${label} is not a UTC timestamp`);
  }
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds) || new Date(milliseconds).toISOString().replace(".000Z", "Z") !== value) {
    fail(`${label} is not a real UTC timestamp`);
  }
  return milliseconds;
}

function validateFreshTimestamp(value, label, nowMilliseconds, maxAgeSeconds) {
  const milliseconds = parseTimestamp(value, label);
  if (milliseconds > nowMilliseconds + FUTURE_TOLERANCE_SECONDS * 1000) fail(`${label} is in the future`);
  if (nowMilliseconds - milliseconds > maxAgeSeconds * 1000) fail(`${label} is stale`);
  return milliseconds;
}

function validateEvidenceShape(evidence, { configuration, configuredURLs, allowedOrigins, now, maxAgeSeconds }) {
  exactKeys(evidence, [
    "schemaVersion", "evidenceType", "productName", "configuredURLs", "allowedOrigins",
    "binding", "pages", "createdAt",
  ], "public-pages evidence");
  if (evidence.schemaVersion !== 1 || evidence.evidenceType !== "public-pages") {
    fail("public-pages evidence version or type is unsupported");
  }
  if (evidence.productName !== configuration.productName) fail("evidence product name differs from current xcconfig");
  exactKeys(evidence.configuredURLs, ["privacy", "support"], "configuredURLs");
  if (evidence.configuredURLs.privacy !== configuredURLs.privacy ||
      evidence.configuredURLs.support !== configuredURLs.support) {
    fail("evidence URLs differ from current xcconfig");
  }
  if (!Array.isArray(evidence.allowedOrigins) ||
      JSON.stringify(evidence.allowedOrigins) !== JSON.stringify(allowedOrigins)) {
    fail("evidence origin allowlist differs from the verifier allowlist");
  }
  exactKeys(evidence.binding, ["type", "path", "sha256"], "binding");
  if (!["identity-lock", "submission-manifest"].includes(evidence.binding.type) ||
      typeof evidence.binding.path !== "string" || path.isAbsolute(evidence.binding.path) ||
      !/^[0-9a-f]{64}$/u.test(evidence.binding.sha256)) {
    fail("evidence binding is invalid");
  }
  assertSafePathText(evidence.binding.path, "binding");
  const expectedBindingPath = evidence.binding.type === "identity-lock"
    ? DEFAULT_IDENTITY_LOCK_RELATIVE_PATH
    : DEFAULT_SUBMISSION_MANIFEST_RELATIVE_PATH;
  if (evidence.binding.path !== expectedBindingPath) {
    fail(`evidence ${evidence.binding.type} binding must use ${expectedBindingPath}`);
  }
  if (!Array.isArray(evidence.pages) || evidence.pages.length !== 2) {
    fail("public-pages evidence must contain exactly two page records");
  }
  const expectedKinds = ["privacy", "support"];
  const checkedTimes = [];
  for (let index = 0; index < evidence.pages.length; index += 1) {
    const page = evidence.pages[index];
    const kind = expectedKinds[index];
    exactKeys(page, [
      "kind", "configuredURL", "finalURL", "status", "contentType", "bodySizeBytes",
      "bodySHA256", "redirectCount", "checkedAt", "validations",
    ], `${kind} page record`);
    if (page.kind !== kind || page.configuredURL !== configuredURLs[kind]) {
      fail(`${kind} page record does not match the configured URL`);
    }
    const configured = parseSafeHTTPSURL(page.configuredURL, `${kind} configured URL evidence`);
    const final = parseSafeHTTPSURL(page.finalURL, `${kind} final URL evidence`);
    if (final.origin !== configured.origin || !allowedOrigins.includes(final.origin)) {
      fail(`${kind} final URL is not same-origin and allowlisted`);
    }
    validateHTMLContentType(page.contentType, kind);
    if (!Number.isInteger(page.status) || page.status < 200 || page.status > 299 ||
        !Number.isInteger(page.bodySizeBytes) || page.bodySizeBytes <= 0 ||
        page.bodySizeBytes > MAX_RESPONSE_BYTES || !/^[0-9a-f]{64}$/u.test(page.bodySHA256) ||
        !Number.isInteger(page.redirectCount) || page.redirectCount < 0 ||
        page.redirectCount > DEFAULT_MAX_REDIRECTS) {
      fail(`${kind} page response evidence is invalid`);
    }
    exactKeys(page.validations, [
      "productName", "bilingualLanguages", "pagePurpose", "contactOrDeletionPath",
    ], `${kind} validations`);
    if (page.validations.productName !== true || page.validations.bilingualLanguages !== true ||
        page.validations.pagePurpose !== true || page.validations.contactOrDeletionPath !== true) {
      fail(`${kind} page validation assertions are incomplete`);
    }
    checkedTimes.push(validateFreshTimestamp(page.checkedAt, `${kind} checkedAt`, now, maxAgeSeconds));
  }
  const createdAt = validateFreshTimestamp(evidence.createdAt, "evidence createdAt", now, maxAgeSeconds);
  if (createdAt < Math.max(...checkedTimes)) fail("evidence createdAt predates a page check");
  return checkedTimes;
}

export async function capturePublicPagesEvidence(options = {}) {
  const root = await canonicalProjectRoot(options.projectRoot ?? DEFAULT_PROJECT_ROOT);
  const configuration = await loadConfiguration(root);
  const allowedOrigins = normalizeAllowedOrigins(options.allowedOrigins ?? []);
  const configuredURLs = validateConfiguredURLs(configuration, allowedOrigins);
  const bindingType = options.bindingType ?? "identity-lock";
  const bindingPath = options.bindingPath ?? (bindingType === "submission-manifest"
    ? DEFAULT_SUBMISSION_MANIFEST_RELATIVE_PATH
    : DEFAULT_IDENTITY_LOCK_RELATIVE_PATH);
  const binding = await captureBinding(root, bindingType, bindingPath, configuration, configuredURLs, allowedOrigins);
  const output = await resolveNewOutput(root, options.outputPath ?? DEFAULT_OUTPUT_RELATIVE_PATH);
  const transport = options.transport ?? productionTransport;
  if (typeof transport !== "function") fail("HTTPS transport is invalid");
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const maxRedirects = options.maxRedirects ?? DEFAULT_MAX_REDIRECTS;
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 60_000) fail("timeout must be 1-60000 milliseconds");
  if (!Number.isInteger(maxRedirects) || maxRedirects < 0 || maxRedirects > DEFAULT_MAX_REDIRECTS) {
    fail("redirect limit must be between 0 and 5");
  }
  const clock = options.clock ?? (() => new Date());
  const pages = [];
  for (const kind of ["privacy", "support"]) {
    pages.push(await capturePage({
      kind,
      configuredURL: configuredURLs[kind],
      productName: configuration.productName,
      transport,
      timeoutMs,
      maxRedirects,
      clock,
    }));
  }
  await assertBindingUnchanged(binding);
  const finalConfiguration = await loadConfiguration(root);
  if (JSON.stringify(finalConfiguration) !== JSON.stringify(configuration)) {
    fail("public-page configuration changed during capture");
  }
  const evidence = {
    schemaVersion: 1,
    evidenceType: "public-pages",
    productName: configuration.productName,
    configuredURLs,
    allowedOrigins,
    binding: binding.record,
    pages,
    createdAt: checkedAtValue(clock),
  };
  const now = Date.parse(evidence.createdAt);
  validateEvidenceShape(evidence, {
    configuration,
    configuredURLs,
    allowedOrigins,
    now,
    maxAgeSeconds: DEFAULT_MAX_AGE_SECONDS,
  });
  const bytes = Buffer.from(`${JSON.stringify(evidence, null, 2)}\n`, "utf8");
  const evidenceSHA256 = await publishAtomicReadOnly(output, bytes);
  return { evidence, evidencePath: output.absolutePath, evidenceSHA256 };
}

export async function verifyPublicPagesEvidence(options = {}) {
  const root = await canonicalProjectRoot(options.projectRoot ?? DEFAULT_PROJECT_ROOT);
  const configuration = await loadConfiguration(root);
  const allowedOrigins = normalizeAllowedOrigins(options.allowedOrigins ?? []);
  const configuredURLs = validateConfiguredURLs(configuration, allowedOrigins);
  const evidenceFile = await existingRepositoryFile(root, options.evidencePath, "public-pages evidence");
  const snapshot = await readStableFile(evidenceFile.absolutePath, MAX_EVIDENCE_BYTES, "public-pages evidence");
  if (unixMode(snapshot.stats) !== 0o444) fail("public-pages evidence must have mode 0444");
  const evidence = strictJSONObject(snapshot, "public-pages evidence");
  const maxAgeSeconds = options.maxAgeSeconds ?? DEFAULT_MAX_AGE_SECONDS;
  if (!Number.isInteger(maxAgeSeconds) || maxAgeSeconds < 1 || maxAgeSeconds > 31 * 24 * 60 * 60) {
    fail("maximum evidence age must be 1-2678400 seconds");
  }
  const clock = options.clock ?? (() => new Date());
  const nowText = checkedAtValue(clock);
  const now = Date.parse(nowText);
  const checkedTimes = validateEvidenceShape(evidence, {
    configuration,
    configuredURLs,
    allowedOrigins,
    now,
    maxAgeSeconds,
  });
  const binding = await captureBinding(
    root,
    evidence.binding.type,
    evidence.binding.path,
    configuration,
    configuredURLs,
    allowedOrigins,
  );
  if (binding.record.sha256 !== evidence.binding.sha256) fail("public-pages evidence binding SHA-256 is stale");
  const oldestCheckedAt = new Date(Math.min(...checkedTimes)).toISOString().replace(".000Z", "Z");
  const newestCheckedAt = new Date(Math.max(...checkedTimes)).toISOString().replace(".000Z", "Z");
  return {
    valid: true,
    evidencePath: evidenceFile.absolutePath,
    evidenceSHA256: snapshot.sha256,
    binding: {
      type: evidence.binding.type,
      path: binding.absolutePath,
      sha256: binding.record.sha256,
    },
    productName: configuration.productName,
    configuredURLs,
    oldestCheckedAt,
    newestCheckedAt,
    maxAgeSeconds,
  };
}

function usage() {
  return `Usage:
  capture-public-pages-evidence.mjs [--output PATH] [--allow-origin HTTPS_ORIGIN ...]
    [--identity-lock PATH | --submission-manifest PATH]
  capture-public-pages-evidence.mjs --verify PATH [--allow-origin HTTPS_ORIGIN ...]
    [--max-age-seconds SECONDS]

Content checks are static HTML renderability screening only. They do not execute
CSS layout or fetch external stylesheets; manually confirm visibility in a browser.`;
}

function parsePositiveInteger(value, label) {
  if (!/^[1-9][0-9]*$/u.test(value ?? "")) fail(`${label} must be a positive integer`);
  const result = Number(value);
  if (!Number.isSafeInteger(result)) fail(`${label} is too large`);
  return result;
}

function parseCLI(argv) {
  const options = { allowedOrigins: [] };
  let mode = "capture";
  let bindingSelected = false;
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    const take = label => {
      index += 1;
      if (index >= argv.length) fail(`${label} requires a value`);
      return argv[index];
    };
    switch (argument) {
      case "--help":
        return { mode: "help", options };
      case "--verify":
        if (mode !== "capture" || options.evidencePath) fail("--verify may be supplied only once");
        mode = "verify";
        options.evidencePath = take("--verify");
        break;
      case "--output":
        options.outputPath = take("--output");
        break;
      case "--allow-origin":
        options.allowedOrigins.push(take("--allow-origin"));
        break;
      case "--identity-lock":
        if (bindingSelected) fail("choose exactly one binding source");
        bindingSelected = true;
        options.bindingType = "identity-lock";
        options.bindingPath = take("--identity-lock");
        break;
      case "--submission-manifest":
        if (bindingSelected) fail("choose exactly one binding source");
        bindingSelected = true;
        options.bindingType = "submission-manifest";
        options.bindingPath = take("--submission-manifest");
        break;
      case "--max-age-seconds":
        options.maxAgeSeconds = parsePositiveInteger(take("--max-age-seconds"), "--max-age-seconds");
        break;
      default:
        fail("unknown command-line option");
    }
  }
  if (mode === "verify") {
    if (options.outputPath || bindingSelected) fail("capture-only options cannot be used with --verify");
  } else if (options.maxAgeSeconds !== undefined) {
    fail("--max-age-seconds requires --verify");
  }
  return { mode, options };
}

async function main() {
  const { mode, options } = parseCLI(process.argv.slice(2));
  if (mode === "help") {
    process.stdout.write(`${usage()}\n`);
    return;
  }
  if (mode === "verify") {
    const result = await verifyPublicPagesEvidence(options);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return;
  }
  const result = await capturePublicPagesEvidence(options);
  process.stdout.write(`Public pages evidence recorded: ${result.evidencePath}\n`);
  process.stdout.write(`Evidence SHA-256: ${result.evidenceSHA256}\n`);
}

const invokedPath = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : "";
if (invokedPath === import.meta.url) {
  main().catch(error => {
    const message = error instanceof PublicPagesEvidenceError
      ? error.message
      : "unexpected internal failure";
    process.stderr.write(`Public-pages evidence capture failed: ${message}\n`);
    process.exitCode = 1;
  });
}
