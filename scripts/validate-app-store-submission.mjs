#!/usr/bin/env node

import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { isIP } from "node:net";
import {
  existsSync,
  lstatSync,
  readFileSync,
  realpathSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = realpathSync(path.resolve(path.dirname(fileURLToPath(import.meta.url)), ".."));
const DEFAULT_MANIFEST_PATH = ".release/app-store-submission.json";
const MANIFEST_ENVIRONMENT_VARIABLE = "AGENT_ISLAND_APP_STORE_SUBMISSION";
const PRODUCT_NAME = "MAC版灵动岛--Agent运行监测";
const REQUIRED_LOCALES = ["zh-Hans", "en-US"];
const PLATFORMS = ["macos", "ios"];
const MAX_MANIFEST_BYTES = 1024 * 1024;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const CONTRACT_KEYS = Object.freeze({
  manifest: [
    "schemaVersion", "productName", "recordMode", "identityLockSHA256",
    "screenshotEvidencePath", "screenshotEvidenceSHA256", "records",
  ],
  records: ["macos", "ios"],
  commonRecord: [
    "appResourceId", "bundleIdentifier", "sku", "primaryLocale", "version", "categories", "commerce",
    "review", "localizations", "screenshotSets",
  ],
  iosRecordExtension: ["widgetBundleIdentifier", "testFlight"],
  version: ["versionString", "buildNumber", "releaseMode", "scheduledReleaseAt", "copyright"],
  categories: ["primary", "secondary"],
  commerce: ["ageRating", "madeForKids", "contentRights", "eula", "digitalServicesAct", "pricing", "exportCompliance"],
  ageRating: ["questionnaireStatus", "declaredRating"],
  contentRights: ["status", "notes"],
  eula: ["type", "customText", "territories"],
  digitalServicesAct: ["traderStatus", "verificationStatus"],
  pricing: ["model", "pricePointReference", "taxCategory", "availableTerritories"],
  exportCompliance: ["usesNonExemptEncryption", "status", "documentationReference"],
  review: ["contact", "login", "notes"],
  contact: ["firstName", "lastName", "email", "phone"],
  login: ["strategy", "credentialsSecretReference", "instructions"],
  localization: [
    "locale", "name", "subtitle", "promotionalText", "description", "keywords", "whatsNew",
    "privacyPolicyURL", "supportURL", "marketingURL",
  ],
  screenshotSet: ["locale", "device", "orderedPaths"],
  testFlight: ["distribution", "feedbackEmail", "betaReviewContact", "login", "localizations"],
  testFlightLocalization: ["locale", "betaAppDescription", "whatToTest"],
});

const options = new Set(process.argv.slice(2));
for (const option of options) {
  if (option !== "--release") {
    console.error(`Unknown option: ${option}`);
    process.exit(2);
  }
}
const releaseMode = options.has("--release");

const structuralErrors = [];
const releaseBlockers = [];
const platformStructuralErrors = { macos: [], ios: [] };
const platformReleaseBlockers = { macos: [], ios: [] };

function addIssue(target, platformTarget, message, platforms = PLATFORMS) {
  if (!target.includes(message)) target.push(message);
  for (const platform of platforms) {
    if (!platformTarget[platform].includes(message)) platformTarget[platform].push(message);
  }
}

function structural(message, platforms = PLATFORMS) {
  addIssue(structuralErrors, platformStructuralErrors, message, platforms);
}

function blocker(message, platforms = PLATFORMS) {
  addIssue(releaseBlockers, platformReleaseBlockers, message, platforms);
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function canonicalJSON(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (isPlainObject(value)) {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function exactObject(value, keys, label, platforms = PLATFORMS) {
  if (!isPlainObject(value)) {
    structural(`${label} must be an object`, platforms);
    return false;
  }
  const expected = [...keys].sort();
  const actual = Object.keys(value).sort();
  const missing = expected.filter((key) => !actual.includes(key));
  const unknown = actual.filter((key) => !expected.includes(key));
  if (missing.length > 0) structural(`${label} is missing keys: ${missing.join(", ")}`, platforms);
  if (unknown.length > 0) structural(`${label} contains unknown keys: ${unknown.join(", ")}`, platforms);
  return missing.length === 0 && unknown.length === 0;
}

function expectString(value, label, platforms, { minimum = 1, maximum = 4000 } = {}) {
  if (typeof value !== "string") {
    structural(`${label} must be a string`, platforms);
    return false;
  }
  const length = Array.from(value).length;
  if (value !== value.trim()) structural(`${label} must not have leading or trailing whitespace`, platforms);
  if (length < minimum || length > maximum) {
    structural(`${label} must contain ${minimum}-${maximum} characters`, platforms);
    return false;
  }
  return value === value.trim();
}

function expectArray(value, label, platforms, minimum = 1, maximum = Number.POSITIVE_INFINITY) {
  if (!Array.isArray(value)) {
    structural(`${label} must be an array`, platforms);
    return false;
  }
  if (value.length < minimum || value.length > maximum) {
    structural(`${label} must contain ${minimum}-${maximum} entries`, platforms);
    return false;
  }
  return true;
}

// JSON.parse silently accepts duplicate object members. Submission state is
// too consequential for "last member wins", so parse once with a small strict
// RFC 8259 parser that rejects duplicates at every nesting level.
function parseStrictJSON(source, label) {
  let index = 0;
  let depth = 0;

  function fail(message) {
    throw new Error(`${label}: ${message} at byte ${Buffer.byteLength(source.slice(0, index), "utf8")}`);
  }

  function whitespace() {
    while (index < source.length && /[\x20\t\r\n]/.test(source[index])) index += 1;
  }

  function string() {
    const start = index;
    if (source[index] !== '"') fail("expected string");
    index += 1;
    while (index < source.length) {
      const character = source[index];
      if (character === '"') {
        index += 1;
        try {
          return JSON.parse(source.slice(start, index));
        } catch (error) {
          fail(`invalid string (${error.message})`);
        }
      }
      if (character === "\\") {
        index += 1;
        if (index >= source.length || !/["\\/bfnrtu]/.test(source[index])) fail("invalid escape");
        if (source[index] === "u") {
          const escape = source.slice(index + 1, index + 5);
          if (!/^[0-9a-fA-F]{4}$/.test(escape)) fail("invalid Unicode escape");
          index += 4;
        }
      } else if (character.charCodeAt(0) <= 0x1f) {
        fail("unescaped control character in string");
      }
      index += 1;
    }
    fail("unterminated string");
  }

  function value(location) {
    whitespace();
    if (depth > 100) fail("maximum nesting depth exceeded");
    const character = source[index];
    if (character === "{") return object(location);
    if (character === "[") return array(location);
    if (character === '"') return string();
    for (const [literal, parsed] of [["true", true], ["false", false], ["null", null]]) {
      if (source.startsWith(literal, index)) {
        index += literal.length;
        return parsed;
      }
    }
    const number = source.slice(index).match(/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/);
    if (number) {
      index += number[0].length;
      const parsed = Number(number[0]);
      if (!Number.isFinite(parsed)) fail("number is not finite");
      return parsed;
    }
    fail(`unexpected ${JSON.stringify(character ?? "end of input")}`);
  }

  function object(location) {
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
      const key = string();
      if (keys.has(key)) fail(`duplicate key ${JSON.stringify(key)} in ${location}`);
      keys.add(key);
      whitespace();
      if (source[index] !== ":") fail("expected colon");
      index += 1;
      result[key] = value(`${location}.${key}`);
      whitespace();
      if (source[index] === "}") {
        index += 1;
        depth -= 1;
        return result;
      }
      if (source[index] !== ",") fail("expected comma or closing brace");
      index += 1;
    }
    fail("unterminated object");
  }

  function array(location) {
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
      result.push(value(`${location}[${result.length}]`));
      whitespace();
      if (source[index] === "]") {
        index += 1;
        depth -= 1;
        return result;
      }
      if (source[index] !== ",") fail("expected comma or closing bracket");
      index += 1;
    }
    fail("unterminated array");
  }

  const parsed = value("$");
  whitespace();
  if (index !== source.length) fail("trailing content");
  return parsed;
}

function normalizedRepositoryPath(value, label, platforms = PLATFORMS) {
  if (typeof value !== "string" || value !== value.trim() || value.length < 1 || value.length > 500) {
    structural(`${label} must be a non-empty repository-relative path`);
    return null;
  }
  if (value.includes("\\") || value.includes("\0") || path.isAbsolute(value)) {
    structural(`${label} must be a repository-relative POSIX path`);
    return null;
  }
  if (path.posix.normalize(value) !== value || value === "." || value.startsWith("./")) {
    structural(`${label} must already be normalized`);
    return null;
  }
  const segments = value.split("/");
  if (segments.some((segment) => segment === "" || segment === "." || segment === "..")) {
    structural(`${label} must not contain empty, dot, or parent components`);
    return null;
  }
  const absolute = path.resolve(projectRoot, value);
  const relative = path.relative(projectRoot, absolute);
  if (relative.startsWith("..") || path.isAbsolute(relative)) {
    structural(`${label} must stay inside the repository`);
    return null;
  }
  return { relative: value, absolute };
}

function safeExistingFile(pathRecord, label) {
  if (!pathRecord || !existsSync(pathRecord.absolute)) return null;
  let current = projectRoot;
  for (const component of pathRecord.relative.split("/")) {
    current = path.join(current, component);
    let status;
    try {
      status = lstatSync(current);
    } catch (error) {
      structural(`${label} could not be inspected: ${error.message}`);
      return null;
    }
    if (status.isSymbolicLink()) {
      structural(`${label} must not contain a symbolic-link component`);
      return null;
    }
  }
  let canonical;
  try {
    canonical = realpathSync(pathRecord.absolute);
  } catch (error) {
    structural(`${label} could not be resolved: ${error.message}`);
    return null;
  }
  const relative = path.relative(projectRoot, canonical);
  if (relative.startsWith("..") || path.isAbsolute(relative)) {
    structural(`${label} canonical location must stay inside the repository`);
    return null;
  }
  const status = lstatSync(canonical);
  if (!status.isFile()) {
    structural(`${label} must be a regular file`);
    return null;
  }
  return { ...pathRecord, canonical, size: status.size, mode: status.mode & 0o777 };
}

function sha256(absolutePath) {
  return createHash("sha256").update(readFileSync(absolutePath)).digest("hex");
}

function validateSchemaContract() {
  const relativePath = "docs/release/APP_STORE_SUBMISSION.schema.json";
  const pathRecord = normalizedRepositoryPath(relativePath, "submission schema");
  const result = { path: relativePath, present: false, sha256: null, implementationKeysBound: false };
  if (!pathRecord || !existsSync(pathRecord.absolute)) {
    structural("submission schema is missing");
    return result;
  }
  const safeSchema = safeExistingFile(pathRecord, "submission schema");
  if (!safeSchema) return { ...result, present: true };
  result.present = true;
  result.sha256 = sha256(safeSchema.canonical);
  let schema;
  try {
    schema = parseStrictJSON(readFileSync(safeSchema.canonical, "utf8"), "submission schema");
  } catch (error) {
    structural(error.message);
    return result;
  }
  const checks = [
    [schema?.required, Object.keys(schema?.properties ?? {}), CONTRACT_KEYS.manifest, "manifest"],
    [schema?.properties?.records?.required, Object.keys(schema?.properties?.records?.properties ?? {}), CONTRACT_KEYS.records, "records"],
    [schema?.$defs?.commonRecordProperties?.required, Object.keys(schema?.$defs?.commonRecordProperties?.properties ?? {}), CONTRACT_KEYS.commonRecord, "commonRecord"],
    [schema?.$defs?.iosRecord?.allOf?.[1]?.required, Object.keys(schema?.$defs?.iosRecord?.allOf?.[1]?.properties ?? {}), CONTRACT_KEYS.iosRecordExtension, "iosRecordExtension"],
    [schema?.$defs?.version?.required, Object.keys(schema?.$defs?.version?.properties ?? {}), CONTRACT_KEYS.version, "version"],
    [schema?.$defs?.categories?.required, Object.keys(schema?.$defs?.categories?.properties ?? {}), CONTRACT_KEYS.categories, "categories"],
    [schema?.$defs?.commerce?.required, Object.keys(schema?.$defs?.commerce?.properties ?? {}), CONTRACT_KEYS.commerce, "commerce"],
    [schema?.$defs?.ageRating?.required, Object.keys(schema?.$defs?.ageRating?.properties ?? {}), CONTRACT_KEYS.ageRating, "ageRating"],
    [schema?.$defs?.contentRights?.required, Object.keys(schema?.$defs?.contentRights?.properties ?? {}), CONTRACT_KEYS.contentRights, "contentRights"],
    [schema?.$defs?.eula?.required, Object.keys(schema?.$defs?.eula?.properties ?? {}), CONTRACT_KEYS.eula, "eula"],
    [schema?.$defs?.digitalServicesAct?.required, Object.keys(schema?.$defs?.digitalServicesAct?.properties ?? {}), CONTRACT_KEYS.digitalServicesAct, "digitalServicesAct"],
    [schema?.$defs?.pricing?.required, Object.keys(schema?.$defs?.pricing?.properties ?? {}), CONTRACT_KEYS.pricing, "pricing"],
    [schema?.$defs?.exportCompliance?.required, Object.keys(schema?.$defs?.exportCompliance?.properties ?? {}), CONTRACT_KEYS.exportCompliance, "exportCompliance"],
    [schema?.$defs?.review?.required, Object.keys(schema?.$defs?.review?.properties ?? {}), CONTRACT_KEYS.review, "review"],
    [schema?.$defs?.contact?.required, Object.keys(schema?.$defs?.contact?.properties ?? {}), CONTRACT_KEYS.contact, "contact"],
    [schema?.$defs?.login?.required, Object.keys(schema?.$defs?.login?.properties ?? {}), CONTRACT_KEYS.login, "login"],
    [schema?.$defs?.localization?.required, Object.keys(schema?.$defs?.localization?.properties ?? {}), CONTRACT_KEYS.localization, "localization"],
    [schema?.$defs?.screenshotSet?.required, Object.keys(schema?.$defs?.screenshotSet?.properties ?? {}), CONTRACT_KEYS.screenshotSet, "screenshotSet"],
    [schema?.$defs?.testFlight?.required, Object.keys(schema?.$defs?.testFlight?.properties ?? {}), CONTRACT_KEYS.testFlight, "testFlight"],
    [schema?.$defs?.testFlightLocalization?.required, Object.keys(schema?.$defs?.testFlightLocalization?.properties ?? {}), CONTRACT_KEYS.testFlightLocalization, "testFlightLocalization"],
  ];
  let bound = schema?.additionalProperties === false
    && schema?.properties?.records?.additionalProperties === false
    && schema?.$defs?.macosRecord?.unevaluatedProperties === false
    && schema?.$defs?.iosRecord?.unevaluatedProperties === false;
  for (const [required, properties, expected, label] of checks) {
    const normalizedRequired = Array.isArray(required) ? [...required].sort() : [];
    const normalizedProperties = [...properties].sort();
    const normalizedExpected = [...expected].sort();
    if (canonicalJSON(normalizedRequired) !== canonicalJSON(normalizedExpected)
        || canonicalJSON(normalizedProperties) !== canonicalJSON(normalizedExpected)) {
      structural(`submission schema ${label} keys diverge from the validator implementation`);
      bound = false;
    }
  }
  if (!bound) structural("submission schema must fail closed on unevaluated top-level, record, and platform keys");
  result.implementationKeysBound = bound;
  return result;
}

function canonicalUTCTimestamp(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value)) return null;
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds)) return null;
  return new Date(milliseconds).toISOString().replace(".000Z", "Z") === value ? milliseconds : null;
}

