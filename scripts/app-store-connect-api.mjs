#!/usr/bin/env node

import {
  createHash,
  createPrivateKey,
  randomBytes,
  sign,
} from "node:crypto";
import {
  constants as fsConstants,
  closeSync,
  existsSync,
  fchmodSync,
  fstatSync,
  fsyncSync,
  lstatSync,
  linkSync,
  openSync,
  readFileSync,
  readSync,
  realpathSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";

export const ASC_ORIGIN = "https://api.appstoreconnect.apple.com";
export const SNAPSHOT_SCHEMA_VERSION = 1;
export const SNAPSHOT_MAX_AGE_SECONDS = 15 * 60;
export const DEFAULT_TIMEOUT_MS = 15_000;
export const DEFAULT_MAX_RESPONSE_BYTES = 1_048_576;
export const DEFAULT_MAX_PAGES = 10;
export const DEFAULT_PROJECT_ROOT = realpathSync(dirname(dirname(fileURLToPath(import.meta.url))));

const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const RESOURCE_ID_PATTERN = /^(?!\.{1,2}$)[^\s/?#]{1,256}$/u;
const BUNDLE_ID_PATTERN = /^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/;
const VERSION_PATTERN = /^[0-9]+(?:\.[0-9]+){1,2}$/;
const BUILD_PATTERN = /^[1-9][0-9]*$/;
const KEY_ID_PATTERN = /^[A-Z0-9]{10}$/;
const ISSUER_ID_PATTERN = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const PRODUCTION_CLOUDKIT_CONTRACT = Object.freeze({
  databaseScope: "private",
  environment: "Production",
  recordType: "AgentIslandSnapshot",
  recordName: "latest",
  payloadField: "payloadJSON",
});
const APPLIED_IDENTITY_PATHS = Object.freeze([
  "Resources/Info.plist",
  "ApplePlatforms/iOS/Config/Project.xcconfig",
  "ApplePlatforms/macOS/Config/Project.xcconfig",
]);

export class AscSnapshotError extends Error {
  constructor(code, message, options = {}) {
    super(message, options);
    this.name = "AscSnapshotError";
    this.code = code;
    if (options.status !== undefined) this.status = options.status;
  }
}

function fail(code, message, options) {
  throw new AscSnapshotError(code, message, options);
}

function assertString(value, label, pattern = null) {
  if (typeof value !== "string" || value.length === 0) {
    fail("INVALID_INPUT", `${label} must be a non-empty string`);
  }
  if (pattern && !pattern.test(value)) {
    fail("INVALID_INPUT", `${label} has an invalid format`);
  }
  return value;
}

export function normalizePlatform(value) {
  const normalized = String(value ?? "").trim();
  if (normalized === "IOS" || normalized.toLowerCase() === "ios") return "IOS";
  if (normalized === "MAC_OS" || normalized.toLowerCase() === "macos") return "MAC_OS";
  fail("INVALID_INPUT", "platform must be iOS/IOS or macOS/MAC_OS");
}

export function validateCaptureQuery({ bundleId, platform, version, build } = {}) {
  assertString(bundleId, "bundle ID", BUNDLE_ID_PATTERN);
  if (platform !== undefined) normalizePlatform(platform);
  if (version !== undefined) assertString(version, "version", VERSION_PATTERN);
  if (build !== undefined) assertString(build, "build", BUILD_PATTERN);
}

function base64url(value) {
  return Buffer.from(value).toString("base64url");
}

function readRegularFileNoFollow(filePath, label, {
  allowEmpty = false,
  maxBytes = null,
  retainBytes = true,
} = {}) {
  let pathStat;
  try {
    pathStat = lstatSync(filePath);
  } catch {
    fail("BINDING_FILE_MISSING", `${label} does not exist`);
  }
  if (!pathStat.isFile() || pathStat.isSymbolicLink()) {
    fail("UNSAFE_PATH", `${label} must be a regular, non-symlink file`);
  }
  let descriptor;
  try {
    descriptor = openSync(filePath, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
  } catch {
    fail("UNSAFE_PATH", `${label} could not be opened without following links`);
  }
  try {
    const openedStat = fstatSync(descriptor);
    if (
      !openedStat.isFile() ||
      openedStat.dev !== pathStat.dev ||
      openedStat.ino !== pathStat.ino
    ) {
      fail("UNSAFE_PATH", `${label} changed while it was opened`);
    }
    if ((!allowEmpty && openedStat.size < 1) || !Number.isSafeInteger(openedStat.size)) {
      fail("BINDING_FILE_INVALID", `${label} has an invalid size`);
    }
    if (maxBytes !== null && openedStat.size > maxBytes) {
      fail("BINDING_FILE_INVALID", `${label} exceeds its size limit`);
    }
    let bytes;
    let byteLength;
    let sha256;
    if (retainBytes) {
      bytes = readFileSync(descriptor);
      byteLength = bytes.byteLength;
      sha256 = createHash("sha256").update(bytes).digest("hex");
    } else {
      const digest = createHash("sha256");
      const chunk = Buffer.allocUnsafe(1024 * 1024);
      byteLength = 0;
      while (byteLength < openedStat.size) {
        const bytesRead = readSync(
          descriptor,
          chunk,
          0,
          Math.min(chunk.byteLength, openedStat.size - byteLength),
          null,
        );
        if (bytesRead === 0) break;
        digest.update(chunk.subarray(0, bytesRead));
        byteLength += bytesRead;
      }
      sha256 = digest.digest("hex");
    }
    const finalStat = fstatSync(descriptor);
    if (
      finalStat.dev !== openedStat.dev ||
      finalStat.ino !== openedStat.ino ||
      finalStat.size !== openedStat.size ||
      finalStat.mtimeMs !== openedStat.mtimeMs ||
      finalStat.ctimeMs !== openedStat.ctimeMs ||
      byteLength !== openedStat.size
    ) {
      fail("BINDING_CHANGED", `${label} changed while it was read`);
    }
    return { bytes, byteLength, sha256, stat: finalStat };
  } finally {
    closeSync(descriptor);
  }
}

function readConfiguredPrivateKey(keyId) {
  assertString(keyId, "App Store Connect key ID", KEY_ID_PATTERN);
  const keyPath = join(
    homedir(),
    ".appstoreconnect",
    "private_keys",
    `AuthKey_${keyId}.p8`,
  );
  let fileStat;
  try {
    fileStat = lstatSync(keyPath);
  } catch {
    fail(
      "ASC_PRIVATE_KEY_MISSING",
      "App Store Connect private key is missing from ~/.appstoreconnect/private_keys",
    );
  }
  if (!fileStat.isFile() || fileStat.isSymbolicLink()) {
    fail("ASC_PRIVATE_KEY_UNSAFE", "App Store Connect private key must be a regular, non-symlink file");
  }
  let canonicalPath;
  try {
    canonicalPath = realpathSync(keyPath);
  } catch {
    fail("ASC_PRIVATE_KEY_UNSAFE", "App Store Connect private key path cannot be resolved safely");
  }
  if (canonicalPath !== keyPath) {
    fail("ASC_PRIVATE_KEY_UNSAFE", "App Store Connect private key path must not traverse symlinks");
  }
  if ((fileStat.mode & 0o077) !== 0) {
    fail("ASC_PRIVATE_KEY_UNSAFE", "App Store Connect private key must not be accessible to group or other users");
  }
  if (fileStat.size < 80 || fileStat.size > 16_384) {
    fail("ASC_PRIVATE_KEY_UNSAFE", "App Store Connect private key has an unexpected size");
  }
  try {
    return readRegularFileNoFollow(keyPath, "App Store Connect private key", {
      maxBytes: 16_384,
    }).bytes;
  } catch (error) {
    if (error instanceof AscSnapshotError && error.code === "UNSAFE_PATH") {
      fail("ASC_PRIVATE_KEY_UNSAFE", "App Store Connect private key changed while it was opened");
    }
    fail("ASC_PRIVATE_KEY_UNREADABLE", "App Store Connect private key could not be read");
  }
}

export function createTeamApiJwt({
  keyId = process.env.AGENT_ISLAND_ASC_API_KEY_ID,
  issuerId = process.env.AGENT_ISLAND_ASC_API_ISSUER_ID,
  scope,
  nowSeconds = Math.floor(Date.now() / 1000),
} = {}) {
  assertString(keyId, "AGENT_ISLAND_ASC_API_KEY_ID", KEY_ID_PATTERN);
  assertString(issuerId, "AGENT_ISLAND_ASC_API_ISSUER_ID", ISSUER_ID_PATTERN);
  assertString(scope, "JWT scope");
  if (scope.length > 4096 || !/^GET \/v1\/[^\s#]*$/u.test(scope)) {
    fail("INVALID_INPUT", "JWT scope must be one App Store Connect GET request");
  }
  if (!Number.isSafeInteger(nowSeconds) || nowSeconds <= 0) {
    fail("INVALID_INPUT", "JWT issued-at time is invalid");
  }

  const header = { alg: "ES256", kid: keyId, typ: "JWT" };
  const payload = {
    iss: issuerId,
    iat: nowSeconds,
    exp: nowSeconds + 120,
    aud: "appstoreconnect-v1",
    scope: [scope],
  };
  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(payload))}`;
  const privateKeyBytes = readConfiguredPrivateKey(keyId);
  let privateKey;
  try {
    privateKey = createPrivateKey(privateKeyBytes);
  } catch {
    fail("ASC_PRIVATE_KEY_INVALID", "App Store Connect private key is not a valid private key");
  } finally {
    privateKeyBytes.fill(0);
  }
  if (privateKey.asymmetricKeyType !== "ec") {
    fail("ASC_PRIVATE_KEY_INVALID", "App Store Connect private key must be an EC P-256 key");
  }
  const curve = privateKey.asymmetricKeyDetails?.namedCurve;
  if (curve && curve !== "prime256v1" && curve !== "P-256") {
    fail("ASC_PRIVATE_KEY_INVALID", "App Store Connect private key must use the P-256 curve");
  }

  let signature;
  try {
    signature = sign("sha256", Buffer.from(signingInput, "utf8"), {
      key: privateKey,
      dsaEncoding: "ieee-p1363",
    });
  } catch {
    fail("ASC_PRIVATE_KEY_INVALID", "App Store Connect JWT signing failed");
  }
  if (signature.length !== 64) {
    fail("ASC_PRIVATE_KEY_INVALID", "App Store Connect JWT signature has an invalid ES256 encoding");
  }
  return `${signingInput}.${signature.toString("base64url")}`;
}

export function assertAscUrl(input) {
  let url;
  try {
    url = input instanceof URL ? new URL(input.href) : new URL(String(input));
  } catch {
    fail("ASC_INVALID_URL", "App Store Connect URL is invalid");
  }
  if (
    url.protocol !== "https:" ||
    url.hostname !== "api.appstoreconnect.apple.com" ||
    (url.port !== "" && url.port !== "443") ||
    url.username !== "" ||
    url.password !== "" ||
    url.hash !== "" ||
    (!url.pathname.startsWith("/v1/") && url.pathname !== "/v1/apps")
  ) {
    fail("ASC_UNSAFE_URL", "App Store Connect requests must use the fixed HTTPS API host and a /v1 path");
  }
  return url;
}

function makeAscUrl(endpointPath, query = {}) {
  if (typeof endpointPath !== "string" || !endpointPath.startsWith("/v1/")) {
    fail("ASC_INVALID_ENDPOINT", "App Store Connect endpoint must be a relative /v1 path");
  }
  if (endpointPath.includes("?") || endpointPath.includes("#") || endpointPath.includes("\\")) {
    fail("ASC_INVALID_ENDPOINT", "App Store Connect endpoint must not contain a query, fragment, or backslash");
  }
  const url = assertAscUrl(`${ASC_ORIGIN}${endpointPath}`);
  for (const [key, value] of Object.entries(query)) {
    if (value === undefined || value === null || value === "") continue;
    if (Array.isArray(value)) {
      for (const item of value) url.searchParams.append(key, String(item));
    } else {
      url.searchParams.set(key, String(value));
    }
  }
  return url;
}

async function readResponseBody(response, maxResponseBytes) {
  const declaredLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > maxResponseBytes) {
    try {
      await response.body?.cancel();
    } catch {
      // The response is already being rejected; cancellation is best effort.
    }
    fail("ASC_RESPONSE_TOO_LARGE", "App Store Connect response exceeds the configured size limit");
  }
  if (!response.body) return Buffer.alloc(0);

  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxResponseBytes) {
        try {
          await reader.cancel();
        } catch {
          // Ignore cancellation failure while rejecting an oversized body.
        }
        fail("ASC_RESPONSE_TOO_LARGE", "App Store Connect response exceeds the configured size limit");
      }
      chunks.push(Buffer.from(value));
    }
  } finally {
    reader.releaseLock();
  }
  return Buffer.concat(chunks, total);
}

export async function defaultAscTransport({ url, method, headers, signal, maxResponseBytes }) {
  if (method !== "GET") {
    fail("ASC_MUTATION_FORBIDDEN", "The App Store Connect snapshot transport permits GET only");
  }
  let response;
  try {
    response = await fetch(url, {
      method: "GET",
      headers,
      signal,
      redirect: "manual",
    });
  } catch (error) {
    if (error?.name === "AbortError" || signal?.aborted) {
      fail("ASC_TIMEOUT", "App Store Connect request timed out");
    }
    fail("ASC_NETWORK_ERROR", "App Store Connect request failed before a response was received");
  }
  const body = await readResponseBody(response, maxResponseBytes);
  return {
    status: response.status,
    headers: Object.fromEntries(response.headers.entries()),
    body,
  };
}

function responseHeader(headers, name) {
  if (!headers) return null;
  if (typeof headers.get === "function") return headers.get(name);
  const wanted = name.toLowerCase();
  for (const [key, value] of Object.entries(headers)) {
    if (key.toLowerCase() === wanted) return String(value);
  }
  return null;
}

function normalizeTransportBody(body) {
  if (Buffer.isBuffer(body)) return body;
  if (body instanceof Uint8Array) return Buffer.from(body);
  if (typeof body === "string") return Buffer.from(body, "utf8");
  fail("ASC_TRANSPORT_INVALID", "App Store Connect transport returned an invalid response body");
}

function ensureJsonApiCollection(json) {
  if (!json || typeof json !== "object" || Array.isArray(json) || !Array.isArray(json.data)) {
    fail("ASC_RESPONSE_INVALID", "App Store Connect response is not a JSON:API collection");
  }
  if (json.included !== undefined && !Array.isArray(json.included)) {
    fail("ASC_RESPONSE_INVALID", "App Store Connect included resources are invalid");
  }
  if (json.links !== undefined && (json.links === null || typeof json.links !== "object" || Array.isArray(json.links))) {
    fail("ASC_RESPONSE_INVALID", "App Store Connect pagination links are invalid");
  }
}

function paginationInvariantEntries(url) {
  return [...url.searchParams.entries()]
    .filter(([key]) => key !== "cursor")
    .sort(([leftKey, leftValue], [rightKey, rightValue]) =>
      leftKey.localeCompare(rightKey) || leftValue.localeCompare(rightValue),
    );
}

export function createAscClient({
  transport = defaultAscTransport,
  tokenProvider = ({ scope }) => createTeamApiJwt({ scope }),
  timeoutMs = DEFAULT_TIMEOUT_MS,
  maxResponseBytes = DEFAULT_MAX_RESPONSE_BYTES,
  maxPages = DEFAULT_MAX_PAGES,
} = {}) {
  if (typeof transport !== "function" || typeof tokenProvider !== "function") {
    fail("INVALID_INPUT", "transport and token provider must be functions");
  }
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 100 || timeoutMs > 60_000) {
    fail("INVALID_INPUT", "timeout must be between 100 and 60000 milliseconds");
  }
  if (!Number.isSafeInteger(maxResponseBytes) || maxResponseBytes < 256 || maxResponseBytes > 16_777_216) {
    fail("INVALID_INPUT", "response size limit must be between 256 bytes and 16 MiB");
  }
  if (!Number.isSafeInteger(maxPages) || maxPages < 1 || maxPages > 50) {
    fail("INVALID_INPUT", "pagination limit must be between 1 and 50 pages");
  }

  async function getPage(url) {
    const safeUrl = assertAscUrl(url);
    const scope = `GET ${safeUrl.pathname}${safeUrl.search}`;
    let token;
    try {
      token = await tokenProvider({ scope, url: new URL(safeUrl.href) });
    } catch (error) {
      if (error instanceof AscSnapshotError) throw error;
      fail("ASC_AUTHENTICATION_FAILED", "App Store Connect authentication token could not be created");
    }
    if (typeof token !== "string" || token.length < 8 || /\s/u.test(token)) {
      fail("ASC_AUTHENTICATION_FAILED", "App Store Connect authentication token is invalid");
    }

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    let response;
    try {
      response = await transport({
        url: new URL(safeUrl.href),
        method: "GET",
        headers: {
          accept: "application/json",
          authorization: `Bearer ${token}`,
        },
        signal: controller.signal,
        maxResponseBytes,
      });
    } catch (error) {
      if (error instanceof AscSnapshotError) throw error;
      if (error?.name === "AbortError" || controller.signal.aborted) {
        fail("ASC_TIMEOUT", "App Store Connect request timed out");
      }
      fail("ASC_NETWORK_ERROR", "App Store Connect request failed before a response was received");
    } finally {
      clearTimeout(timeout);
      token = "";
    }

    if (!response || !Number.isInteger(response.status)) {
      fail("ASC_TRANSPORT_INVALID", "App Store Connect transport returned an invalid response");
    }
    const body = normalizeTransportBody(response.body);
    if (body.byteLength > maxResponseBytes) {
      fail("ASC_RESPONSE_TOO_LARGE", "App Store Connect response exceeds the configured size limit");
    }
    const location = responseHeader(response.headers, "location");
    if (response.status >= 300 && response.status < 400) {
      if (location) {
        try {
          assertAscUrl(new URL(location, safeUrl));
        } catch {
          fail("ASC_CROSS_ORIGIN_REDIRECT", "App Store Connect returned an unsafe redirect");
        }
      }
      fail("ASC_REDIRECT_REJECTED", "App Store Connect redirects are not followed by the read-only client");
    }
    if (response.status === 401) {
      fail("ASC_AUTHENTICATION_FAILED", "App Store Connect rejected the API credentials", { status: 401 });
    }
    if (response.status === 403) {
      fail("ASC_AUTHORIZATION_FAILED", "App Store Connect API key is not authorized for this GET request", { status: 403 });
    }
    if (response.status === 429) {
      const retryAfter = responseHeader(response.headers, "retry-after");
      const suffix = retryAfter && /^[0-9]{1,8}$/.test(retryAfter)
        ? `; retry after ${retryAfter} seconds`
        : "";
      fail("ASC_RATE_LIMITED", `App Store Connect rate limit was reached${suffix}`, { status: 429 });
    }
    if (response.status < 200 || response.status >= 300) {
      fail("ASC_HTTP_ERROR", `App Store Connect returned HTTP ${response.status}`, {
        status: response.status,
      });
    }

    const contentType = responseHeader(response.headers, "content-type");
    if (contentType && !/^application\/(?:vnd\.api\+)?json(?:;|$)/iu.test(contentType.trim())) {
      fail("ASC_RESPONSE_INVALID", "App Store Connect returned a non-JSON response");
    }
    let json;
    try {
      json = JSON.parse(body.toString("utf8"));
    } catch {
      fail("ASC_RESPONSE_INVALID", "App Store Connect returned malformed JSON");
    }
    ensureJsonApiCollection(json);
    return {
      json,
      evidence: {
        method: "GET",
        pathAndQuery: `${safeUrl.pathname}${safeUrl.search}`,
        status: response.status,
        responseBytes: body.byteLength,
        responseSHA256: createHash("sha256").update(body).digest("hex"),
      },
    };
  }

  async function getCollection(endpointPath, query = {}) {
    const initialUrl = makeAscUrl(endpointPath, query);
    if (initialUrl.searchParams.has("cursor")) {
      fail("ASC_INVALID_ENDPOINT", "initial App Store Connect query must not contain a pagination cursor");
    }
    const invariantQuery = canonicalJSONString(paginationInvariantEntries(initialUrl));
    let nextUrl = initialUrl;
    const seen = new Set();
    const seenCursors = new Set();
    const data = [];
    const included = [];
    const requests = [];
    let pageCount = 0;

    while (nextUrl) {
      if (pageCount >= maxPages) {
        fail("ASC_PAGINATION_LIMIT", `App Store Connect response exceeded the ${maxPages}-page limit`);
      }
      const safeNextUrl = assertAscUrl(nextUrl);
      if (seen.has(safeNextUrl.href)) {
        fail("ASC_PAGINATION_LOOP", "App Store Connect returned a repeated pagination URL");
      }
      seen.add(safeNextUrl.href);
      const page = await getPage(safeNextUrl);
      pageCount += 1;
      data.push(...page.json.data);
      included.push(...(page.json.included ?? []));
      requests.push(page.evidence);
      const rawNext = page.json.links?.next ?? null;
      if (rawNext === null) {
        nextUrl = null;
      } else if (typeof rawNext === "string" && rawNext.length > 0) {
        let resolved;
        try {
          resolved = new URL(rawNext, safeNextUrl);
        } catch {
          fail("ASC_RESPONSE_INVALID", "App Store Connect returned an invalid pagination URL");
        }
        const safeResolved = assertAscUrl(resolved);
        if (
          safeResolved.pathname !== initialUrl.pathname ||
          canonicalJSONString(paginationInvariantEntries(safeResolved)) !== invariantQuery
        ) {
          fail(
            "ASC_PAGINATION_DRIFT",
            "App Store Connect next-page link changed the endpoint or non-cursor query parameters",
          );
        }
        const cursors = safeResolved.searchParams.getAll("cursor");
        if (cursors.length !== 1 || cursors[0].length === 0 || cursors[0].length > 4096) {
          fail("ASC_PAGINATION_INVALID", "App Store Connect next-page link must contain one bounded cursor");
        }
        if (seenCursors.has(cursors[0])) {
          fail("ASC_PAGINATION_LOOP", "App Store Connect returned a repeated pagination cursor");
        }
        seenCursors.add(cursors[0]);
        nextUrl = new URL(initialUrl.href);
        nextUrl.searchParams.set("cursor", cursors[0]);
      } else {
        fail("ASC_RESPONSE_INVALID", "App Store Connect returned an invalid next-page link");
      }
    }
    return { data, included, requests, pageCount };
  }

  return Object.freeze({ getCollection });
}

function requireResource(resource, type, label) {
  if (!resource || typeof resource !== "object" || Array.isArray(resource)) {
    fail("ASC_RESPONSE_INVALID", `${label} resource is missing`);
  }
  if (resource.type !== type || typeof resource.id !== "string" || !RESOURCE_ID_PATTERN.test(resource.id)) {
    fail("ASC_RESPONSE_INVALID", `${label} resource has an invalid type or ID`);
  }
  if (!resource.attributes || typeof resource.attributes !== "object" || Array.isArray(resource.attributes)) {
    fail("ASC_RESPONSE_INVALID", `${label} resource attributes are missing`);
  }
  return resource;
}

function relationshipId(resource, relationship, type, label) {
  const linkage = resource?.relationships?.[relationship]?.data;
  if (!linkage || Array.isArray(linkage) || linkage.type !== type || !RESOURCE_ID_PATTERN.test(linkage.id ?? "")) {
    fail("ASC_RESPONSE_INVALID", `${label} relationship is missing or invalid`);
  }
  return linkage.id;
}

function indexIncluded(resources) {
  const index = new Map();
  for (const resource of resources) {
    if (!resource || typeof resource !== "object" || Array.isArray(resource)) {
      fail("ASC_RESPONSE_INVALID", "App Store Connect included resource is invalid");
    }
    const key = `${resource.type}:${resource.id}`;
    if (index.has(key) && canonicalJSONString(index.get(key)) !== canonicalJSONString(resource)) {
      fail("ASC_RESPONSE_INVALID", `App Store Connect returned conflicting included resource ${key}`);
    }
    index.set(key, resource);
  }
  return index;
}

export async function findUniqueApp(client, bundleId) {
  validateCaptureQuery({ bundleId });
  const collection = await client.getCollection("/v1/apps", {
    "filter[bundleId]": bundleId,
    "fields[apps]": "name,bundleId,sku,primaryLocale,contentRightsDeclaration,isOrEverWasMadeForKids",
    limit: "200",
  });
  const matches = collection.data.filter((item) =>
    item?.type === "apps" && item?.attributes?.bundleId === bundleId,
  );
  if (matches.length === 0) {
    fail("ASC_APP_NOT_FOUND", `No App Store Connect app matches bundle ID ${bundleId}`);
  }
  if (matches.length !== 1) {
    fail("ASC_APP_NOT_UNIQUE", `App Store Connect returned ${matches.length} apps for bundle ID ${bundleId}`);
  }
  return { app: requireResource(matches[0], "apps", "app"), requests: collection.requests };
}

function normalizedApp(resource) {
  if (
    typeof resource.attributes.bundleId !== "string" ||
    typeof resource.attributes.name !== "string" ||
    resource.attributes.name.length === 0 ||
    typeof resource.attributes.sku !== "string" ||
    resource.attributes.sku.length === 0 ||
    typeof resource.attributes.primaryLocale !== "string" ||
    resource.attributes.primaryLocale.length === 0
  ) {
    fail("ASC_RESPONSE_INVALID", "App Store Connect app attributes are incomplete");
  }
  return {
    resourceID: resource.id,
    bundleID: resource.attributes.bundleId,
    name: resource.attributes.name ?? null,
    sku: resource.attributes.sku ?? null,
    primaryLocale: resource.attributes.primaryLocale ?? null,
    contentRightsDeclaration: resource.attributes.contentRightsDeclaration ?? null,
    isOrEverWasMadeForKids: resource.attributes.isOrEverWasMadeForKids ?? null,
  };
}

function inspectBindingFile(filePath, label, { retainBytes = true } = {}) {
  assertString(filePath, `${label} path`);
  if (!isAbsolute(filePath)) fail("UNSAFE_PATH", `${label} path must be absolute`);
  let canonical;
  try {
    canonical = realpathSync(filePath);
  } catch {
    fail("UNSAFE_PATH", `${label} path cannot be resolved`);
  }
  if (canonical !== filePath) fail("UNSAFE_PATH", `${label} path must not traverse symlinks`);
  const observation = readRegularFileNoFollow(filePath, label, { retainBytes });
  const { bytes, byteLength, sha256, stat: fileStat } = observation;
  return {
    path: filePath,
    sha256,
    byteLength,
    device: fileStat.dev,
    inode: fileStat.ino,
    mode: fileStat.mode,
    ...(retainBytes ? { bytes } : {}),
  };
}

function productionBundleID(value) {
  if (
    typeof value !== "string" ||
    value.length > 255 ||
    !/^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$/u.test(value)
  ) return false;
  const normalized = value.toLowerCase();
  return !normalized.startsWith("local.") &&
    !normalized.includes("example") &&
    !normalized.includes("yourname") &&
    !normalized.includes("yourdomain") &&
    !normalized.includes("placeholder") &&
    !normalized.endsWith(".invalid");
}

function assertObservationUnchanged(original, label) {
  const current = inspectBindingFile(original.path, label, {
    retainBytes: Object.hasOwn(original, "bytes"),
  });
  if (
    current.sha256 !== original.sha256 ||
    current.byteLength !== original.byteLength ||
    current.device !== original.device ||
    current.inode !== original.inode
  ) {
    fail("BINDING_CHANGED", `${label} changed while App Store Connect evidence was evaluated`);
  }
  return current;
}

function validateIdentityLock(binding, {
  projectRoot = DEFAULT_PROJECT_ROOT,
  bundleId,
  platform,
  now = new Date(),
} = {}) {
  let canonicalProjectRoot;
  try {
    canonicalProjectRoot = realpathSync(projectRoot);
  } catch {
    fail("IDENTITY_LOCK_INVALID", "project root cannot be resolved");
  }
  if (canonicalProjectRoot !== projectRoot) {
    fail("IDENTITY_LOCK_INVALID", "project root must be an absolute canonical directory");
  }
  const requiredLockPath = join(canonicalProjectRoot, ".release", "identity.lock.json");
  if (binding.path !== requiredLockPath) {
    fail("IDENTITY_LOCK_PATH_INVALID", "release identity lock must be the repository .release/identity.lock.json");
  }
  if ((binding.mode & 0o077) !== 0) {
    fail("IDENTITY_LOCK_INVALID", "release identity lock must not be accessible to group or other users");
  }

  let parsed;
  try {
    parsed = JSON.parse(binding.bytes.toString("utf8"));
  } catch {
    fail("IDENTITY_LOCK_INVALID", "release identity lock must contain valid JSON");
  }
  requireExactObjectKeys(parsed, [
    "schemaVersion",
    "firstAppliedAt",
    "identity",
    "provisioningProfile",
    "generatedEntitlements",
    "appliedFiles",
  ], "release identity lock envelope", "IDENTITY_LOCK_INVALID");
  if (
    parsed.schemaVersion !== 1 ||
    typeof parsed.firstAppliedAt !== "string" ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/u.test(parsed.firstAppliedAt) ||
    !Number.isFinite(Date.parse(parsed.firstAppliedAt))
  ) {
    fail("IDENTITY_LOCK_INVALID", "release identity lock envelope has an invalid schema or timestamp");
  }
  const identity = parsed.identity;
  requireExactObjectKeys(identity, [
    "schemaVersion",
    "appStoreRecordMode",
    "macOSAppBundleIdentifier",
    "iOSAppBundleIdentifier",
    "iOSWidgetBundleIdentifier",
    "teamIdentifier",
    "iCloudContainerIdentifier",
    "cloudKit",
  ], "release identity payload", "IDENTITY_LOCK_INVALID");
  requireExactObjectKeys(identity.cloudKit, Object.keys(PRODUCTION_CLOUDKIT_CONTRACT),
    "release identity CloudKit contract", "IDENTITY_LOCK_INVALID");
  if (
    identity.schemaVersion !== 2 ||
    !["universal-purchase", "separate-records"].includes(identity.appStoreRecordMode) ||
    !productionBundleID(identity.macOSAppBundleIdentifier) ||
    !productionBundleID(identity.iOSAppBundleIdentifier) ||
    !productionBundleID(identity.iOSWidgetBundleIdentifier) ||
    identity.iOSWidgetBundleIdentifier !== `${identity.iOSAppBundleIdentifier}.liveactivity` ||
    (identity.appStoreRecordMode === "universal-purchase" &&
      identity.macOSAppBundleIdentifier !== identity.iOSAppBundleIdentifier) ||
    (identity.appStoreRecordMode === "separate-records" &&
      identity.macOSAppBundleIdentifier === identity.iOSAppBundleIdentifier) ||
    typeof identity.teamIdentifier !== "string" ||
    !/^[A-Z0-9]{10}$/u.test(identity.teamIdentifier) ||
    identity.teamIdentifier === "YOURTEAMID" ||
    typeof identity.iCloudContainerIdentifier !== "string" ||
    !identity.iCloudContainerIdentifier.startsWith("iCloud.") ||
    !productionBundleID(identity.iCloudContainerIdentifier.replace(/^iCloud\./u, "")) ||
    canonicalJSONString(identity.cloudKit) !== canonicalJSONString(PRODUCTION_CLOUDKIT_CONTRACT)
  ) {
    fail("IDENTITY_LOCK_INVALID", "release identity payload is not a complete production schemaVersion 2 identity");
  }
  const allowedBundles = new Set([
    identity.macOSAppBundleIdentifier,
    identity.iOSAppBundleIdentifier,
  ]);
  if (!allowedBundles.has(bundleId)) {
    fail("IDENTITY_LOCK_BUNDLE_MISMATCH", "query bundle ID is not an App bundle permitted by the release identity lock");
  }
  if (
    platform !== undefined &&
    bundleId !== (normalizePlatform(platform) === "IOS"
      ? identity.iOSAppBundleIdentifier
      : identity.macOSAppBundleIdentifier)
  ) {
    fail("IDENTITY_LOCK_BUNDLE_MISMATCH", "query platform and bundle ID do not match the release identity lock");
  }

  if (!Array.isArray(parsed.appliedFiles) || parsed.appliedFiles.length !== APPLIED_IDENTITY_PATHS.length) {
    fail("IDENTITY_LOCK_INVALID", "release identity lock must contain exactly three applied-file records");
  }
  const appliedByPath = new Map();
  for (const entry of parsed.appliedFiles) {
    requireExactObjectKeys(entry, ["path", "sha256"], "release identity applied-file record",
      "IDENTITY_LOCK_INVALID");
    if (
      !APPLIED_IDENTITY_PATHS.includes(entry.path) ||
      !SHA256_PATTERN.test(entry.sha256 ?? "") ||
      appliedByPath.has(entry.path)
    ) {
      fail("IDENTITY_LOCK_INVALID", "release identity applied-file records are incomplete or duplicated");
    }
    appliedByPath.set(entry.path, entry.sha256);
  }
  const observations = [];
  for (const relativePath of APPLIED_IDENTITY_PATHS) {
    const observation = inspectBindingFile(join(canonicalProjectRoot, relativePath),
      `identity-applied file ${relativePath}`);
    if (observation.sha256 !== appliedByPath.get(relativePath)) {
      fail("IDENTITY_LOCK_INVALID", `identity-applied file hash does not match ${relativePath}`);
    }
    observations.push({ observation, label: `identity-applied file ${relativePath}` });
  }

  const bothNull = parsed.provisioningProfile === null && parsed.generatedEntitlements === null;
  const bothObjects = parsed.provisioningProfile && parsed.generatedEntitlements &&
    typeof parsed.provisioningProfile === "object" &&
    !Array.isArray(parsed.provisioningProfile) &&
    typeof parsed.generatedEntitlements === "object" &&
    !Array.isArray(parsed.generatedEntitlements);
  if (!bothNull && !bothObjects) {
    fail("IDENTITY_LOCK_INVALID", "provisioning profile and generated entitlements must both be null or objects");
  }
  if (bothObjects) {
    requireExactObjectKeys(parsed.provisioningProfile, [
      "sha256",
      "uuid",
      "name",
      "expiration",
      "applicationIdentifier",
      "appIDPrefix",
    ], "release identity provisioning profile", "IDENTITY_LOCK_INVALID");
    requireExactObjectKeys(parsed.generatedEntitlements, ["path", "sha256"],
      "release identity generated entitlements", "IDENTITY_LOCK_INVALID");
    const profile = parsed.provisioningProfile;
    const expirationTime = Date.parse(profile.expiration);
    const nowTime = now instanceof Date ? now.getTime() : new Date(now).getTime();
    if (
      !SHA256_PATTERN.test(profile.sha256 ?? "") ||
      typeof profile.uuid !== "string" || profile.uuid.length === 0 ||
      typeof profile.name !== "string" || profile.name.length === 0 ||
      typeof profile.expiration !== "string" ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/u.test(profile.expiration) ||
      !Number.isFinite(expirationTime) || !Number.isFinite(nowTime) || expirationTime <= nowTime ||
      typeof profile.appIDPrefix !== "string" || !/^[A-Z0-9]+$/u.test(profile.appIDPrefix) ||
      profile.applicationIdentifier !== `${profile.appIDPrefix}.${identity.macOSAppBundleIdentifier}` ||
      parsed.generatedEntitlements.path !== ".release/CloudKit.entitlements" ||
      !SHA256_PATTERN.test(parsed.generatedEntitlements.sha256 ?? "")
    ) {
      fail("IDENTITY_LOCK_INVALID", "release identity profile or entitlements record is invalid");
    }
    const entitlementsObservation = inspectBindingFile(
      join(canonicalProjectRoot, ".release", "CloudKit.entitlements"),
      "generated release entitlements",
    );
    if (entitlementsObservation.sha256 !== parsed.generatedEntitlements.sha256) {
      fail("IDENTITY_LOCK_INVALID", "generated release entitlements hash does not match the identity lock");
    }
    observations.push({ observation: entitlementsObservation, label: "generated release entitlements" });
  }

  return {
    normalized: canonicalValue(identity),
    observations,
  };
}

function assertBindingUnchanged(original, label) {
  return assertObservationUnchanged(original, label);
}

function publicCandidateBinding(artifact, identityLock) {
  return {
    artifactPath: artifact.path,
    artifactSHA256: artifact.sha256,
    artifactByteLength: artifact.byteLength,
    releaseIdentityLockPath: identityLock.path,
    releaseIdentityLockSHA256: identityLock.sha256,
    releaseIdentityLockByteLength: identityLock.byteLength,
  };
}

function snapshotTimes(now) {
  const date = now instanceof Date ? new Date(now.getTime()) : new Date(now);
  if (!Number.isFinite(date.getTime())) fail("INVALID_INPUT", "snapshot time is invalid");
  return {
    capturedAt: date.toISOString(),
    expiresAt: new Date(date.getTime() + SNAPSHOT_MAX_AGE_SECONDS * 1000).toISOString(),
  };
}

function canonicalValue(value) {
  if (value === null || typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) fail("SNAPSHOT_INVALID", "snapshot contains a non-finite number");
    return value;
  }
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (value && typeof value === "object") {
    const result = {};
    for (const key of Object.keys(value).sort()) {
      if (value[key] === undefined) fail("SNAPSHOT_INVALID", "snapshot contains an undefined value");
      result[key] = canonicalValue(value[key]);
    }
    return result;
  }
  fail("SNAPSHOT_INVALID", "snapshot contains a non-JSON value");
}

export function canonicalJSONString(value) {
  return JSON.stringify(canonicalValue(value));
}

export function sealSnapshot(snapshot) {
  if (snapshot?.evidenceSHA256 !== undefined) {
    fail("SNAPSHOT_INVALID", "snapshot is already sealed");
  }
  const evidenceSHA256 = createHash("sha256")
    .update(canonicalJSONString(snapshot), "utf8")
    .digest("hex");
  return { ...snapshot, evidenceSHA256 };
}

function normalizeIssueArray(value, label) {
  if (value === undefined) return [];
  if (!Array.isArray(value)) fail("ASC_RESPONSE_INVALID", `${label} must be an array`);
  return value.map((detail) => {
    if (!detail || typeof detail !== "object" || Array.isArray(detail)) {
      fail("ASC_RESPONSE_INVALID", `${label} contains an invalid state detail`);
    }
    return canonicalValue(detail);
  });
}

export async function captureAppSnapshot({
  client,
  bundleId,
  artifactPath,
  identityLockPath,
  projectRoot = DEFAULT_PROJECT_ROOT,
  now = new Date(),
}) {
  validateCaptureQuery({ bundleId });
  const artifact = inspectBindingFile(artifactPath, "release artifact", { retainBytes: false });
  const identityLock = inspectBindingFile(identityLockPath, "release identity lock");
  const identityValidation = validateIdentityLock(identityLock, { projectRoot, bundleId, now });
  const { app, requests } = await findUniqueApp(client, bundleId);
  if (app.attributes.bundleId !== bundleId) fail("ASC_APP_MISMATCH", "App Store Connect app bundle ID changed unexpectedly");
  assertBindingUnchanged(artifact, "release artifact");
  const currentIdentityLock = assertBindingUnchanged(identityLock, "release identity lock");
  validateIdentityLock(currentIdentityLock, { projectRoot, bundleId, now });
  for (const item of identityValidation.observations) {
    assertObservationUnchanged(item.observation, item.label);
  }

  return sealSnapshot({
    schemaVersion: SNAPSHOT_SCHEMA_VERSION,
    kind: "app-store-connect-app-snapshot",
    readOnly: true,
    appleAPIOrigin: ASC_ORIGIN,
    ...snapshotTimes(now),
    query: { bundleID: bundleId },
    candidate: publicCandidateBinding(artifact, identityLock),
    releaseIdentity: identityValidation.normalized,
    resourceIDs: { app: app.id },
    app: normalizedApp(app),
    requestEvidence: requests,
    readiness: {
      candidateBindingsVerified: true,
      appResourceUnique: true,
      snapshotReady: true,
    },
  });
}

export async function captureBuildSnapshot({
  client,
  bundleId,
  platform,
  version,
  build,
  artifactPath,
  identityLockPath,
  projectRoot = DEFAULT_PROJECT_ROOT,
  now = new Date(),
}) {
  validateCaptureQuery({ bundleId, platform, version, build });
  const normalizedPlatform = normalizePlatform(platform);
  const artifact = inspectBindingFile(artifactPath, "release artifact", { retainBytes: false });
  const identityLock = inspectBindingFile(identityLockPath, "release identity lock");
  const identityValidation = validateIdentityLock(identityLock, {
    projectRoot,
    bundleId,
    platform: normalizedPlatform,
    now,
  });
  const appResult = await findUniqueApp(client, bundleId);
  const app = appResult.app;
  const normalizedInitialApp = normalizedApp(app);
  const collection = await client.getCollection("/v1/builds", {
    "filter[app]": app.id,
    "filter[version]": build,
    "filter[preReleaseVersion.version]": version,
    "filter[preReleaseVersion.platform]": normalizedPlatform,
    include: "app,preReleaseVersion,buildUpload",
    "fields[apps]": "name,bundleId,sku,primaryLocale,contentRightsDeclaration,isOrEverWasMadeForKids",
    "fields[builds]": "version,uploadedDate,expirationDate,expired,processingState,buildAudienceType,usesNonExemptEncryption,app,preReleaseVersion,buildUpload",
    "fields[preReleaseVersions]": "version,platform,app",
    "fields[buildUploads]": "cfBundleShortVersionString,cfBundleVersion,createdDate,state,platform,uploadedDate,build",
    limit: "200",
  });
  const exactBuilds = collection.data.filter((resource) =>
    resource?.type === "builds" && resource?.attributes?.version === build,
  );
  if (exactBuilds.length === 0) {
    fail("ASC_BUILD_NOT_FOUND", `No App Store Connect build matches ${normalizedPlatform} ${version} (${build})`);
  }
  if (exactBuilds.length !== 1) {
    fail("ASC_BUILD_NOT_UNIQUE", `App Store Connect returned ${exactBuilds.length} exact build matches`);
  }
  const buildResource = requireResource(exactBuilds[0], "builds", "build");
  const included = indexIncluded(collection.included);
  const appRelationshipID = relationshipId(buildResource, "app", "apps", "build-to-app");
  const preReleaseVersionID = relationshipId(
    buildResource,
    "preReleaseVersion",
    "preReleaseVersions",
    "build-to-prerelease-version",
  );
  const buildUploadID = relationshipId(
    buildResource,
    "buildUpload",
    "buildUploads",
    "build-to-upload",
  );
  if (appRelationshipID !== normalizedInitialApp.resourceID) {
    fail("ASC_RESPONSE_DRIFT", "Build response changed the App Store Connect app resource ID");
  }
  const includedAppCandidates = collection.included.filter(resource => resource?.type === "apps");
  if (includedAppCandidates.length !== 1) {
    fail("ASC_RESPONSE_DRIFT", "Build response did not include exactly one stable App resource");
  }
  let normalizedIncludedApp;
  try {
    normalizedIncludedApp = normalizedApp(
      requireResource(includedAppCandidates[0], "apps", "included app"),
    );
  } catch (error) {
    if (error instanceof AscSnapshotError && error.code === "ASC_RESPONSE_INVALID") {
      fail("ASC_RESPONSE_DRIFT", "Build response included an incomplete App representation");
    }
    throw error;
  }
  if (canonicalJSONString(normalizedIncludedApp) !== canonicalJSONString(normalizedInitialApp)) {
    fail("ASC_RESPONSE_DRIFT", "App Store Connect app metadata changed between App and Build reads");
  }
  const preReleaseVersion = requireResource(
    included.get(`preReleaseVersions:${preReleaseVersionID}`),
    "preReleaseVersions",
    "prerelease version",
  );
  let preReleaseVersionAppID;
  try {
    preReleaseVersionAppID = relationshipId(
      preReleaseVersion,
      "app",
      "apps",
      "prerelease-version-to-app",
    );
  } catch (error) {
    if (error instanceof AscSnapshotError && error.code === "ASC_RESPONSE_INVALID") {
      fail("ASC_RESPONSE_DRIFT", "Prerelease version no longer identifies the queried App resource");
    }
    throw error;
  }
  if (preReleaseVersionAppID !== normalizedInitialApp.resourceID) {
    fail("ASC_RESPONSE_DRIFT", "Prerelease version points to a different App resource");
  }
  if (
    preReleaseVersion.attributes.version !== version ||
    preReleaseVersion.attributes.platform !== normalizedPlatform
  ) {
    fail("ASC_BUILD_VERSION_MISMATCH", "Build prerelease version or platform does not match the requested candidate");
  }
  const buildUpload = requireResource(
    included.get(`buildUploads:${buildUploadID}`),
    "buildUploads",
    "build upload",
  );
  let uploadedBuildID;
  try {
    uploadedBuildID = relationshipId(
      buildUpload,
      "build",
      "builds",
      "build-upload-to-build",
    );
  } catch (error) {
    if (error instanceof AscSnapshotError && error.code === "ASC_RESPONSE_INVALID") {
      fail("ASC_RESPONSE_DRIFT", "Build upload no longer identifies the queried Build resource");
    }
    throw error;
  }
  if (uploadedBuildID !== buildResource.id) {
    fail("ASC_RESPONSE_DRIFT", "Build upload points to a different Build resource");
  }
  const uploadAttributes = buildUpload.attributes;
  if (
    uploadAttributes.cfBundleShortVersionString !== version ||
    uploadAttributes.cfBundleVersion !== build ||
    uploadAttributes.platform !== normalizedPlatform
  ) {
    fail("ASC_BUILD_UPLOAD_MISMATCH", "Build upload identity does not match the requested candidate");
  }
  if (buildResource.attributes.processingState !== "VALID") {
    fail(
      "ASC_BUILD_NOT_VALID",
      `App Store Connect build processing state is ${buildResource.attributes.processingState ?? "unknown"}, not VALID`,
    );
  }
  if (buildResource.attributes.expired !== false) {
    fail("ASC_BUILD_EXPIRED", "App Store Connect build is expired or has no explicit non-expired state");
  }
  if (buildResource.attributes.buildAudienceType !== "APP_STORE_ELIGIBLE") {
    fail("ASC_BUILD_AUDIENCE_INELIGIBLE", "App Store Connect build is not APP_STORE_ELIGIBLE");
  }
  if (typeof buildResource.attributes.usesNonExemptEncryption !== "boolean") {
    fail("ASC_BUILD_ENCRYPTION_UNRESOLVED", "App Store Connect build encryption declaration is not an explicit boolean");
  }
  if (uploadAttributes.state?.state !== "COMPLETE") {
    fail(
      "ASC_BUILD_UPLOAD_INCOMPLETE",
      `App Store Connect build upload state is ${uploadAttributes.state?.state ?? "unknown"}, not COMPLETE`,
    );
  }
  const errors = normalizeIssueArray(uploadAttributes.state.errors, "build upload errors");
  const warnings = normalizeIssueArray(uploadAttributes.state.warnings, "build upload warnings");
  const infos = normalizeIssueArray(uploadAttributes.state.infos, "build upload infos");
  const exportComplianceRequired = buildResource.attributes.usesNonExemptEncryption;
  const buildUploadErrorFree = errors.length === 0;
  const warningsPresent = warnings.length > 0;
  const snapshotReady = buildUploadErrorFree && !exportComplianceRequired;
  assertBindingUnchanged(artifact, "release artifact");
  const currentIdentityLock = assertBindingUnchanged(identityLock, "release identity lock");
  validateIdentityLock(currentIdentityLock, {
    projectRoot,
    bundleId,
    platform: normalizedPlatform,
    now,
  });
  for (const item of identityValidation.observations) {
    assertObservationUnchanged(item.observation, item.label);
  }

  return sealSnapshot({
    schemaVersion: SNAPSHOT_SCHEMA_VERSION,
    kind: "app-store-connect-build-snapshot",
    readOnly: true,
    appleAPIOrigin: ASC_ORIGIN,
    ...snapshotTimes(now),
    query: {
      bundleID: bundleId,
      platform: normalizedPlatform,
      version,
      build,
    },
    candidate: publicCandidateBinding(artifact, identityLock),
    releaseIdentity: identityValidation.normalized,
    resourceIDs: {
      app: app.id,
      preReleaseVersion: preReleaseVersion.id,
      build: buildResource.id,
      buildUpload: buildUpload.id,
    },
    app: normalizedInitialApp,
    preReleaseVersion: {
      resourceID: preReleaseVersion.id,
      version: preReleaseVersion.attributes.version,
      platform: preReleaseVersion.attributes.platform,
    },
    build: {
      resourceID: buildResource.id,
      buildNumber: buildResource.attributes.version,
      processingState: buildResource.attributes.processingState,
      uploadedDate: buildResource.attributes.uploadedDate ?? null,
      expirationDate: buildResource.attributes.expirationDate ?? null,
      expired: buildResource.attributes.expired,
      buildAudienceType: buildResource.attributes.buildAudienceType ?? null,
      usesNonExemptEncryption: buildResource.attributes.usesNonExemptEncryption ?? null,
      exportComplianceRequired,
    },
    buildUpload: {
      resourceID: buildUpload.id,
      cfBundleShortVersionString: uploadAttributes.cfBundleShortVersionString,
      cfBundleVersion: uploadAttributes.cfBundleVersion,
      platform: uploadAttributes.platform,
      createdDate: uploadAttributes.createdDate ?? null,
      uploadedDate: uploadAttributes.uploadedDate ?? null,
      state: "COMPLETE",
      errors,
      warnings,
      warningsPresent,
      infos,
      rawState: canonicalValue(uploadAttributes.state),
    },
    requestEvidence: [...appResult.requests, ...collection.requests],
    readiness: {
      candidateBindingsVerified: true,
      appResourceUnique: true,
      preReleaseVersionExact: true,
      buildResourceUnique: true,
      buildProcessingValid: true,
      buildNotExpired: true,
      appStoreEligible: true,
      encryptionDeclarationResolved: true,
      exportComplianceRequired,
      buildUploadComplete: true,
      buildUploadErrorFree,
      warningsPresent,
      snapshotReady,
    },
  });
}

function assertOutputPath(outputPath) {
  assertString(outputPath, "snapshot output path");
  if (!isAbsolute(outputPath)) fail("UNSAFE_PATH", "snapshot output path must be absolute");
  if (basename(outputPath) === "." || basename(outputPath) === ".." || !outputPath.endsWith(".json")) {
    fail("UNSAFE_PATH", "snapshot output path must name a JSON file");
  }
  const parent = dirname(outputPath);
  let canonicalParent;
  try {
    canonicalParent = realpathSync(parent);
  } catch {
    fail("UNSAFE_PATH", "snapshot output parent directory does not exist");
  }
  if (canonicalParent !== parent || !statSync(parent).isDirectory()) {
    fail("UNSAFE_PATH", "snapshot output parent must be a canonical, non-symlink directory");
  }
  if (existsSync(outputPath)) fail("SNAPSHOT_EXISTS", "refusing to overwrite an existing snapshot");
}

export function writeImmutableSnapshot(outputPath, snapshot) {
  assertOutputPath(outputPath);
  const payload = `${JSON.stringify(snapshot, null, 2)}\n`;
  const parent = dirname(outputPath);
  const temporaryPath = join(parent, `.${basename(outputPath)}.${randomBytes(8).toString("hex")}.tmp`);
  let descriptor = null;
  try {
    descriptor = openSync(temporaryPath, "wx", 0o600);
    writeFileSync(descriptor, payload, { encoding: "utf8" });
    fsyncSync(descriptor);
    fchmodSync(descriptor, 0o444);
    const temporaryStat = fstatSync(descriptor);
    closeSync(descriptor);
    descriptor = null;
    linkSync(temporaryPath, outputPath);
    const outputStat = lstatSync(outputPath);
    if (
      !outputStat.isFile() ||
      outputStat.isSymbolicLink() ||
      outputStat.dev !== temporaryStat.dev ||
      outputStat.ino !== temporaryStat.ino ||
      (outputStat.mode & 0o777) !== 0o444
    ) {
      fail("SNAPSHOT_PUBLICATION_FAILED", "published snapshot does not reference the sealed temporary inode");
    }
    unlinkSync(temporaryPath);
    try {
      const directoryDescriptor = openSync(parent, "r");
      try {
        fsyncSync(directoryDescriptor);
      } finally {
        closeSync(directoryDescriptor);
      }
    } catch {
      // The file link is already atomic; some file systems do not permit directory fsync.
    }
  } catch (error) {
    if (descriptor !== null) {
      try {
        closeSync(descriptor);
      } catch {
        // Best-effort cleanup only.
      }
    }
    try {
      if (existsSync(temporaryPath)) unlinkSync(temporaryPath);
    } catch {
      // Preserve the original failure.
    }
    if (error instanceof AscSnapshotError) throw error;
    if (error?.code === "EEXIST") fail("SNAPSHOT_EXISTS", "refusing to overwrite an existing snapshot");
    fail("SNAPSHOT_PUBLICATION_FAILED", "could not publish the immutable App Store Connect snapshot");
  }
  const published = inspectBindingFile(outputPath, "published snapshot");
  if ((published.mode & 0o777) !== 0o444) {
    fail("SNAPSHOT_PUBLICATION_FAILED", "published snapshot lost its immutable file mode");
  }
  return { path: outputPath, sha256: published.sha256 };
}

function requireExactObjectKeys(value, keys, label, code = "SNAPSHOT_INVALID") {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail(code, `${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (canonicalJSONString(actual) !== canonicalJSONString(expected)) {
    fail(code, `${label} has unexpected or missing fields`);
  }
}

function verifyCandidate(snapshot, expected, now) {
  requireExactObjectKeys(snapshot.candidate, [
    "artifactPath",
    "artifactSHA256",
    "artifactByteLength",
    "releaseIdentityLockPath",
    "releaseIdentityLockSHA256",
    "releaseIdentityLockByteLength",
  ], "snapshot candidate");
  const artifact = inspectBindingFile(expected.artifactPath, "release artifact", { retainBytes: false });
  const identityLock = inspectBindingFile(expected.identityLockPath, "release identity lock");
  const identityValidation = validateIdentityLock(identityLock, {
    projectRoot: expected.projectRoot,
    bundleId: expected.bundleId,
    platform: expected.platform,
    now,
  });
  if (
    snapshot.candidate.artifactPath !== artifact.path ||
    snapshot.candidate.artifactSHA256 !== artifact.sha256 ||
    snapshot.candidate.artifactByteLength !== artifact.byteLength ||
    snapshot.candidate.releaseIdentityLockPath !== identityLock.path ||
    snapshot.candidate.releaseIdentityLockSHA256 !== identityLock.sha256 ||
    snapshot.candidate.releaseIdentityLockByteLength !== identityLock.byteLength
  ) {
    fail("SNAPSHOT_BINDING_MISMATCH", "snapshot does not bind the expected artifact and release identity lock");
  }
  if (canonicalJSONString(snapshot.releaseIdentity) !== canonicalJSONString(identityValidation.normalized)) {
    fail("SNAPSHOT_BINDING_MISMATCH", "snapshot release identity does not match the current identity lock");
  }
  return { artifact, identityLock, identityValidation };
}

function verifyRequestEvidence(value) {
  if (!Array.isArray(value) || value.length === 0) {
    fail("SNAPSHOT_INVALID", "snapshot request evidence is missing");
  }
  for (const request of value) {
    requireExactObjectKeys(request, [
      "method",
      "pathAndQuery",
      "status",
      "responseBytes",
      "responseSHA256",
    ], "request evidence entry");
    if (
      request.method !== "GET" ||
      typeof request.pathAndQuery !== "string" ||
      !request.pathAndQuery.startsWith("/v1/") && request.pathAndQuery !== "/v1/apps" ||
      request.status !== 200 ||
      !Number.isSafeInteger(request.responseBytes) ||
      request.responseBytes < 0 ||
      !SHA256_PATTERN.test(request.responseSHA256)
    ) {
      fail("SNAPSHOT_INVALID", "snapshot request evidence is invalid");
    }
  }
}

function verifyCommonSnapshot(snapshot, expectedKind, expected, maxAgeSeconds, now) {
  if (!snapshot || typeof snapshot !== "object" || Array.isArray(snapshot)) {
    fail("SNAPSHOT_INVALID", "snapshot root must be an object");
  }
  if (
    snapshot.schemaVersion !== SNAPSHOT_SCHEMA_VERSION ||
    snapshot.kind !== expectedKind ||
    snapshot.readOnly !== true ||
    snapshot.appleAPIOrigin !== ASC_ORIGIN ||
    !SHA256_PATTERN.test(snapshot.evidenceSHA256 ?? "")
  ) {
    fail("SNAPSHOT_INVALID", "snapshot envelope is invalid or unsupported");
  }
  const commonKeys = [
    "schemaVersion",
    "kind",
    "readOnly",
    "appleAPIOrigin",
    "capturedAt",
    "expiresAt",
    "query",
    "candidate",
    "releaseIdentity",
    "resourceIDs",
    "app",
    "requestEvidence",
    "readiness",
    "evidenceSHA256",
  ];
  requireExactObjectKeys(
    snapshot,
    expectedKind === "app-store-connect-build-snapshot"
      ? [...commonKeys, "preReleaseVersion", "build", "buildUpload"]
      : commonKeys,
    "snapshot root",
  );
  const unsealed = { ...snapshot };
  delete unsealed.evidenceSHA256;
  const calculatedEvidenceSHA256 = createHash("sha256")
    .update(canonicalJSONString(unsealed), "utf8")
    .digest("hex");
  if (calculatedEvidenceSHA256 !== snapshot.evidenceSHA256) {
    fail("SNAPSHOT_TAMPERED", "snapshot evidence digest does not match its content");
  }
  const capturedAt = Date.parse(snapshot.capturedAt);
  const expiresAt = Date.parse(snapshot.expiresAt);
  const nowTime = now instanceof Date ? now.getTime() : new Date(now).getTime();
  if (!Number.isFinite(capturedAt) || !Number.isFinite(expiresAt) || !Number.isFinite(nowTime)) {
    fail("SNAPSHOT_INVALID", "snapshot timestamps are invalid");
  }
  if (expiresAt - capturedAt !== SNAPSHOT_MAX_AGE_SECONDS * 1000) {
    fail("SNAPSHOT_INVALID", "snapshot expiry window is invalid");
  }
  if (capturedAt > nowTime + 60_000) fail("SNAPSHOT_NOT_YET_VALID", "snapshot capture time is in the future");
  if (nowTime > expiresAt || nowTime - capturedAt > maxAgeSeconds * 1000) {
    fail("SNAPSHOT_EXPIRED", "App Store Connect snapshot is stale; capture a new read-only snapshot");
  }
  const candidateValidation = verifyCandidate(snapshot, expected, now);
  verifyRequestEvidence(snapshot.requestEvidence);
  return candidateValidation;
}

function verifyAppSnapshotShape(snapshot, expected) {
  validateCaptureQuery({ bundleId: expected.bundleId });
  requireExactObjectKeys(snapshot.query, ["bundleID"], "app snapshot query");
  requireExactObjectKeys(snapshot.resourceIDs, ["app"], "app snapshot resource IDs");
  requireExactObjectKeys(snapshot.app, [
    "resourceID",
    "bundleID",
    "name",
    "sku",
    "primaryLocale",
    "contentRightsDeclaration",
    "isOrEverWasMadeForKids",
  ], "app snapshot app");
  requireExactObjectKeys(snapshot.readiness, [
    "candidateBindingsVerified",
    "appResourceUnique",
    "snapshotReady",
  ], "app snapshot readiness");
  if (
    snapshot.query?.bundleID !== expected.bundleId ||
    snapshot.app?.bundleID !== expected.bundleId ||
    snapshot.app?.resourceID !== snapshot.resourceIDs?.app ||
    !RESOURCE_ID_PATTERN.test(snapshot.resourceIDs?.app ?? "") ||
    typeof snapshot.app?.name !== "string" ||
    snapshot.app.name.length === 0 ||
    typeof snapshot.app?.sku !== "string" ||
    snapshot.app.sku.length === 0 ||
    typeof snapshot.app?.primaryLocale !== "string" ||
    snapshot.app.primaryLocale.length === 0 ||
    snapshot.readiness?.candidateBindingsVerified !== true ||
    snapshot.readiness?.appResourceUnique !== true ||
    snapshot.readiness?.snapshotReady !== true
  ) {
    fail("SNAPSHOT_BINDING_MISMATCH", "app snapshot does not match the expected App Store Connect record");
  }
}

function verifyBuildSnapshotShape(snapshot, expected) {
  validateCaptureQuery(expected);
  const platform = normalizePlatform(expected.platform);
  requireExactObjectKeys(snapshot.query, ["bundleID", "platform", "version", "build"], "build snapshot query");
  requireExactObjectKeys(snapshot.resourceIDs, [
    "app",
    "preReleaseVersion",
    "build",
    "buildUpload",
  ], "build snapshot resource IDs");
  requireExactObjectKeys(snapshot.app, [
    "resourceID",
    "bundleID",
    "name",
    "sku",
    "primaryLocale",
    "contentRightsDeclaration",
    "isOrEverWasMadeForKids",
  ], "build snapshot app");
  requireExactObjectKeys(snapshot.preReleaseVersion, [
    "resourceID",
    "version",
    "platform",
  ], "build snapshot prerelease version");
  requireExactObjectKeys(snapshot.build, [
    "resourceID",
    "buildNumber",
    "processingState",
    "uploadedDate",
    "expirationDate",
    "expired",
    "buildAudienceType",
    "usesNonExemptEncryption",
    "exportComplianceRequired",
  ], "build snapshot build");
  requireExactObjectKeys(snapshot.buildUpload, [
    "resourceID",
    "cfBundleShortVersionString",
    "cfBundleVersion",
    "platform",
    "createdDate",
    "uploadedDate",
    "state",
    "errors",
    "warnings",
    "warningsPresent",
    "infos",
    "rawState",
  ], "build snapshot upload");
  requireExactObjectKeys(snapshot.readiness, [
    "candidateBindingsVerified",
    "appResourceUnique",
    "preReleaseVersionExact",
    "buildResourceUnique",
    "buildProcessingValid",
    "buildNotExpired",
    "appStoreEligible",
    "encryptionDeclarationResolved",
    "exportComplianceRequired",
    "buildUploadComplete",
    "buildUploadErrorFree",
    "warningsPresent",
    "snapshotReady",
  ], "build snapshot readiness");
  const exportComplianceRequired = snapshot.build?.usesNonExemptEncryption === true;
  const buildUploadErrorFree = Array.isArray(snapshot.buildUpload?.errors) &&
    snapshot.buildUpload.errors.length === 0;
  const warningsPresent = Array.isArray(snapshot.buildUpload?.warnings) &&
    snapshot.buildUpload.warnings.length > 0;
  const expectedSnapshotReady = buildUploadErrorFree && !exportComplianceRequired;
  if (
    snapshot.query?.bundleID !== expected.bundleId ||
    snapshot.query?.platform !== platform ||
    snapshot.query?.version !== expected.version ||
    snapshot.query?.build !== expected.build ||
    snapshot.app?.bundleID !== expected.bundleId ||
    snapshot.app?.resourceID !== snapshot.resourceIDs?.app ||
    !RESOURCE_ID_PATTERN.test(snapshot.resourceIDs?.app ?? "") ||
    typeof snapshot.app?.name !== "string" ||
    snapshot.app.name.length === 0 ||
    typeof snapshot.app?.sku !== "string" ||
    snapshot.app.sku.length === 0 ||
    typeof snapshot.app?.primaryLocale !== "string" ||
    snapshot.app.primaryLocale.length === 0 ||
    snapshot.preReleaseVersion?.resourceID !== snapshot.resourceIDs?.preReleaseVersion ||
    !RESOURCE_ID_PATTERN.test(snapshot.resourceIDs?.preReleaseVersion ?? "") ||
    snapshot.preReleaseVersion?.version !== expected.version ||
    snapshot.preReleaseVersion?.platform !== platform ||
    snapshot.build?.resourceID !== snapshot.resourceIDs?.build ||
    !RESOURCE_ID_PATTERN.test(snapshot.resourceIDs?.build ?? "") ||
    snapshot.build?.buildNumber !== expected.build ||
    snapshot.build?.processingState !== "VALID" ||
    snapshot.build?.expired !== false ||
    snapshot.build?.buildAudienceType !== "APP_STORE_ELIGIBLE" ||
    typeof snapshot.build?.usesNonExemptEncryption !== "boolean" ||
    snapshot.build?.exportComplianceRequired !== exportComplianceRequired ||
    snapshot.buildUpload?.resourceID !== snapshot.resourceIDs?.buildUpload ||
    !RESOURCE_ID_PATTERN.test(snapshot.resourceIDs?.buildUpload ?? "") ||
    snapshot.buildUpload?.cfBundleShortVersionString !== expected.version ||
    snapshot.buildUpload?.cfBundleVersion !== expected.build ||
    snapshot.buildUpload?.platform !== platform ||
    snapshot.buildUpload?.state !== "COMPLETE" ||
    !Array.isArray(snapshot.buildUpload?.errors) ||
    !Array.isArray(snapshot.buildUpload?.warnings) ||
    snapshot.buildUpload?.warningsPresent !== warningsPresent ||
    !Array.isArray(snapshot.buildUpload?.infos) ||
    snapshot.readiness?.candidateBindingsVerified !== true ||
    snapshot.readiness?.appResourceUnique !== true ||
    snapshot.readiness?.preReleaseVersionExact !== true ||
    snapshot.readiness?.buildResourceUnique !== true ||
    snapshot.readiness?.buildProcessingValid !== true ||
    snapshot.readiness?.buildNotExpired !== true ||
    snapshot.readiness?.appStoreEligible !== true ||
    snapshot.readiness?.encryptionDeclarationResolved !== true ||
    snapshot.readiness?.exportComplianceRequired !== exportComplianceRequired ||
    snapshot.readiness?.buildUploadComplete !== true ||
    snapshot.readiness?.buildUploadErrorFree !== buildUploadErrorFree ||
    snapshot.readiness?.warningsPresent !== warningsPresent ||
    snapshot.readiness?.snapshotReady !== expectedSnapshotReady
  ) {
    fail("SNAPSHOT_BINDING_MISMATCH", "build snapshot does not match the expected exact App Store Connect build");
  }
  const rawState = snapshot.buildUpload.rawState;
  if (
    !rawState ||
    typeof rawState !== "object" ||
    Array.isArray(rawState) ||
    rawState.state !== "COMPLETE" ||
    canonicalJSONString(snapshot.buildUpload.errors) !== canonicalJSONString(rawState.errors ?? []) ||
    canonicalJSONString(snapshot.buildUpload.warnings) !== canonicalJSONString(rawState.warnings ?? []) ||
    canonicalJSONString(snapshot.buildUpload.infos) !== canonicalJSONString(rawState.infos ?? [])
  ) {
    fail("SNAPSHOT_INVALID", "build upload issue arrays do not exactly preserve the raw state");
  }
}

export function verifySnapshotFile(snapshotPath, {
  kind,
  bundleId,
  platform,
  version,
  build,
  artifactPath,
  identityLockPath,
  projectRoot = DEFAULT_PROJECT_ROOT,
  maxAgeSeconds = SNAPSHOT_MAX_AGE_SECONDS,
  now = new Date(),
} = {}) {
  assertString(snapshotPath, "snapshot path");
  if (!isAbsolute(snapshotPath)) fail("UNSAFE_PATH", "snapshot path must be absolute");
  let canonical;
  try {
    canonical = realpathSync(snapshotPath);
  } catch {
    fail("SNAPSHOT_MISSING", "snapshot does not exist");
  }
  if (canonical !== snapshotPath) fail("UNSAFE_PATH", "snapshot path must not traverse symlinks");
  if (!Number.isSafeInteger(maxAgeSeconds) || maxAgeSeconds < 1 || maxAgeSeconds > SNAPSHOT_MAX_AGE_SECONDS) {
    fail("INVALID_INPUT", `maximum snapshot age must be between 1 and ${SNAPSHOT_MAX_AGE_SECONDS} seconds`);
  }
  let snapshotObservation;
  try {
    snapshotObservation = readRegularFileNoFollow(snapshotPath, "snapshot", {
      maxBytes: 4 * 1_048_576,
    });
  } catch (error) {
    if (error instanceof AscSnapshotError && error.code === "BINDING_FILE_MISSING") {
      fail("SNAPSHOT_MISSING", "snapshot does not exist");
    }
    throw error;
  }
  if ((snapshotObservation.stat.mode & 0o777) !== 0o444) {
    fail("SNAPSHOT_PERMISSIONS_INVALID", "snapshot must be a regular, non-symlink 0444 file");
  }
  let snapshot;
  try {
    snapshot = JSON.parse(snapshotObservation.bytes.toString("utf8"));
  } catch {
    fail("SNAPSHOT_INVALID", "snapshot does not contain valid JSON");
  }
  const expected = {
    bundleId,
    platform,
    version,
    build,
    artifactPath,
    identityLockPath,
    projectRoot,
  };
  const candidateValidation = verifyCommonSnapshot(snapshot, kind, expected, maxAgeSeconds, now);
  if (kind === "app-store-connect-app-snapshot") {
    verifyAppSnapshotShape(snapshot, expected);
  } else if (kind === "app-store-connect-build-snapshot") {
    verifyBuildSnapshotShape(snapshot, expected);
  } else {
    fail("INVALID_INPUT", "unsupported snapshot kind");
  }
  assertObservationUnchanged(candidateValidation.artifact, "release artifact");
  assertObservationUnchanged(candidateValidation.identityLock, "release identity lock");
  for (const item of candidateValidation.identityValidation.observations) {
    assertObservationUnchanged(item.observation, item.label);
  }
  const finalSnapshot = inspectBindingFile(snapshotPath, "snapshot");
  if (
    finalSnapshot.sha256 !== createHash("sha256").update(snapshotObservation.bytes).digest("hex") ||
    finalSnapshot.byteLength !== snapshotObservation.bytes.byteLength ||
    finalSnapshot.device !== snapshotObservation.stat.dev ||
    finalSnapshot.inode !== snapshotObservation.stat.ino ||
    (finalSnapshot.mode & 0o777) !== 0o444
  ) {
    fail("BINDING_CHANGED", "snapshot changed while it was verified");
  }
  const canonicalDetails = kind === "app-store-connect-build-snapshot"
    ? {
        app: snapshot.app,
        preReleaseVersion: snapshot.preReleaseVersion,
        build: snapshot.build,
        buildUpload: snapshot.buildUpload,
      }
    : { app: snapshot.app };
  return {
    schemaVersion: SNAPSHOT_SCHEMA_VERSION,
    kind,
    verified: true,
    verifiedAt: (now instanceof Date ? now : new Date(now)).toISOString(),
    snapshotPath,
    snapshotSHA256: finalSnapshot.sha256,
    evidenceSHA256: snapshot.evidenceSHA256,
    capturedAt: snapshot.capturedAt,
    expiresAt: snapshot.expiresAt,
    query: snapshot.query,
    candidate: snapshot.candidate,
    releaseIdentity: snapshot.releaseIdentity,
    resourceIDs: snapshot.resourceIDs,
    ...canonicalDetails,
    readiness: snapshot.readiness,
  };
}

export function formatPublicError(error, prefix = "App Store Connect snapshot failed") {
  if (error instanceof AscSnapshotError) return `${prefix} [${error.code}]: ${error.message}`;
  return `${prefix}: unexpected internal error`;
}