const schemaContract = validateSchemaContract();

function productionBundleIdentifier(value) {
  return typeof value === "string"
    && /^(?:[A-Za-z][A-Za-z0-9-]*\.)+[A-Za-z][A-Za-z0-9-]*$/.test(value)
    && !/(?:^|\.)(?:example|yourname|placeholder|local)(?:\.|$)/i.test(value);
}

function hasPlaceholder(value) {
  if (typeof value !== "string") return false;
  return /\[[^\]\n]+\]|\b(?:TBD|TODO|CHANGEME|REPLACE_ME|YOURTEAMID)\b|(?:^|\.)(?:example|yourname|yourdomain|placeholder)(?:\.|$)|\.invalid(?:\/|$)/iu.test(value);
}

function scanForPlaceholdersAndSecrets(value, location = "$", platforms = PLATFORMS) {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => scanForPlaceholdersAndSecrets(entry, `${location}[${index}]`, platforms));
    return;
  }
  if (!isPlainObject(value)) {
    if (typeof value !== "string") return;
    if (hasPlaceholder(value)) blocker(`${location} contains an unresolved placeholder`, platforms);
    const plaintextSecretPatterns = [
      /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
      /\bsk-[A-Za-z0-9_-]{16,}\b/,
      /\bAKIA[0-9A-Z]{16}\b/,
      /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/,
      /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/,
      /\b[a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4}\b/i,
      /\b(?:password|passwd|pwd|api[_ -]?key|private[_ -]?key|secret)\s*[:=]\s*\S+/i,
      /https?:\/\/[^\s/@:]+:[^\s/@]+@/,
    ];
    if (plaintextSecretPatterns.some((pattern) => pattern.test(value))) {
      structural(`${location} appears to contain a plaintext credential`);
    }
    return;
  }
  for (const [key, entry] of Object.entries(value)) {
    if (key !== "credentialsSecretReference"
        && /(?:password|private.?key|api.?key|app.?specific.?password|access.?token|refresh.?token|secret)/i.test(key)) {
      // A credential-bearing field invalidates the trust boundary for the
      // entire manifest, even when it is nested under only one platform.
      structural(`${location}.${key} is a forbidden credential field`);
    }
    scanForPlaceholdersAndSecrets(entry, `${location}.${key}`, platforms);
  }
}

function readXcconfig(relativePath, key) {
  const source = readFileSync(path.join(projectRoot, relativePath), "utf8");
  let result = null;
  for (const line of source.split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (match && match[1] === key) result = match[2];
  }
  return result;
}

const projectConfiguration = {
  productName: readXcconfig("ApplePlatforms/iOS/Config/Project.xcconfig", "AGENT_ISLAND_DISPLAY_NAME"),
  macos: {
    bundleIdentifier: readXcconfig("ApplePlatforms/macOS/Config/Project.xcconfig", "AGENT_ISLAND_MAC_APP_BUNDLE_ID"),
    versionString: readXcconfig("ApplePlatforms/macOS/Config/Project.xcconfig", "MARKETING_VERSION"),
    buildNumber: readXcconfig("ApplePlatforms/macOS/Config/Project.xcconfig", "CURRENT_PROJECT_VERSION"),
  },
  ios: {
    bundleIdentifier: readXcconfig("ApplePlatforms/iOS/Config/Project.xcconfig", "AGENT_ISLAND_APP_BUNDLE_ID"),
    widgetBundleIdentifier: readXcconfig("ApplePlatforms/iOS/Config/Project.xcconfig", "AGENT_ISLAND_WIDGET_BUNDLE_ID"),
    versionString: readXcconfig("ApplePlatforms/iOS/Config/Project.xcconfig", "MARKETING_VERSION"),
    buildNumber: readXcconfig("ApplePlatforms/iOS/Config/Project.xcconfig", "CURRENT_PROJECT_VERSION"),
  },
};
if (projectConfiguration.ios.widgetBundleIdentifier?.includes("$(AGENT_ISLAND_APP_BUNDLE_ID)")) {
  projectConfiguration.ios.widgetBundleIdentifier = projectConfiguration.ios.widgetBundleIdentifier.replace(
    "$(AGENT_ISLAND_APP_BUNDLE_ID)",
    projectConfiguration.ios.bundleIdentifier ?? "",
  );
}

function validateIdentityLock(manifest) {
  const lockPath = normalizedRepositoryPath(".release/identity.lock.json", "identity lock");
  const result = {
    path: ".release/identity.lock.json",
    present: false,
    sha256: null,
    bound: false,
    identity: null,
  };
  if (!lockPath || !existsSync(lockPath.absolute)) {
    blocker("identity lock does not exist: .release/identity.lock.json");
    return result;
  }
  const safeLock = safeExistingFile(lockPath, "identity lock");
  if (!safeLock) return { ...result, present: true };
  result.present = true;
  result.sha256 = sha256(safeLock.canonical);
  if (safeLock.size > MAX_MANIFEST_BYTES) {
    structural(`identity lock exceeds ${MAX_MANIFEST_BYTES} bytes`);
    return result;
  }
  let lock;
  try {
    lock = parseStrictJSON(readFileSync(safeLock.canonical, "utf8"), "identity lock");
  } catch (error) {
    structural(error.message);
    return result;
  }
  if (!exactObject(
    lock,
    ["schemaVersion", "firstAppliedAt", "identity", "provisioningProfile", "generatedEntitlements", "appliedFiles"],
    "identity lock",
  )) return result;
  if (lock.schemaVersion !== 1) structural("identity lock.schemaVersion must equal 1");
  if (canonicalUTCTimestamp(lock.firstAppliedAt) === null) structural("identity lock.firstAppliedAt must be canonical UTC");
  const requiredAppliedFiles = [
    "Resources/Info.plist",
    "ApplePlatforms/iOS/Config/Project.xcconfig",
    "ApplePlatforms/macOS/Config/Project.xcconfig",
  ];
  if (!Array.isArray(lock.appliedFiles) || lock.appliedFiles.length !== requiredAppliedFiles.length) {
    structural("identity lock.appliedFiles must contain exactly the three applied release identity files");
  } else {
    const seenPaths = new Set();
    for (const [index, appliedFile] of lock.appliedFiles.entries()) {
      const label = `identity lock.appliedFiles[${index}]`;
      if (!exactObject(appliedFile, ["path", "sha256"], label)) continue;
      const appliedPath = normalizedRepositoryPath(appliedFile.path, `${label}.path`);
      if (!requiredAppliedFiles.includes(appliedFile.path)) structural(`${label}.path is not an identity-managed project file`);
      if (seenPaths.has(appliedFile.path)) structural("identity lock.appliedFiles contains duplicate paths");
      seenPaths.add(appliedFile.path);
      if (typeof appliedFile.sha256 !== "string" || !SHA256_PATTERN.test(appliedFile.sha256)) {
        structural(`${label}.sha256 must be lowercase SHA-256`);
      }
      if (!appliedPath || !existsSync(appliedPath.absolute)) {
        blocker(`${label}.path does not exist`);
      } else {
        const safeAppliedFile = safeExistingFile(appliedPath, `${label}.path`);
        if (!safeAppliedFile || sha256(safeAppliedFile.canonical) !== appliedFile.sha256) {
          blocker(`${label} no longer matches the identity-managed project file`);
        }
      }
    }
    if (canonicalJSON([...seenPaths].sort()) !== canonicalJSON([...requiredAppliedFiles].sort())) {
      structural("identity lock.appliedFiles paths are incomplete");
    }
  }
  if ((lock.provisioningProfile === null) !== (lock.generatedEntitlements === null)) {
    structural("identity lock provisioningProfile and generatedEntitlements must both be null or both be records");
  }
  const identity = lock.identity;
  if (!exactObject(
    identity,
    [
      "schemaVersion", "appStoreRecordMode", "macOSAppBundleIdentifier", "iOSAppBundleIdentifier",
      "iOSWidgetBundleIdentifier", "teamIdentifier", "iCloudContainerIdentifier", "cloudKit",
    ],
    "identity lock.identity",
  )) return result;
  result.identity = identity;
  if (identity.schemaVersion !== 2) structural("identity lock.identity.schemaVersion must equal 2");
  if (!["universal-purchase", "separate-records"].includes(identity.appStoreRecordMode)) {
    structural("identity lock.identity.appStoreRecordMode is unsupported");
  }
  if (!productionBundleIdentifier(identity.macOSAppBundleIdentifier)
      || !productionBundleIdentifier(identity.iOSAppBundleIdentifier)) {
    blocker("identity lock must contain production macOS/iOS Bundle IDs");
  }
  if (typeof identity.teamIdentifier !== "string" || !/^[A-Z0-9]{10}$/.test(identity.teamIdentifier)) {
    blocker("identity lock must contain the 10-character Apple Team ID");
  }
  if (typeof identity.iCloudContainerIdentifier !== "string"
      || !/^iCloud\.(?:[A-Za-z][A-Za-z0-9-]*\.)+[A-Za-z][A-Za-z0-9-]*$/.test(identity.iCloudContainerIdentifier)
      || /(?:example|yourname|placeholder)/i.test(identity.iCloudContainerIdentifier)) {
    blocker("identity lock must contain a production iCloud Container ID");
  }
  if (identity.iOSWidgetBundleIdentifier !== `${identity.iOSAppBundleIdentifier}.liveactivity`) {
    structural("identity lock Widget Bundle ID does not derive from the iOS Bundle ID");
  }
  if (identity.appStoreRecordMode === "universal-purchase"
      && identity.macOSAppBundleIdentifier !== identity.iOSAppBundleIdentifier) {
    structural("identity lock Universal Purchase Bundle IDs must match");
  }
  if (identity.appStoreRecordMode === "separate-records"
      && identity.macOSAppBundleIdentifier === identity.iOSAppBundleIdentifier) {
    structural("identity lock separate-records Bundle IDs must differ");
  }
  if (!exactObject(identity.cloudKit, ["databaseScope", "environment", "recordType", "recordName", "payloadField"], "identity lock.identity.cloudKit")) {
    return result;
  }
  const expectedCloudKit = {
    databaseScope: "private",
    environment: "Production",
    recordType: "AgentIslandSnapshot",
    recordName: "latest",
    payloadField: "payloadJSON",
  };
  if (canonicalJSON(identity.cloudKit) !== canonicalJSON(expectedCloudKit)) {
    structural("identity lock CloudKit contract is not the Production private snapshot contract");
  }
  if (isPlainObject(lock.provisioningProfile) && isPlainObject(lock.generatedEntitlements)) {
    const profile = lock.provisioningProfile;
    const entitlements = lock.generatedEntitlements;
    const profileIsExact = exactObject(
      profile,
      ["sha256", "uuid", "name", "expiration", "applicationIdentifier", "appIDPrefix"],
      "identity lock.provisioningProfile",
    );
    const entitlementsAreExact = exactObject(
      entitlements,
      ["path", "sha256"],
      "identity lock.generatedEntitlements",
    );
    if (profileIsExact) {
      if (typeof profile.sha256 !== "string" || !SHA256_PATTERN.test(profile.sha256)) {
        structural("identity lock.provisioningProfile.sha256 must be lowercase SHA-256");
      }
      expectString(profile.uuid, "identity lock.provisioningProfile.uuid", PLATFORMS, { maximum: 200 });
      expectString(profile.name, "identity lock.provisioningProfile.name", PLATFORMS, { maximum: 500 });
      const expiration = canonicalUTCTimestamp(profile.expiration);
      if (expiration === null) {
        structural("identity lock.provisioningProfile.expiration must be canonical UTC");
      } else if (expiration <= Date.now()) {
        blocker("identity lock provisioning profile is expired");
      }
      if (typeof profile.appIDPrefix !== "string" || !/^[A-Z0-9]+$/.test(profile.appIDPrefix)) {
        structural("identity lock.provisioningProfile.appIDPrefix must contain uppercase ASCII letters and digits");
      }
      if (profile.applicationIdentifier !== `${profile.appIDPrefix}.${identity.macOSAppBundleIdentifier}`) {
        structural("identity lock provisioning profile applicationIdentifier does not bind the macOS Bundle ID");
      }
    }
    if (entitlementsAreExact) {
      if (entitlements.path !== ".release/CloudKit.entitlements") {
        structural("identity lock.generatedEntitlements.path must equal .release/CloudKit.entitlements");
      }
      if (typeof entitlements.sha256 !== "string" || !SHA256_PATTERN.test(entitlements.sha256)) {
        structural("identity lock.generatedEntitlements.sha256 must be lowercase SHA-256");
      }
      const entitlementsPath = normalizedRepositoryPath(
        entitlements.path,
        "identity lock.generatedEntitlements.path",
      );
      if (!entitlementsPath || !existsSync(entitlementsPath.absolute)) {
        blocker("identity lock generated entitlements file does not exist");
      } else {
        const safeEntitlements = safeExistingFile(entitlementsPath, "identity lock.generatedEntitlements.path");
        if (!safeEntitlements || sha256(safeEntitlements.canonical) !== entitlements.sha256) {
          blocker("identity lock generated entitlements hash does not match .release/CloudKit.entitlements");
        }
      }
    }
  } else if (lock.provisioningProfile !== null || lock.generatedEntitlements !== null) {
    structural("identity lock provisioningProfile and generatedEntitlements must both be null or both be records");
  }
  if (typeof manifest.identityLockSHA256 !== "string" || !SHA256_PATTERN.test(manifest.identityLockSHA256)) {
    blocker("manifest.identityLockSHA256 must be the lowercase SHA-256 of .release/identity.lock.json");
  } else if (manifest.identityLockSHA256 !== result.sha256) {
    blocker("manifest.identityLockSHA256 does not match .release/identity.lock.json");
  }
  if (manifest.recordMode !== identity.appStoreRecordMode
      || manifest.records?.macos?.bundleIdentifier !== identity.macOSAppBundleIdentifier
      || manifest.records?.ios?.bundleIdentifier !== identity.iOSAppBundleIdentifier
      || manifest.records?.ios?.widgetBundleIdentifier !== identity.iOSWidgetBundleIdentifier) {
    blocker("manifest record mode and Bundle IDs do not match .release/identity.lock.json");
  }
  result.bound = structuralErrors.length === 0
    && !releaseBlockers.some((message) => message.includes("identity lock") || message.includes("identityLockSHA256"));
  return result;
}

function isReservedOrLocalHostname(value) {
  const hostname = value.toLowerCase().replace(/\.$/, "");
  const address = hostname.startsWith("[") && hostname.endsWith("]")
    ? hostname.slice(1, -1)
    : hostname;
  const ipVersion = isIP(address);
  if (ipVersion === 4) {
    const octets = address.split(".").map(Number);
    const [first, second, third] = octets;
    return first === 0
      || first === 10
      || first === 127
      || (first === 100 && second >= 64 && second <= 127)
      || (first === 169 && second === 254)
      || (first === 172 && second >= 16 && second <= 31)
      || (first === 192 && (second === 0 || second === 168 || (second === 88 && third === 99)))
      || (first === 198 && (second === 18 || second === 19 || (second === 51 && third === 100)))
      || (first === 203 && second === 0 && third === 113)
      || first >= 224;
  }
  if (ipVersion === 6) {
    return address === "::"
      || address === "::1"
      || address.startsWith("::ffff:")
      || /^(?:fc|fd)/.test(address)
      || /^fe[89ab]/.test(address)
      || /^2001:db8(?::|$)/.test(address)
      || /^ff/.test(address);
  }
  return hostname === "localhost"
    || hostname.endsWith(".localhost")
    || hostname.endsWith(".local")
    || hostname.endsWith(".test")
    || hostname.endsWith(".invalid")
    || hostname.endsWith(".example")
    || ["example.com", "example.net", "example.org"].includes(hostname);
}

function validateURL(value, label, platforms, { nullable = false } = {}) {
  if (value === null && nullable) return;
  if (!expectString(value, label, platforms, { maximum: 500 })) return;
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    blocker(`${label} must be a valid public HTTPS URL`, platforms);
    return;
  }
  const hostname = parsed.hostname.toLowerCase().replace(/\.$/, "");
  const reservedHostname = isReservedOrLocalHostname(hostname);
  if (parsed.protocol !== "https:" || parsed.username || parsed.password || parsed.port
      || !hostname.includes(".") || reservedHostname || parsed.search || parsed.hash) {
    blocker(`${label} must be a public HTTPS URL without credentials, port, query, fragment, or reserved/local host`, platforms);
  }
  if (hasPlaceholder(parsed.hostname)) blocker(`${label} uses a placeholder host`, platforms);
}

function validateEmail(value, label, platforms) {
  if (!expectString(value, label, platforms, { maximum: 254 })) return;
  const domain = typeof value === "string" ? value.split("@").at(-1)?.toLowerCase().replace(/\.$/, "") : "";
  const reserved = domain === "localhost"
    || domain.endsWith(".localhost")
    || domain.endsWith(".test")
    || domain.endsWith(".invalid")
    || domain.endsWith(".example")
    || ["example.com", "example.net", "example.org"].includes(domain);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value) || reserved) {
    blocker(`${label} must be a syntactically valid address on a non-reserved domain; public reachability is verified separately`, platforms);
  }
}

function validateContact(value, label, platforms) {
  if (!exactObject(value, CONTRACT_KEYS.contact, label, platforms)) return;
  expectString(value.firstName, `${label}.firstName`, platforms, { maximum: 100 });
  expectString(value.lastName, `${label}.lastName`, platforms, { maximum: 100 });
  validateEmail(value.email, `${label}.email`, platforms);
  if (expectString(value.phone, `${label}.phone`, platforms, { maximum: 100 })
      && !/^\+[1-9][0-9]{7,14}$/.test(value.phone)) {
    blocker(`${label}.phone must use E.164 format`, platforms);
  }
}

function validateLogin(value, label, platforms) {
  if (!exactObject(value, CONTRACT_KEYS.login, label, platforms)) return;
  if (!["no-login", "review-account", "custom-instructions"].includes(value.strategy)) {
    structural(`${label}.strategy is unsupported`, platforms);
  }
  expectString(value.instructions, `${label}.instructions`, platforms);
  if (value.strategy === "no-login") {
    if (value.credentialsSecretReference !== null) {
      structural(`${label}.credentialsSecretReference must be null for no-login`, platforms);
    }
  } else if (typeof value.credentialsSecretReference !== "string"
      || !/^(?:keychain|ci-secret):\/\/[A-Za-z0-9._/-]{2,200}$/.test(value.credentialsSecretReference)) {
    structural(`${label}.credentialsSecretReference must be a keychain:// or ci-secret:// locator, never plaintext`);
  }
}

function validateVersion(value, label, platform) {
  const platforms = [platform];
  if (!exactObject(value, CONTRACT_KEYS.version, label, platforms)) return;
  if (!/^\d+(?:\.\d+){1,2}$/.test(value.versionString ?? "")) structural(`${label}.versionString is invalid`, platforms);
  if (!/^[1-9][0-9]*$/.test(value.buildNumber ?? "")) structural(`${label}.buildNumber is invalid`, platforms);
  if (!["manual", "automatic", "scheduled"].includes(value.releaseMode)) structural(`${label}.releaseMode is unsupported`, platforms);
  if (value.releaseMode === "scheduled") {
    const scheduledMilliseconds = canonicalUTCTimestamp(value.scheduledReleaseAt);
    if (scheduledMilliseconds === null) {
      blocker(`${label}.scheduledReleaseAt must be a valid UTC timestamp for scheduled release`, platforms);
    } else if (scheduledMilliseconds <= Date.now()) {
      blocker(`${label}.scheduledReleaseAt must still be in the future`, platforms);
    }
  } else if (value.scheduledReleaseAt !== null) {
    structural(`${label}.scheduledReleaseAt must be null unless releaseMode is scheduled`, platforms);
  }
  expectString(value.copyright, `${label}.copyright`, platforms, { maximum: 200 });
  const expected = projectConfiguration[platform];
  if (value.versionString !== expected.versionString) {
    blocker(`${label}.versionString must match ${platform} MARKETING_VERSION ${expected.versionString}`, platforms);
  }
  if (value.buildNumber !== expected.buildNumber) {
    blocker(`${label}.buildNumber must match ${platform} CURRENT_PROJECT_VERSION ${expected.buildNumber}`, platforms);
  }
}

function validateCommerce(value, label, platform) {
  const platforms = [platform];
  if (!exactObject(
    value,
    CONTRACT_KEYS.commerce,
    label,
    platforms,
  )) return;

  if (exactObject(value.ageRating, CONTRACT_KEYS.ageRating, `${label}.ageRating`, platforms)) {
    if (!["complete", "incomplete"].includes(value.ageRating.questionnaireStatus)) structural(`${label}.ageRating.questionnaireStatus is unsupported`, platforms);
    if (value.ageRating.questionnaireStatus !== "complete") blocker(`${label}.ageRating questionnaire is not complete`, platforms);
    if (!["4+", "9+", "13+", "16+", "18+"].includes(value.ageRating.declaredRating)) {
      blocker(`${label}.ageRating.declaredRating must be the final App Store rating`, platforms);
    }
  }

  if (typeof value.madeForKids !== "boolean") {
    structural(`${label}.madeForKids must be an explicit Boolean decision`, platforms);
  }

  if (exactObject(value.contentRights, CONTRACT_KEYS.contentRights, `${label}.contentRights`, platforms)) {
    if (!["does-not-use-third-party-content", "uses-third-party-content-rights-cleared"].includes(value.contentRights.status)) {
      blocker(`${label}.contentRights.status must record the final rights decision`, platforms);
    }
    expectString(value.contentRights.notes, `${label}.contentRights.notes`, platforms);
  }

  if (exactObject(value.eula, CONTRACT_KEYS.eula, `${label}.eula`, platforms)) {
    if (!["apple-standard", "custom"].includes(value.eula.type)) structural(`${label}.eula.type is unsupported`, platforms);
    if (value.eula.type === "apple-standard") {
      if (value.eula.customText !== null || !Array.isArray(value.eula.territories) || value.eula.territories.length !== 0) {
        structural(`${label}.eula standard EULA requires null customText and empty territories`, platforms);
      }
    } else {
      expectString(value.eula.customText, `${label}.eula.customText`, platforms, { minimum: 100, maximum: 4000 });
      if (expectArray(value.eula.territories, `${label}.eula.territories`, platforms, 1, 175)
          && value.eula.territories.some((territory) => typeof territory !== "string" || !/^[A-Z]{3}$/.test(territory))) {
        blocker(`${label}.eula.territories must contain ISO 3166-1 alpha-3 codes`, platforms);
      }
    }
  }

  if (exactObject(value.digitalServicesAct, CONTRACT_KEYS.digitalServicesAct, `${label}.digitalServicesAct`, platforms)) {
    if (!["trader", "non-trader"].includes(value.digitalServicesAct.traderStatus)) {
      blocker(`${label}.digitalServicesAct.traderStatus must be decided by the Account Holder`, platforms);
    }
    if (!["verified", "not-required"].includes(value.digitalServicesAct.verificationStatus)) {
      blocker(`${label}.digitalServicesAct.verificationStatus is not release-ready`, platforms);
    }
    if (value.digitalServicesAct.traderStatus === "trader" && value.digitalServicesAct.verificationStatus !== "verified") {
      blocker(`${label}.digitalServicesAct trader must be verified`, platforms);
    }
  }

  if (exactObject(value.pricing, CONTRACT_KEYS.pricing, `${label}.pricing`, platforms)) {
    if (!["free", "paid"].includes(value.pricing.model)) blocker(`${label}.pricing.model must be free or paid`, platforms);
    if (value.pricing.model === "free" && value.pricing.pricePointReference !== null) {
      structural(`${label}.pricing.pricePointReference must be null for a free app`, platforms);
    }
    if (value.pricing.model === "paid"
        && (typeof value.pricing.pricePointReference !== "string"
          || !/^[A-Za-z0-9._:-]{2,100}$/.test(value.pricing.pricePointReference))) {
      blocker(`${label}.pricing.pricePointReference must identify the confirmed App Store price point`, platforms);
    }
    if (typeof value.pricing.taxCategory !== "string" || !/^[A-Z][A-Z0-9_]{2,63}$/.test(value.pricing.taxCategory)) {
      blocker(`${label}.pricing.taxCategory must be the confirmed App Store tax-category code`, platforms);
    }
    if (expectArray(value.pricing.availableTerritories, `${label}.pricing.availableTerritories`, platforms, 1, 175)) {
      const territories = value.pricing.availableTerritories;
      if (territories.some((territory) => typeof territory !== "string" || !/^[A-Z]{3}$/.test(territory))) {
        blocker(`${label}.pricing.availableTerritories must contain ISO 3166-1 alpha-3 territory codes`, platforms);
      }
      if (new Set(territories).size !== territories.length) structural(`${label}.pricing.availableTerritories contains duplicates`, platforms);
    }
  }

  if (exactObject(
    value.exportCompliance,
    CONTRACT_KEYS.exportCompliance,
    `${label}.exportCompliance`,
    platforms,
  )) {
    if (typeof value.exportCompliance.usesNonExemptEncryption !== "boolean") {
      structural(`${label}.exportCompliance.usesNonExemptEncryption must be Boolean`, platforms);
    }
    const { usesNonExemptEncryption, status, documentationReference } = value.exportCompliance;
    if (usesNonExemptEncryption === false) {
      if (status !== "exempt" || documentationReference !== null) {
        blocker(`${label}.exportCompliance must record exempt with no documentation when non-exempt encryption is false`, platforms);
      }
    } else if (usesNonExemptEncryption === true) {
      if (status !== "documentation-approved") {
        blocker(`${label}.exportCompliance non-exempt encryption requires documentation-approved status`, platforms);
      }
      const documentationPath = normalizedRepositoryPath(
        documentationReference,
        `${label}.exportCompliance.documentationReference`,
        platforms,
      );
      if (!documentationPath || !documentationPath.relative.startsWith(".release/")) {
        blocker(`${label}.exportCompliance documentation must be a private .release/ file`, platforms);
      } else if (!existsSync(documentationPath.absolute)) {
        blocker(`${label}.exportCompliance documentation does not exist`, platforms);
      } else {
        safeExistingFile(documentationPath, `${label}.exportCompliance.documentationReference`);
      }
    }
  }
}

const APP_STORE_CATEGORIES = new Set([
  "books", "business", "developer-tools", "education", "entertainment", "finance", "food-drink",
  "games", "graphics-design", "health-fitness", "lifestyle", "magazines-newspapers", "medical", "music",
  "navigation", "news", "photography-video", "productivity", "reference", "shopping", "social-networking",
  "sports", "travel", "utilities", "weather",
]);

function validateCategories(value, label, platform) {
  const platforms = [platform];
  if (!exactObject(value, CONTRACT_KEYS.categories, label, platforms)) return;
  if (!APP_STORE_CATEGORIES.has(value.primary)) structural(`${label}.primary is not a recognized App Store category`, platforms);
  if (value.secondary !== null && !APP_STORE_CATEGORIES.has(value.secondary)) {
    structural(`${label}.secondary must be null or a recognized App Store category`, platforms);
  }
  if (value.secondary !== null && value.secondary === value.primary) {
    structural(`${label}.secondary must differ from primary`, platforms);
  }
  if (platform === "macos" && value.primary !== "developer-tools") {
    blocker(`${label}.primary must remain developer-tools for the current Mac product positioning`, platforms);
  }
}

function validateLocalization(value, label, platform) {
  const platforms = [platform];
  if (!exactObject(value, CONTRACT_KEYS.localization, label, platforms)) return null;
  if (!REQUIRED_LOCALES.includes(value.locale)) structural(`${label}.locale is unsupported`, platforms);
  expectString(value.name, `${label}.name`, platforms, { minimum: 2, maximum: 30 });
  if (value.name !== PRODUCT_NAME) blocker(`${label}.name must equal the approved product name ${PRODUCT_NAME}`, platforms);
  expectString(value.subtitle, `${label}.subtitle`, platforms, { minimum: 0, maximum: 30 });
  expectString(value.promotionalText, `${label}.promotionalText`, platforms, { minimum: 0, maximum: 170 });
  expectString(value.description, `${label}.description`, platforms, { maximum: 4000 });
  if (expectString(value.keywords, `${label}.keywords`, platforms, { maximum: 100 })
      && Buffer.byteLength(value.keywords, "utf8") > 100) {
    structural(`${label}.keywords exceeds App Store Connect's 100-byte limit`, platforms);
  }
  expectString(value.whatsNew, `${label}.whatsNew`, platforms, { maximum: 4000 });
  for (const field of ["name", "subtitle", "promotionalText", "description", "keywords", "whatsNew"]) {
    if (typeof value[field] === "string" && /`|\*\*|__|\[[^\]\n]+\]\([^)]+\)/.test(value[field])) {
      structural(`${label}.${field} contains unsupported Markdown`, platforms);
    }
  }
  validateURL(value.privacyPolicyURL, `${label}.privacyPolicyURL`, platforms);
  validateURL(value.supportURL, `${label}.supportURL`, platforms);
  validateURL(value.marketingURL, `${label}.marketingURL`, platforms, { nullable: true });
  return value.locale;
}

function validateReview(value, label, platform) {
  const platforms = [platform];
  if (!exactObject(value, CONTRACT_KEYS.review, label, platforms)) return;
  validateContact(value.contact, `${label}.contact`, platforms);
  validateLogin(value.login, `${label}.login`, platforms);
  expectString(value.notes, `${label}.notes`, platforms);
}

function validateScreenshotSets(value, label, platform) {
  const platforms = [platform];
  const normalizedSets = [];
  if (!expectArray(value, label, platforms, 2, 20)) return normalizedSets;
  const allPaths = [];
  for (const [index, set] of value.entries()) {
    const setLabel = `${label}[${index}]`;
    if (!exactObject(set, CONTRACT_KEYS.screenshotSet, setLabel, platforms)) continue;
    if (!REQUIRED_LOCALES.includes(set.locale)) structural(`${setLabel}.locale is unsupported`, platforms);
    expectString(set.device, `${setLabel}.device`, platforms, { minimum: 2, maximum: 80 });
    const paths = [];
    if (expectArray(set.orderedPaths, `${setLabel}.orderedPaths`, platforms, 1, 10)) {
      for (const [pathIndex, screenshotPath] of set.orderedPaths.entries()) {
        const pathLabel = `${setLabel}.orderedPaths[${pathIndex}]`;
        const normalized = normalizedRepositoryPath(screenshotPath, pathLabel, platforms);
        if (!normalized) continue;
        const expectedPrefix = `docs/release-assets/${platform}/${set.locale}/`;
        if (!normalized.relative.startsWith(expectedPrefix)
            || !/\.(?:png|jpe?g)$/.test(normalized.relative)) {
          structural(`${pathLabel} must be a PNG/JPEG inside ${expectedPrefix}`, platforms);
        }
        paths.push(normalized.relative);
        allPaths.push(normalized.relative);
      }
      if (new Set(paths).size !== paths.length) structural(`${setLabel}.orderedPaths contains duplicates`, platforms);
    }
    normalizedSets.push({ locale: set.locale, device: set.device, orderedPaths: paths });
  }
  for (const locale of REQUIRED_LOCALES) {
    if (!normalizedSets.some((set) => set.locale === locale)) blocker(`${label} is missing ${locale}`, platforms);
  }
  if (new Set(allPaths).size !== allPaths.length) structural(`${label} reuses a screenshot path`, platforms);
  return normalizedSets;
}

function validateTestFlight(value, label) {
  const platforms = ["ios"];
  if (!exactObject(value, CONTRACT_KEYS.testFlight, label, platforms)) return;
  if (!["internal-only", "external"].includes(value.distribution)) structural(`${label}.distribution is unsupported`, platforms);
  validateEmail(value.feedbackEmail, `${label}.feedbackEmail`, platforms);
  validateContact(value.betaReviewContact, `${label}.betaReviewContact`, platforms);
  validateLogin(value.login, `${label}.login`, platforms);
  const locales = [];
  if (expectArray(value.localizations, `${label}.localizations`, platforms, 2, 2)) {
    for (const [index, localization] of value.localizations.entries()) {
      const localizationLabel = `${label}.localizations[${index}]`;
      if (!exactObject(localization, CONTRACT_KEYS.testFlightLocalization, localizationLabel, platforms)) continue;
      if (!REQUIRED_LOCALES.includes(localization.locale)) structural(`${localizationLabel}.locale is unsupported`, platforms);
      expectString(localization.betaAppDescription, `${localizationLabel}.betaAppDescription`, platforms);
      expectString(localization.whatToTest, `${localizationLabel}.whatToTest`, platforms);
      locales.push(localization.locale);
    }
  }
  if (JSON.stringify([...new Set(locales)].sort()) !== JSON.stringify([...REQUIRED_LOCALES].sort())) {
    structural(`${label}.localizations must contain exactly zh-Hans and en-US`, platforms);
  }
}

function validateRecord(value, platform) {
  const platforms = [platform];
  const label = `records.${platform}`;
  const keys = [...CONTRACT_KEYS.commonRecord];
  if (platform === "ios") keys.push("widgetBundleIdentifier", "testFlight");
  if (!exactObject(value, keys, label, platforms)) return { screenshotSets: [] };

  if (expectString(value.appResourceId, `${label}.appResourceId`, platforms, { maximum: 100 })
      && !/^[0-9]{8,20}$/.test(value.appResourceId)) {
    blocker(`${label}.appResourceId must be the numeric App Store Connect app resource ID`, platforms);
  }
  if (expectString(value.bundleIdentifier, `${label}.bundleIdentifier`, platforms, { maximum: 255 })
      && !productionBundleIdentifier(value.bundleIdentifier)) {
    blocker(`${label}.bundleIdentifier is not a production Bundle ID`, platforms);
  }
  if (expectString(value.sku, `${label}.sku`, platforms, { maximum: 64 })
      && !/^[A-Za-z0-9._-]{2,64}$/.test(value.sku)) {
    blocker(`${label}.sku must be the final 2-64 character App Store SKU`, platforms);
  }
  if (!REQUIRED_LOCALES.includes(value.primaryLocale)) structural(`${label}.primaryLocale is unsupported`, platforms);

  const expected = projectConfiguration[platform];
  if (value.bundleIdentifier !== expected.bundleIdentifier) {
    blocker(`${label}.bundleIdentifier must match the current ${platform} project value ${expected.bundleIdentifier}`, platforms);
  }
  if (platform === "ios") {
    if (expectString(value.widgetBundleIdentifier, `${label}.widgetBundleIdentifier`, platforms, { maximum: 255 })) {
      if (!productionBundleIdentifier(value.widgetBundleIdentifier)) blocker(`${label}.widgetBundleIdentifier is not a production Bundle ID`, platforms);
      if (value.widgetBundleIdentifier !== `${value.bundleIdentifier}.liveactivity`) {
        structural(`${label}.widgetBundleIdentifier must equal the iOS Bundle ID plus .liveactivity`, platforms);
      }
      if (value.widgetBundleIdentifier !== expected.widgetBundleIdentifier) {
        blocker(`${label}.widgetBundleIdentifier must match the current iOS project value ${expected.widgetBundleIdentifier}`, platforms);
      }
    }
  }

  validateVersion(value.version, `${label}.version`, platform);
  validateCategories(value.categories, `${label}.categories`, platform);
  validateCommerce(value.commerce, `${label}.commerce`, platform);
  validateReview(value.review, `${label}.review`, platform);

  const locales = [];
  if (expectArray(value.localizations, `${label}.localizations`, platforms, 2, 2)) {
    value.localizations.forEach((localization, index) => {
      const locale = validateLocalization(localization, `${label}.localizations[${index}]`, platform);
      if (locale) locales.push(locale);
    });
  }
  if (JSON.stringify([...new Set(locales)].sort()) !== JSON.stringify([...REQUIRED_LOCALES].sort())) {
    structural(`${label}.localizations must contain exactly zh-Hans and en-US`, platforms);
  }
  if (!locales.includes(value.primaryLocale)) structural(`${label}.primaryLocale has no matching localization`, platforms);

  const screenshotSets = validateScreenshotSets(value.screenshotSets, `${label}.screenshotSets`, platform);
  if (platform === "ios") validateTestFlight(value.testFlight, `${label}.testFlight`);
  return { screenshotSets };
}

function validateStoreSubmissionAssets(manifest, screenshotSetsByPlatform) {
  const result = {
    validatorPath: "scripts/validate-store-submission.mjs",
    validatorReportSHA256: null,
    evidencePath: manifest.screenshotEvidencePath ?? null,
    evidencePresent: false,
    evidenceSHA256: null,
    evidenceHashBound: false,
    platforms: {
      macos: { ready: false, candidate: null, metadataBound: false, screenshotReferencesBound: false },
      ios: { ready: false, candidate: null, metadataBound: false, screenshotReferencesBound: false },
    },
  };
  const evidencePath = normalizedRepositoryPath(manifest.screenshotEvidencePath, "screenshotEvidencePath");
  if (!evidencePath) return result;
  if (!evidencePath.relative.startsWith(".release/")) {
    blocker("screenshotEvidencePath must identify a private .release/ evidence file");
  }
  if (!existsSync(evidencePath.absolute)) {
    blocker(`screenshotEvidencePath does not exist: ${evidencePath.relative}`);
    return result;
  }
  const evidenceFile = safeExistingFile(evidencePath, "screenshotEvidencePath");
  if (!evidenceFile) return { ...result, evidencePresent: true };
  result.evidencePresent = true;
  if (evidenceFile.size > MAX_MANIFEST_BYTES) {
    structural(`screenshotEvidencePath exceeds ${MAX_MANIFEST_BYTES} bytes`);
    return result;
  }
  result.evidenceSHA256 = sha256(evidenceFile.canonical);
  if (typeof manifest.screenshotEvidenceSHA256 !== "string"
      || !SHA256_PATTERN.test(manifest.screenshotEvidenceSHA256)) {
    blocker("manifest.screenshotEvidenceSHA256 must be a lowercase SHA-256");
  } else if (manifest.screenshotEvidenceSHA256 !== result.evidenceSHA256) {
    blocker("manifest.screenshotEvidenceSHA256 does not match screenshotEvidencePath");
  } else {
    result.evidenceHashBound = true;
  }

  const validatorPath = normalizedRepositoryPath(result.validatorPath, "store asset validator");
  if (!validatorPath || !existsSync(validatorPath.absolute)) {
    structural("authoritative store asset validator is missing");
    return result;
  }
  const safeValidator = safeExistingFile(validatorPath, "store asset validator");
  if (!safeValidator) return result;
  const invocation = spawnSync(process.execPath, [safeValidator.canonical], {
    cwd: projectRoot,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
    env: {
      ...process.env,
      AGENT_ISLAND_STORE_SCREENSHOT_EVIDENCE: evidencePath.relative,
    },
  });
  if (invocation.error) {
    structural(`authoritative store asset validator could not run: ${invocation.error.message}`);
    return result;
  }
  let report;
  try {
    report = parseStrictJSON(invocation.stdout, "store asset validator output");
  } catch (error) {
    structural(error.message);
    return result;
  }
  result.validatorReportSHA256 = createHash("sha256").update(invocation.stdout).digest("hex");
  if (invocation.status !== 0 || report?.draftValid !== true) {
    structural("authoritative store asset validator reported a structural failure");
    return result;
  }
  if (report?.screenshotEvidence?.path !== evidencePath.relative) {
    structural("authoritative store asset validator inspected a different screenshot evidence path");
    return result;
  }

  for (const platform of PLATFORMS) {
    const platforms = [platform];
    const record = manifest.records[platform];
    const platformResult = result.platforms[platform];
    const reportReadyKey = platform === "macos"
      ? "macStoreSubmissionAssetsReady"
      : "iosStoreSubmissionAssetsReady";
    const reportBlockersKey = platform === "macos"
      ? "macStoreSubmissionBlockers"
      : "iosStoreSubmissionBlockers";
    const reportStructuralKey = platform === "macos"
      ? "macStoreSubmissionStructuralErrors"
      : "iosStoreSubmissionStructuralErrors";
    if (!Array.isArray(report?.[reportBlockersKey]) || !Array.isArray(report?.[reportStructuralKey])) {
      structural(`authoritative store asset validator omitted its ${platform} diagnostics`);
      continue;
    }
    for (const message of report[reportStructuralKey]) {
      structural(`store assets: ${message}`, platforms);
    }
    if (report[reportReadyKey] !== true) {
      blocker(`authoritative store asset validator did not approve ${platform} assets`, platforms);
      continue;
    }

    const candidate = report?.screenshotEvidence?.platforms?.[platform]?.candidate;
    platformResult.candidate = candidate ?? null;
    if (!isPlainObject(candidate)
        || candidate.platform !== platform
        || candidate.bundleIdentifier !== record.bundleIdentifier
        || candidate.version !== record.version.versionString
        || candidate.build !== record.version.buildNumber
        || candidate.candidateIdentityVerified !== true
        || candidate.artifact?.configuredSHA256 !== candidate.artifact?.actualSHA256
        || !SHA256_PATTERN.test(candidate.artifact?.actualSHA256 ?? "")) {
      blocker(`authoritative store asset candidate does not match the ${platform} manifest tuple`, platforms);
      continue;
    }

    const reportPlatform = platform === "macos" ? "macOS" : "iOS";
    let metadataBound = true;
    for (const localization of record.localizations) {
      const metadata = report.metadata?.find((item) =>
        item?.platform === reportPlatform && item?.locale === localization.locale);
      if (!metadata?.measurements) {
        metadataBound = false;
        break;
      }
      for (const field of ["name", "subtitle", "promotionalText", "description", "keywords"]) {
        if (metadata.measurements[field]?.value !== localization[field]) metadataBound = false;
      }
    }
    platformResult.metadataBound = metadataBound;
    if (!metadataBound) blocker(`authoritative store metadata does not match the ${platform} manifest localizations`, platforms);

    const configuredSets = screenshotSetsByPlatform[platform];
    const validatedSets = (report.finalScreenshots ?? []).filter((set) => set?.platform === platform);
    platformResult.screenshotReferencesBound = configuredSets.length === validatedSets.length
      && configuredSets.every((configuredSet) => {
        const matches = validatedSets.filter((validatedSet) => validatedSet?.locale === configuredSet.locale);
        if (matches.length !== 1) return false;
        const validatedPaths = (matches[0].images ?? []).map((image) =>
          path.relative(projectRoot, image.path).split(path.sep).join("/"));
        // validate-store-submission.mjs returns each locale's final files in
        // deterministic filename order. Keep the manifest sequence intact so
        // `orderedPaths` is a real submission-order contract, not a set.
        return canonicalJSON(configuredSet.orderedPaths) === canonicalJSON(validatedPaths);
      });
    if (!platformResult.screenshotReferencesBound) {
      blocker(`manifest screenshot order references do not cover every and only validated ${platform} screenshot`, platforms);
    }
    platformResult.ready = result.evidenceHashBound
      && metadataBound
      && platformResult.screenshotReferencesBound
      && platformStructuralErrors[platform].length === 0
      && platformReleaseBlockers[platform].length === 0;
  }
  return result;
}

const manifestPathFromEnvironment = Object.prototype.hasOwnProperty.call(process.env, MANIFEST_ENVIRONMENT_VARIABLE);
const manifestPathValue = manifestPathFromEnvironment
  ? process.env[MANIFEST_ENVIRONMENT_VARIABLE]
  : DEFAULT_MANIFEST_PATH;
const manifestPath = normalizedRepositoryPath(manifestPathValue, MANIFEST_ENVIRONMENT_VARIABLE);
let manifest = null;
let manifestFile = null;
if (manifestPath) {
  if (!existsSync(manifestPath.absolute)) {
    const message = `${MANIFEST_ENVIRONMENT_VARIABLE} path does not exist: ${manifestPath.relative}`;
    if (manifestPathFromEnvironment) structural(message);
    else blocker(message);
  } else {
    manifestFile = safeExistingFile(manifestPath, MANIFEST_ENVIRONMENT_VARIABLE, PLATFORMS, structural);
    if (manifestFile && manifestFile.size > MAX_MANIFEST_BYTES) {
      structural(`${MANIFEST_ENVIRONMENT_VARIABLE} exceeds ${MAX_MANIFEST_BYTES} bytes`);
      manifestFile = null;
    }
    if (manifestFile) {
      try {
        manifest = parseStrictJSON(readFileSync(manifestFile.canonical, "utf8"), "App Store submission manifest");
      } catch (error) {
        structural(error.message);
      }
    }
  }
}

let recordResults = { macos: { screenshotSets: [] }, ios: { screenshotSets: [] } };
let identityLock = {
  path: ".release/identity.lock.json",
  present: false,
  sha256: null,
  bound: false,
  identity: null,
};
let storeAssets = {
  validatorPath: "scripts/validate-store-submission.mjs",
  validatorReportSHA256: null,
  evidencePath: manifest?.screenshotEvidencePath ?? null,
  evidencePresent: false,
  evidenceSHA256: null,
  evidenceHashBound: false,
  platforms: {
    macos: { ready: false, candidate: null, metadataBound: false, screenshotReferencesBound: false },
    ios: { ready: false, candidate: null, metadataBound: false, screenshotReferencesBound: false },
  },
};
const manifestStoredInReleaseDirectory = manifestPath?.relative.startsWith(".release/") === true;
const manifestWriteProtected = manifestFile !== null && (manifestFile.mode & 0o222) === 0;
if (manifest) {
  if (!manifestStoredInReleaseDirectory) {
    blocker("a finalized submission manifest must be stored in the gitignored .release/ directory");
  }
  if (!manifestWriteProtected) {
    blocker("a finalized submission manifest must not have owner, group, or other write permissions");
  }
  const topLevelIsExact = exactObject(
    manifest,
    CONTRACT_KEYS.manifest,
    "manifest",
  );
  scanForPlaceholdersAndSecrets({
    productName: manifest.productName,
    recordMode: manifest.recordMode,
    identityLockSHA256: manifest.identityLockSHA256,
    screenshotEvidencePath: manifest.screenshotEvidencePath,
    screenshotEvidenceSHA256: manifest.screenshotEvidenceSHA256,
  });
  if (isPlainObject(manifest.records)) {
    scanForPlaceholdersAndSecrets(manifest.records.macos, "$.records.macos", ["macos"]);
    scanForPlaceholdersAndSecrets(manifest.records.ios, "$.records.ios", ["ios"]);
  }
  if (manifest.schemaVersion !== 1) structural("manifest.schemaVersion must be 1");
  if (manifest.productName !== PRODUCT_NAME) blocker(`manifest.productName must equal ${PRODUCT_NAME}`);
  if (manifest.productName !== projectConfiguration.productName) {
    blocker(`manifest.productName must match the current project display name ${projectConfiguration.productName}`);
  }
  if (!["universal-purchase", "separate-records"].includes(manifest.recordMode)) structural("manifest.recordMode is unsupported");
  if (topLevelIsExact && exactObject(manifest.records, CONTRACT_KEYS.records, "manifest.records")) {
    recordResults = {
      macos: validateRecord(manifest.records.macos, "macos"),
      ios: validateRecord(manifest.records.ios, "ios"),
    };
    const mac = manifest.records.macos;
    const ios = manifest.records.ios;
    if (isPlainObject(mac) && isPlainObject(ios)) {
      if (manifest.recordMode === "universal-purchase") {
        for (const field of ["appResourceId", "bundleIdentifier", "sku", "primaryLocale"] ) {
          if (mac[field] !== ios[field]) structural(`universal-purchase requires matching macOS/iOS ${field}`);
        }
        if (canonicalJSON(mac.commerce) !== canonicalJSON(ios.commerce)) {
          structural("universal-purchase requires identical macOS/iOS commerce decisions");
        }
        if (canonicalJSON(mac.categories) !== canonicalJSON(ios.categories)) {
          structural("universal-purchase requires identical macOS/iOS categories");
        }
        const macLocalizations = new Map((mac.localizations ?? []).map((item) => [item?.locale, item]));
        const iosLocalizations = new Map((ios.localizations ?? []).map((item) => [item?.locale, item]));
        for (const locale of REQUIRED_LOCALES) {
          const macLocalization = macLocalizations.get(locale);
          const iosLocalization = iosLocalizations.get(locale);
          for (const field of ["name", "subtitle", "privacyPolicyURL", "supportURL", "marketingURL"]) {
            if (macLocalization?.[field] !== iosLocalization?.[field]) {
              structural(`universal-purchase requires matching ${locale} ${field}`);
            }
          }
        }
      } else if (manifest.recordMode === "separate-records") {
        for (const field of ["appResourceId", "bundleIdentifier", "sku"] ) {
          if (mac[field] === ios[field]) structural(`separate-records requires different macOS/iOS ${field}`);
        }
      }
    }
    identityLock = validateIdentityLock(manifest);
    if (structuralErrors.length === 0 && releaseBlockers.length === 0) {
      storeAssets = validateStoreSubmissionAssets(manifest, {
        macos: recordResults.macos.screenshotSets,
        ios: recordResults.ios.screenshotSets,
      });
    }
  }
}

const draftValid = structuralErrors.length === 0;
const derivedChecks = (() => {
  const mac = manifest?.records?.macos;
  const ios = manifest?.records?.ios;
  if (!isPlainObject(mac) || !isPlainObject(ios)) {
    return {
      recordModeSemanticsValid: false,
      universalPurchaseSharedFieldsConsistent: null,
      universalPurchaseCategoriesConsistent: null,
      universalPurchaseLocalizedAppFieldsConsistent: null,
      primaryLocalesCovered: false,
      macPrimaryCategoryMatchesProduct: false,
    };
  }
  const primaryLocalesCovered = [mac, ios].every((record) =>
    REQUIRED_LOCALES.every((locale) => record.localizations?.some((item) => item?.locale === locale))
    && record.localizations?.some((item) => item?.locale === record.primaryLocale));
  if (manifest.recordMode !== "universal-purchase") {
    return {
      recordModeSemanticsValid: manifest.recordMode === "separate-records"
        && mac.appResourceId !== ios.appResourceId
        && mac.bundleIdentifier !== ios.bundleIdentifier
        && mac.sku !== ios.sku,
      universalPurchaseSharedFieldsConsistent: null,
      universalPurchaseCategoriesConsistent: null,
      universalPurchaseLocalizedAppFieldsConsistent: null,
      primaryLocalesCovered,
      macPrimaryCategoryMatchesProduct: mac.categories?.primary === "developer-tools",
    };
  }
  const sharedFieldsConsistent = ["appResourceId", "bundleIdentifier", "sku", "primaryLocale"]
    .every((field) => mac[field] === ios[field])
    && canonicalJSON(mac.categories) === canonicalJSON(ios.categories)
    && canonicalJSON(mac.commerce) === canonicalJSON(ios.commerce);
  const categoriesConsistent = canonicalJSON(mac.categories) === canonicalJSON(ios.categories);
  const macLocalizations = new Map((mac.localizations ?? []).map((item) => [item?.locale, item]));
  const iosLocalizations = new Map((ios.localizations ?? []).map((item) => [item?.locale, item]));
  const localizedFieldsConsistent = REQUIRED_LOCALES.every((locale) =>
    ["name", "subtitle", "privacyPolicyURL", "supportURL", "marketingURL"]
      .every((field) => macLocalizations.get(locale)?.[field] === iosLocalizations.get(locale)?.[field]));
  return {
    recordModeSemanticsValid: sharedFieldsConsistent && localizedFieldsConsistent,
    universalPurchaseSharedFieldsConsistent: sharedFieldsConsistent,
    universalPurchaseCategoriesConsistent: categoriesConsistent,
    universalPurchaseLocalizedAppFieldsConsistent: localizedFieldsConsistent,
    primaryLocalesCovered,
    macPrimaryCategoryMatchesProduct: mac.categories?.primary === "developer-tools",
  };
})();
const macManifestReady = manifest !== null
  && manifestStoredInReleaseDirectory
  && manifestWriteProtected
  && identityLock.bound
  && storeAssets.platforms.macos.ready
  && platformStructuralErrors.macos.length === 0
  && platformReleaseBlockers.macos.length === 0;
const iosManifestReady = manifest !== null
  && manifestStoredInReleaseDirectory
  && manifestWriteProtected
  && identityLock.bound
  && storeAssets.platforms.ios.ready
  && platformStructuralErrors.ios.length === 0
  && platformReleaseBlockers.ios.length === 0;
const localPreflightReady = macManifestReady && iosManifestReady;

const output = {
  schemaVersion: 1,
  mode: releaseMode ? "release" : "draft",
  manifest: {
    path: manifestPath?.relative ?? manifestPathValue ?? null,
    source: manifestPathFromEnvironment ? "environment" : "default",
    present: manifest !== null,
    sha256: manifestFile ? sha256(manifestFile.canonical) : null,
    finalizedLocation: manifestStoredInReleaseDirectory,
    writeProtected: manifestWriteProtected,
  },
  projectConfiguration,
  schemaContract,
  derivedChecks,
  recordMode: manifest?.recordMode ?? null,
  appResourceIds: {
    macos: manifest?.records?.macos?.appResourceId ?? null,
    ios: manifest?.records?.ios?.appResourceId ?? null,
  },
  appStoreConnectComparison: {
    verifiedByThisValidator: false,
    requiredBeforeRemoteAction: true,
    formatValidatedOnly: [
      "appResourceId",
      "sku",
      "primaryLocale",
      "commerce.pricing.taxCategory",
      "commerce.pricing.availableTerritories",
    ],
    expected: {
      macos: {
        appResourceId: manifest?.records?.macos?.appResourceId ?? null,
        bundleIdentifier: manifest?.records?.macos?.bundleIdentifier ?? null,
        sku: manifest?.records?.macos?.sku ?? null,
        primaryLocale: manifest?.records?.macos?.primaryLocale ?? null,
        taxCategory: manifest?.records?.macos?.commerce?.pricing?.taxCategory ?? null,
        availableTerritories: manifest?.records?.macos?.commerce?.pricing?.availableTerritories ?? null,
      },
      ios: {
        appResourceId: manifest?.records?.ios?.appResourceId ?? null,
        bundleIdentifier: manifest?.records?.ios?.bundleIdentifier ?? null,
        sku: manifest?.records?.ios?.sku ?? null,
        primaryLocale: manifest?.records?.ios?.primaryLocale ?? null,
        taxCategory: manifest?.records?.ios?.commerce?.pricing?.taxCategory ?? null,
        availableTerritories: manifest?.records?.ios?.commerce?.pricing?.availableTerritories ?? null,
      },
    },
  },
  candidates: {
    macos: {
      bundleIdentifier: manifest?.records?.macos?.bundleIdentifier ?? null,
      version: manifest?.records?.macos?.version?.versionString ?? null,
      build: manifest?.records?.macos?.version?.buildNumber ?? null,
    },
    ios: {
      bundleIdentifier: manifest?.records?.ios?.bundleIdentifier ?? null,
      widgetBundleIdentifier: manifest?.records?.ios?.widgetBundleIdentifier ?? null,
      version: manifest?.records?.ios?.version?.versionString ?? null,
      build: manifest?.records?.ios?.version?.buildNumber ?? null,
    },
  },
  identityLock,
  storeAssets,
  platforms: {
    macos: {
      draftValid: platformStructuralErrors.macos.length === 0,
      storeAssetsReady: storeAssets.platforms.macos.ready,
      submissionManifestReady: macManifestReady,
      structuralErrors: platformStructuralErrors.macos,
      releaseBlockers: platformReleaseBlockers.macos,
    },
    ios: {
      draftValid: platformStructuralErrors.ios.length === 0,
      storeAssetsReady: storeAssets.platforms.ios.ready,
      submissionManifestReady: iosManifestReady,
      structuralErrors: platformStructuralErrors.ios,
      releaseBlockers: platformReleaseBlockers.ios,
    },
  },
  draftValid,
  localPreflightReady,
  appStoreSubmissionManifestReady: localPreflightReady,
  macAppStoreSubmissionManifestReady: macManifestReady,
  iosAppStoreSubmissionManifestReady: iosManifestReady,
  submissionReadyForRemoteAction: false,
  structuralErrors,
  releaseBlockers,
};

process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
if (!draftValid || (releaseMode && !localPreflightReady)) process.exit(1);
