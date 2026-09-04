#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  closeSync,
  constants as fsConstants,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
  realpathSync,
} from "node:fs";
import { dirname, isAbsolute, join } from "node:path";
import {
  ASC_ORIGIN,
  AscSnapshotError,
  DEFAULT_PROJECT_ROOT,
  SNAPSHOT_MAX_AGE_SECONDS,
  canonicalJSONString,
  normalizePlatform,
  sealSnapshot,
  verifySnapshotFile,
} from "./app-store-connect-api.mjs";

export const SUBMISSION_METADATA_KIND = "app-store-connect-submission-metadata-snapshot";
export const SUBMISSION_METADATA_SCHEMA_VERSION = 1;

const SHA256_PATTERN = /^[0-9a-f]{64}$/u;
const RESOURCE_ID_PATTERN = /^(?!\.{1,2}$)[^\s/?#]{1,256}$/u;
const REQUIRED_LOCALES = Object.freeze(["en-US", "zh-Hans"]);
// AppInfo can expose both the currently live record and the record being
// prepared for the next release. Prefer the unique next-release record; use
// the live record only when no staged record exists. Never guess by order.
const STAGED_APP_INFO_STATES = new Set([
  "ACCEPTED",
  "IN_REVIEW",
  "PENDING_RELEASE",
  "PREPARE_FOR_SUBMISSION",
  "READY_FOR_REVIEW",
  "WAITING_FOR_REVIEW",
]);
const LIVE_APP_INFO_STATES = new Set(["READY_FOR_DISTRIBUTION"]);
const KNOWN_APP_INFO_STATES = new Set([
  ...STAGED_APP_INFO_STATES,
  ...LIVE_APP_INFO_STATES,
  "DEVELOPER_REJECTED",
  "REJECTED",
  "REPLACED_WITH_NEW_INFO",
]);
const REVIEW_SELECTION_VERSION_STATES = new Set([
  "PREPARE_FOR_SUBMISSION",
  "READY_FOR_REVIEW",
]);
const APP_CATEGORY_SLUGS = new Map(Object.entries({
  BOOKS: "books",
  BUSINESS: "business",
  DEVELOPER_TOOLS: "developer-tools",
  EDUCATION: "education",
  ENTERTAINMENT: "entertainment",
  FINANCE: "finance",
  FOOD_AND_DRINK: "food-drink",
  GAMES: "games",
  GRAPHICS_AND_DESIGN: "graphics-design",
  HEALTH_AND_FITNESS: "health-fitness",
  LIFESTYLE: "lifestyle",
  MAGAZINES_AND_NEWSPAPERS: "magazines-newspapers",
  MEDICAL: "medical",
  MUSIC: "music",
  NAVIGATION: "navigation",
  NEWS: "news",
  PHOTO_AND_VIDEO: "photography-video",
  PRODUCTIVITY: "productivity",
  REFERENCE: "reference",
  SHOPPING: "shopping",
  SOCIAL_NETWORKING: "social-networking",
  SPORTS: "sports",
  TRAVEL: "travel",
  UTILITIES: "utilities",
  WEATHER: "weather",
}));
const MANIFEST_KEYS = Object.freeze({
  root: ["schemaVersion", "productName", "recordMode", "identityLockSHA256", "screenshotEvidencePath", "screenshotEvidenceSHA256", "records"],
  records: ["macos", "ios"],
  commonRecord: ["appResourceId", "bundleIdentifier", "sku", "primaryLocale", "version", "categories", "commerce", "review", "localizations", "screenshotSets"],
  version: ["versionString", "buildNumber", "releaseKind", "releaseMode", "scheduledReleaseAt", "copyright"],
  categories: ["primary", "secondary"],
  commerce: ["ageRating", "madeForKids", "contentRights", "eula", "digitalServicesAct", "pricing", "exportCompliance"],
  ageRating: ["questionnaireStatus", "declaredRating"],
  contentRights: ["status", "notes"],
  eula: ["type", "customText", "territories"],
  dsa: ["traderStatus", "verificationStatus"],
  pricing: ["model", "pricePointReference", "taxCategory", "availableTerritories"],
  exportCompliance: ["usesNonExemptEncryption", "status", "documentationReference"],
  review: ["contact", "login", "notes"],
  contact: ["firstName", "lastName", "email", "phone"],
  login: ["strategy", "credentialsSecretReference", "instructions"],
  localization: ["locale", "name", "subtitle", "promotionalText", "description", "keywords", "whatsNew", "privacyPolicyURL", "supportURL", "marketingURL"],
  screenshotSet: ["locale", "device", "orderedPaths"],
  iosExtension: ["widgetBundleIdentifier", "testFlight"],
  testFlight: ["distribution", "feedbackEmail", "betaReviewContact", "betaReviewNotes", "login", "localizations"],
  testFlightLocalization: ["locale", "betaAppDescription", "whatToTest"],
});

function fail(code, message) {
  throw new AscSnapshotError(code, message);
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function exactKeys(value, keys, label) {
  if (!isObject(value)) fail("SNAPSHOT_INVALID", `${label} must be an object`);
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (canonicalJSONString(actual) !== canonicalJSONString(expected)) {
    fail("SNAPSHOT_INVALID", `${label} has unexpected or missing fields`);
  }
}

function exactManifestKeys(value, keys, label) {
  if (!isObject(value)) fail("MANIFEST_INVALID", `${label} must be an object`);
  if (canonicalJSONString(Object.keys(value).sort()) !== canonicalJSONString([...keys].sort())) {
    fail("MANIFEST_INVALID", `${label} has unexpected or missing fields`);
  }
}

function requireString(value, label, { allowEmpty = false } = {}) {
  if (typeof value !== "string" || (!allowEmpty && value.length === 0)) {
    fail("MANIFEST_INVALID", `${label} must be ${allowEmpty ? "a" : "a non-empty"} string`);
  }
  return value;
}

function requireResource(resource, type, label) {
  if (
    !isObject(resource) ||
    resource.type !== type ||
    typeof resource.id !== "string" ||
    !RESOURCE_ID_PATTERN.test(resource.id) ||
    !isObject(resource.attributes)
  ) {
    fail("ASC_RESPONSE_INVALID", `${label} resource is missing or invalid`);
  }
  return resource;
}

function relationshipData(resource, name, label) {
  const relationship = resource?.relationships?.[name];
  if (!isObject(relationship) || !Object.hasOwn(relationship, "data")) {
    fail("ASC_RESPONSE_INVALID", `${label} relationship is missing`);
  }
  return relationship.data;
}

function relationshipOne(resource, name, type, label, { nullable = false } = {}) {
  const linkage = relationshipData(resource, name, label);
  if (linkage === null && nullable) return null;
  if (
    !isObject(linkage) ||
    linkage.type !== type ||
    typeof linkage.id !== "string" ||
    !RESOURCE_ID_PATTERN.test(linkage.id)
  ) {
    fail("ASC_RESPONSE_INVALID", `${label} relationship linkage is invalid`);
  }
  return linkage.id;
}

function indexIncluded(resources) {
  if (!Array.isArray(resources)) fail("ASC_RESPONSE_INVALID", "included resources are missing");
  const index = new Map();
  for (const resource of resources) {
    if (!isObject(resource) || typeof resource.type !== "string" || typeof resource.id !== "string") {
      fail("ASC_RESPONSE_INVALID", "included resource is invalid");
    }
    const key = `${resource.type}:${resource.id}`;
    if (index.has(key) && canonicalJSONString(index.get(key)) !== canonicalJSONString(resource)) {
      fail("ASC_RESPONSE_INVALID", `included resource ${key} is conflicting`);
    }
    index.set(key, resource);
  }
  return index;
}

function linkedResource(resource, relationship, type, index, label, options = {}) {
  const id = relationshipOne(resource, relationship, type, label, options);
  if (id === null) return null;
  return requireResource(index.get(`${type}:${id}`), type, `${label} included`);
}

function uniqueCollection(collection, type, label) {
  if (!isObject(collection) || !Array.isArray(collection.data) || !Array.isArray(collection.requests)) {
    fail("ASC_RESPONSE_INVALID", `${label} collection is invalid`);
  }
  if (collection.data.some((item) => item?.type !== type)) {
    fail("ASC_RESPONSE_INVALID", `${label} collection contains an unexpected resource type`);
  }
  if (collection.data.length !== 1) {
    fail("ASC_METADATA_NOT_UNIQUE", `${label} must contain exactly one resource; received ${collection.data.length}`);
  }
  return requireResource(collection.data[0], type, label);
}

function collectionResources(collection, type, label) {
  if (!isObject(collection) || !Array.isArray(collection.data) || !Array.isArray(collection.requests)) {
    fail("ASC_RESPONSE_INVALID", `${label} collection is invalid`);
  }
  return collection.data.map((item) => requireResource(item, type, label));
}

function selectComparableAppInfo(collection) {
  if (!isObject(collection) || !Array.isArray(collection.data) || !Array.isArray(collection.requests)) {
    fail("ASC_RESPONSE_INVALID", "App Info collection is invalid");
  }
  if (collection.data.some((item) => item?.type !== "appInfos")) {
    fail("ASC_RESPONSE_INVALID", "App Info collection contains an unexpected resource type");
  }
  const resources = collection.data.map((item) => requireResource(item, "appInfos", "App Info"));
  if (resources.some((item) => !KNOWN_APP_INFO_STATES.has(item.attributes.state))) {
    fail("ASC_RESPONSE_INVALID", "App Info contains an unknown state");
  }
  const staged = resources.filter((item) => STAGED_APP_INFO_STATES.has(item.attributes.state));
  const live = resources.filter((item) => LIVE_APP_INFO_STATES.has(item.attributes.state));
  const candidates = staged.length > 0 ? staged : live;
  if (candidates.length !== 1) {
    const states = resources.map((item) => item.attributes.state).sort().join(", ");
    fail("ASC_METADATA_NOT_UNIQUE",
      `App Info must have one deterministic staged-or-live record; received ${candidates.length} (${states})`);
  }
  return candidates[0];
}

function selectAppStoreVersion(collection) {
  if (!isObject(collection) || !Array.isArray(collection.data) || !Array.isArray(collection.requests)) {
    fail("ASC_RESPONSE_INVALID", "App Store version collection is invalid");
  }
  if (collection.data.some((item) => item?.type !== "appStoreVersions")) {
    fail("ASC_RESPONSE_INVALID", "App Store version collection contains an unexpected resource type");
  }
  const candidates = collection.data
    .map((item) => requireResource(item, "appStoreVersions", "App Store version"))
    .filter((item) => item.attributes.reviewType === "APP_STORE");
  if (candidates.length !== 1) {
    fail("ASC_METADATA_NOT_UNIQUE",
      `App Store version must contain exactly one APP_STORE review resource; received ${candidates.length}`);
  }
  return candidates[0];
}

function inspectFile(filePath, label, { maxBytes = 4 * 1024 * 1024 } = {}) {
  if (typeof filePath !== "string" || !isAbsolute(filePath)) {
    fail("UNSAFE_PATH", `${label} path must be absolute`);
  }
  let canonical;
  let pathStat;
  try {
    canonical = realpathSync(filePath);
    pathStat = lstatSync(filePath);
  } catch {
    fail("BINDING_FILE_MISSING", `${label} does not exist`);
  }
  if (canonical !== filePath || !pathStat.isFile() || pathStat.isSymbolicLink()) {
    fail("UNSAFE_PATH", `${label} must be a canonical regular non-symlink file`);
  }
  let descriptor;
  try {
    descriptor = openSync(filePath, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
  } catch {
    fail("UNSAFE_PATH", `${label} could not be opened without following links`);
  }
  try {
    const opened = fstatSync(descriptor);
    if (
      !opened.isFile() ||
      opened.dev !== pathStat.dev ||
      opened.ino !== pathStat.ino ||
      opened.size < 1 ||
      opened.size > maxBytes
    ) {
      fail("BINDING_FILE_INVALID", `${label} has an invalid size or changed while opening`);
    }
    const bytes = readFileSync(descriptor);
    const closedOver = fstatSync(descriptor);
    if (
      bytes.byteLength !== opened.size ||
      closedOver.dev !== opened.dev ||
      closedOver.ino !== opened.ino ||
      closedOver.size !== opened.size ||
      closedOver.mtimeMs !== opened.mtimeMs ||
      closedOver.ctimeMs !== opened.ctimeMs
    ) {
      fail("BINDING_CHANGED", `${label} changed while it was read`);
    }
    return {
      path: filePath,
      bytes,
      byteLength: bytes.byteLength,
      sha256: createHash("sha256").update(bytes).digest("hex"),
      mode: opened.mode & 0o777,
      device: opened.dev,
      inode: opened.ino,
    };
  } finally {
    closeSync(descriptor);
  }
}

function assertFileUnchanged(original, label) {
  const current = inspectFile(original.path, label, { maxBytes: Math.max(original.byteLength, 1) });
  if (
    current.sha256 !== original.sha256 ||
    current.byteLength !== original.byteLength ||
    current.device !== original.device ||
    current.inode !== original.inode ||
    current.mode !== original.mode
  ) {
    fail("BINDING_CHANGED", `${label} changed while metadata evidence was evaluated`);
  }
  return current;
}

// JSON.parse silently accepts duplicate members. The release manifest is an
// authority-bearing input, so use a bounded strict parser instead.
function parseStrictJSON(bytes, label, errorCode = "MANIFEST_INVALID") {
  let source;
  try {
    source = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    fail(errorCode, `${label}: invalid UTF-8`);
  }
  let index = 0;
  let depth = 0;
  function invalid(message) {
    fail(errorCode, `${label}: ${message}`);
  }
  function whitespace() {
    while (index < source.length && /[\x20\t\r\n]/u.test(source[index])) index += 1;
  }
  function string() {
    const start = index;
    if (source[index] !== '"') invalid("expected string");
    index += 1;
    while (index < source.length) {
      if (source[index] === '"') {
        index += 1;
        try {
          return JSON.parse(source.slice(start, index));
        } catch {
          invalid("invalid string");
        }
      }
      if (source[index] === "\\") {
        index += 1;
        if (index >= source.length || !/["\\/bfnrtu]/u.test(source[index])) invalid("invalid escape");
        if (source[index] === "u") {
          if (!/^[0-9a-fA-F]{4}$/u.test(source.slice(index + 1, index + 5))) invalid("invalid Unicode escape");
          index += 4;
        }
      } else if (source.charCodeAt(index) <= 0x1f) {
        invalid("unescaped control character");
      }
      index += 1;
    }
    invalid("unterminated string");
  }
  function value(location) {
    whitespace();
    if (depth > 100) invalid("maximum nesting depth exceeded");
    if (source[index] === "{") return object(location);
    if (source[index] === "[") return array(location);
    if (source[index] === '"') return string();
    for (const [literal, parsed] of [["true", true], ["false", false], ["null", null]]) {
      if (source.startsWith(literal, index)) {
        index += literal.length;
        return parsed;
      }
    }
    const match = source.slice(index).match(/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/u);
    if (match) {
      index += match[0].length;
      const parsed = Number(match[0]);
      if (!Number.isFinite(parsed)) invalid("non-finite number");
      return parsed;
    }
    invalid("unexpected value");
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
      if (keys.has(key)) invalid(`duplicate key ${JSON.stringify(key)} in ${location}`);
      keys.add(key);
      whitespace();
      if (source[index] !== ":") invalid("expected colon");
      index += 1;
      result[key] = value(`${location}.${key}`);
      whitespace();
      if (source[index] === "}") {
        index += 1;
        depth -= 1;
        return result;
      }
      if (source[index] !== ",") invalid("expected comma or closing brace");
      index += 1;
    }
    invalid("unterminated object");
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
      if (source[index] !== ",") invalid("expected comma or closing bracket");
      index += 1;
    }
    invalid("unterminated array");
  }
  const parsed = value("$");
  whitespace();
  if (index !== source.length) invalid("trailing content");
  return parsed;
}

function manifestString(value, label, { nullable = false, allowEmpty = false } = {}) {
  if (value === null && nullable) return;
  requireString(value, label, { allowEmpty });
}

function manifestBoolean(value, label) {
  if (typeof value !== "boolean") fail("MANIFEST_INVALID", `${label} must be Boolean`);
}

function manifestStringArray(value, label, { minimum = 0, maximum = 200 } = {}) {
  if (!Array.isArray(value) || value.length < minimum || value.length > maximum) {
    fail("MANIFEST_INVALID", `${label} has an invalid number of entries`);
  }
  value.forEach((item, index) => manifestString(item, `${label}[${index}]`));
}

function validateManifestContact(value, label) {
  exactManifestKeys(value, MANIFEST_KEYS.contact, label);
  for (const field of MANIFEST_KEYS.contact) manifestString(value[field], `${label}.${field}`);
}

function validateManifestLogin(value, label) {
  exactManifestKeys(value, MANIFEST_KEYS.login, label);
  if (!["no-login", "review-account", "custom-instructions"].includes(value.strategy)) {
    fail("MANIFEST_INVALID", `${label}.strategy is unsupported`);
  }
  manifestString(value.credentialsSecretReference, `${label}.credentialsSecretReference`, { nullable: true });
  manifestString(value.instructions, `${label}.instructions`);
  if (value.strategy === "no-login" && value.credentialsSecretReference !== null) {
    fail("MANIFEST_INVALID", `${label}.credentialsSecretReference must be null for no-login`);
  }
  if (value.strategy === "review-account" && value.credentialsSecretReference === null) {
    fail("MANIFEST_INVALID", `${label}.credentialsSecretReference is required for review-account`);
  }
}

function validateManifestReview(value, label) {
  exactManifestKeys(value, MANIFEST_KEYS.review, label);
  validateManifestContact(value.contact, `${label}.contact`);
  validateManifestLogin(value.login, `${label}.login`);
  manifestString(value.notes, `${label}.notes`);
}

function validateManifestLocalization(value, label) {
  exactManifestKeys(value, MANIFEST_KEYS.localization, label);
  if (!REQUIRED_LOCALES.includes(value.locale)) fail("MANIFEST_INVALID", `${label}.locale is unsupported`);
  manifestString(value.name, `${label}.name`);
  manifestString(value.subtitle, `${label}.subtitle`, { allowEmpty: true });
  manifestString(value.promotionalText, `${label}.promotionalText`, { allowEmpty: true });
  manifestString(value.description, `${label}.description`);
  manifestString(value.keywords, `${label}.keywords`);
  manifestString(value.whatsNew, `${label}.whatsNew`, { nullable: true });
  manifestString(value.privacyPolicyURL, `${label}.privacyPolicyURL`);
  manifestString(value.supportURL, `${label}.supportURL`);
  manifestString(value.marketingURL, `${label}.marketingURL`, { nullable: true });
}

function validateManifestCommerce(value, label) {
  exactManifestKeys(value, MANIFEST_KEYS.commerce, label);
  exactManifestKeys(value.ageRating, MANIFEST_KEYS.ageRating, `${label}.ageRating`);
  if (!["complete", "incomplete"].includes(value.ageRating.questionnaireStatus)) {
    fail("MANIFEST_INVALID", `${label}.ageRating.questionnaireStatus is unsupported`);
  }
  manifestString(value.ageRating.declaredRating, `${label}.ageRating.declaredRating`);
  manifestBoolean(value.madeForKids, `${label}.madeForKids`);
  exactManifestKeys(value.contentRights, MANIFEST_KEYS.contentRights, `${label}.contentRights`);
  manifestString(value.contentRights.status, `${label}.contentRights.status`);
  manifestString(value.contentRights.notes, `${label}.contentRights.notes`);
  exactManifestKeys(value.eula, MANIFEST_KEYS.eula, `${label}.eula`);
  if (!["apple-standard", "custom"].includes(value.eula.type)) {
    fail("MANIFEST_INVALID", `${label}.eula.type is unsupported`);
  }
  manifestString(value.eula.customText, `${label}.eula.customText`, { nullable: true });
  manifestStringArray(value.eula.territories, `${label}.eula.territories`, { maximum: 175 });
  exactManifestKeys(value.digitalServicesAct, MANIFEST_KEYS.dsa, `${label}.digitalServicesAct`);
  manifestString(value.digitalServicesAct.traderStatus, `${label}.digitalServicesAct.traderStatus`);
  manifestString(value.digitalServicesAct.verificationStatus, `${label}.digitalServicesAct.verificationStatus`);
  exactManifestKeys(value.pricing, MANIFEST_KEYS.pricing, `${label}.pricing`);
  manifestString(value.pricing.model, `${label}.pricing.model`);
  manifestString(value.pricing.pricePointReference, `${label}.pricing.pricePointReference`, { nullable: true });
  manifestString(value.pricing.taxCategory, `${label}.pricing.taxCategory`);
  manifestStringArray(value.pricing.availableTerritories, `${label}.pricing.availableTerritories`, {
    minimum: 1,
    maximum: 175,
  });
  exactManifestKeys(value.exportCompliance, MANIFEST_KEYS.exportCompliance, `${label}.exportCompliance`);
  manifestBoolean(value.exportCompliance.usesNonExemptEncryption,
    `${label}.exportCompliance.usesNonExemptEncryption`);
  manifestString(value.exportCompliance.status, `${label}.exportCompliance.status`);
  manifestString(value.exportCompliance.documentationReference,
    `${label}.exportCompliance.documentationReference`, { nullable: true });
}

function validateManifestRecord(value, platformKey) {
  const label = `records.${platformKey}`;
  exactManifestKeys(value,
    platformKey === "ios" ? [...MANIFEST_KEYS.commonRecord, ...MANIFEST_KEYS.iosExtension] : MANIFEST_KEYS.commonRecord,
    label);
  for (const field of ["appResourceId", "bundleIdentifier", "sku", "primaryLocale"]) {
    manifestString(value[field], `${label}.${field}`);
  }
  exactManifestKeys(value.version, MANIFEST_KEYS.version, `${label}.version`);
  manifestString(value.version.versionString, `${label}.version.versionString`);
  manifestString(value.version.buildNumber, `${label}.version.buildNumber`);
  if (!["initial", "update"].includes(value.version.releaseKind)) {
    fail("MANIFEST_INVALID", `${label}.version.releaseKind is unsupported`);
  }
  if (!["manual", "automatic", "scheduled"].includes(value.version.releaseMode)) {
    fail("MANIFEST_INVALID", `${label}.version.releaseMode is unsupported`);
  }
  manifestString(value.version.scheduledReleaseAt, `${label}.version.scheduledReleaseAt`, { nullable: true });
  manifestString(value.version.copyright, `${label}.version.copyright`);
  exactManifestKeys(value.categories, MANIFEST_KEYS.categories, `${label}.categories`);
  manifestString(value.categories.primary, `${label}.categories.primary`);
  manifestString(value.categories.secondary, `${label}.categories.secondary`, { nullable: true });
  validateManifestCommerce(value.commerce, `${label}.commerce`);
  validateManifestReview(value.review, `${label}.review`);
  if (!Array.isArray(value.localizations) || value.localizations.length !== REQUIRED_LOCALES.length) {
    fail("MANIFEST_INVALID", `${label}.localizations must contain exactly two entries`);
  }
  value.localizations.forEach((item, index) => validateManifestLocalization(item,
    `${label}.localizations[${index}]`));
  if (new Set(value.localizations.map((item) => item.locale)).size !== REQUIRED_LOCALES.length) {
    fail("MANIFEST_INVALID", `${label}.localizations must contain unique zh-Hans and en-US entries`);
  }
  for (const [index, localization] of value.localizations.entries()) {
    const whatsNewLabel = `${label}.localizations[${index}].whatsNew`;
    if (value.version.releaseKind === "initial" && localization.whatsNew !== null) {
      fail("MANIFEST_INVALID", `${whatsNewLabel} must be null for an initial release`);
    }
    if (value.version.releaseKind === "update") manifestString(localization.whatsNew, whatsNewLabel);
  }
  if (!Array.isArray(value.screenshotSets) || value.screenshotSets.length < 2 || value.screenshotSets.length > 20) {
    fail("MANIFEST_INVALID", `${label}.screenshotSets must contain 2-20 entries`);
  }
  value.screenshotSets.forEach((set, index) => {
    const setLabel = `${label}.screenshotSets[${index}]`;
    exactManifestKeys(set, MANIFEST_KEYS.screenshotSet, setLabel);
    if (!REQUIRED_LOCALES.includes(set.locale)) fail("MANIFEST_INVALID", `${setLabel}.locale is unsupported`);
    manifestString(set.device, `${setLabel}.device`);
    manifestStringArray(set.orderedPaths, `${setLabel}.orderedPaths`, { minimum: 1, maximum: 10 });
  });
  if (!REQUIRED_LOCALES.every((locale) => value.screenshotSets.some((set) => set.locale === locale))) {
    fail("MANIFEST_INVALID", `${label}.screenshotSets must cover zh-Hans and en-US`);
  }
  if (platformKey === "ios") {
    manifestString(value.widgetBundleIdentifier, `${label}.widgetBundleIdentifier`);
    exactManifestKeys(value.testFlight, MANIFEST_KEYS.testFlight, `${label}.testFlight`);
    if (!["internal-only", "external"].includes(value.testFlight.distribution)) {
      fail("MANIFEST_INVALID", `${label}.testFlight.distribution is unsupported`);
    }
    manifestString(value.testFlight.feedbackEmail, `${label}.testFlight.feedbackEmail`);
    validateManifestContact(value.testFlight.betaReviewContact, `${label}.testFlight.betaReviewContact`);
    manifestString(value.testFlight.betaReviewNotes, `${label}.testFlight.betaReviewNotes`);
    validateManifestLogin(value.testFlight.login, `${label}.testFlight.login`);
    if (!Array.isArray(value.testFlight.localizations) ||
        value.testFlight.localizations.length !== REQUIRED_LOCALES.length) {
      fail("MANIFEST_INVALID", `${label}.testFlight.localizations must contain exactly two entries`);
    }
    value.testFlight.localizations.forEach((item, index) => {
      const itemLabel = `${label}.testFlight.localizations[${index}]`;
      exactManifestKeys(item, MANIFEST_KEYS.testFlightLocalization, itemLabel);
      if (!REQUIRED_LOCALES.includes(item.locale)) fail("MANIFEST_INVALID", `${itemLabel}.locale is unsupported`);
      manifestString(item.betaAppDescription, `${itemLabel}.betaAppDescription`);
      manifestString(item.whatToTest, `${itemLabel}.whatToTest`);
    });
    if (new Set(value.testFlight.localizations.map((item) => item.locale)).size !== REQUIRED_LOCALES.length) {
      fail("MANIFEST_INVALID", `${label}.testFlight.localizations must contain unique locales`);
    }
  }
}

function validateManifestContract(manifest) {
  exactManifestKeys(manifest, MANIFEST_KEYS.root, "manifest");
  if (manifest.schemaVersion !== 1) fail("MANIFEST_INVALID", "manifest.schemaVersion must be 1");
  manifestString(manifest.productName, "manifest.productName");
  if (!["universal-purchase", "separate-records"].includes(manifest.recordMode)) {
    fail("MANIFEST_INVALID", "manifest.recordMode is unsupported");
  }
  if (!SHA256_PATTERN.test(manifest.identityLockSHA256 ?? "") ||
      !SHA256_PATTERN.test(manifest.screenshotEvidenceSHA256 ?? "")) {
    fail("MANIFEST_INVALID", "manifest evidence hashes must be lowercase SHA-256 values");
  }
  manifestString(manifest.screenshotEvidencePath, "manifest.screenshotEvidencePath");
  exactManifestKeys(manifest.records, MANIFEST_KEYS.records, "manifest.records");
  validateManifestRecord(manifest.records.macos, "macos");
  validateManifestRecord(manifest.records.ios, "ios");
}

function normalizeManifest(manifest, platform, expected) {
  validateManifestContract(manifest);
  const platformKey = platform === "IOS" ? "ios" : "macos";
  const record = manifest.records[platformKey];
  if (!isObject(record) || !isObject(record.version) || !isObject(record.commerce) || !isObject(record.review)) {
    fail("MANIFEST_INVALID", `submission manifest ${platformKey} record is incomplete`);
  }
  requireString(manifest.productName, "manifest.productName");
  requireString(manifest.recordMode, "manifest.recordMode");
  requireString(manifest.identityLockSHA256, "manifest.identityLockSHA256");
  requireString(record.appResourceId, `records.${platformKey}.appResourceId`);
  requireString(record.bundleIdentifier, `records.${platformKey}.bundleIdentifier`);
  requireString(record.sku, `records.${platformKey}.sku`);
  requireString(record.primaryLocale, `records.${platformKey}.primaryLocale`);
  requireString(record.version.versionString, `records.${platformKey}.version.versionString`);
  requireString(record.version.buildNumber, `records.${platformKey}.version.buildNumber`);
  if (
    record.bundleIdentifier !== expected.bundleId ||
    record.version.versionString !== expected.version ||
    record.version.buildNumber !== expected.build
  ) {
    fail("MANIFEST_BINDING_MISMATCH", "submission manifest does not match the expected candidate tuple");
  }
  if (!Array.isArray(record.localizations)) fail("MANIFEST_INVALID", "manifest localizations must be an array");
  const localizationByLocale = new Map();
  for (const localization of record.localizations) {
    if (!isObject(localization)) fail("MANIFEST_INVALID", "manifest localization is invalid");
    const locale = requireString(localization.locale, "manifest localization locale");
    if (localizationByLocale.has(locale)) fail("MANIFEST_INVALID", `manifest localization ${locale} is duplicated`);
    localizationByLocale.set(locale, localization);
  }
  if (!REQUIRED_LOCALES.every((locale) => localizationByLocale.has(locale))) {
    fail("MANIFEST_INVALID", "manifest must contain zh-Hans and en-US localizations");
  }
  let testFlightLocalizationByLocale = null;
  if (platform === "IOS") {
    if (!isObject(record.testFlight) || !Array.isArray(record.testFlight.localizations)) {
      fail("MANIFEST_INVALID", "iOS TestFlight manifest metadata is incomplete");
    }
    testFlightLocalizationByLocale = new Map();
    for (const localization of record.testFlight.localizations) {
      if (!isObject(localization)) fail("MANIFEST_INVALID", "TestFlight localization is invalid");
      const locale = requireString(localization.locale, "TestFlight localization locale");
      if (testFlightLocalizationByLocale.has(locale)) {
        fail("MANIFEST_INVALID", `TestFlight localization ${locale} is duplicated`);
      }
      testFlightLocalizationByLocale.set(locale, localization);
    }
    if (!REQUIRED_LOCALES.every((locale) => testFlightLocalizationByLocale.has(locale))) {
      fail("MANIFEST_INVALID", "TestFlight manifest must contain zh-Hans and en-US localizations");
    }
  }
  return { manifest, record, platformKey, localizationByLocale, testFlightLocalizationByLocale };
}

function normalizeOptionalString(value, label) {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") fail("ASC_RESPONSE_INVALID", `${label} must be a string or null`);
  return value;
}

function normalizeLocalization(resource, type, fields, label) {
  const checked = requireResource(resource, type, label);
  if (typeof checked.attributes.locale !== "string" || checked.attributes.locale.length === 0) {
    fail("ASC_RESPONSE_INVALID", `${label} locale is missing`);
  }
  const result = { resourceID: checked.id, locale: checked.attributes.locale };
  for (const field of fields) {
    result[field] = normalizeOptionalString(checked.attributes[field], `${label}.${field}`);
  }
  return result;
}

function sortAndRejectDuplicateLocales(resources, label) {
  const seen = new Set();
  for (const resource of resources) {
    if (seen.has(resource.locale)) fail("ASC_RESPONSE_INVALID", `${label} contains duplicate locale ${resource.locale}`);
    seen.add(resource.locale);
  }
  return [...resources].sort((left, right) => left.locale.localeCompare(right.locale));
}

function assertExactLocaleSet(resources, label, errorCode = "ASC_RESPONSE_INVALID") {
  if (!Array.isArray(resources)) fail(errorCode, `${label} must be an array`);
  const locales = resources.map((resource) => resource?.locale);
  if (
    locales.some((locale) => typeof locale !== "string") ||
    new Set(locales).size !== locales.length ||
    canonicalJSONString([...locales].sort()) !== canonicalJSONString([...REQUIRED_LOCALES].sort())
  ) {
    fail(errorCode, `${label} must contain exactly one en-US and one zh-Hans resource`);
  }
  return resources;
}

function normalizeReview(resource, type, label, expected, { includeNotes = true } = {}) {
  const attributes = requireResource(resource, type, label).attributes;
  if (attributes.demoAccountRequired !== null && typeof attributes.demoAccountRequired !== "boolean") {
    fail("ASC_RESPONSE_INVALID", `${label}.demoAccountRequired must be Boolean or null`);
  }
  const optional = (field) => normalizeOptionalString(attributes[field], `${label}.${field}`);
  return {
    resourceID: resource.id,
    contactMatches: {
      firstName: optional("contactFirstName") === expected.contact.firstName,
      lastName: optional("contactLastName") === expected.contact.lastName,
      email: optional("contactEmail") === expected.contact.email,
      phone: optional("contactPhone") === expected.contact.phone,
    },
    demoAccountRequired: attributes.demoAccountRequired,
    notesMatch: includeNotes ? optional("notes") === expected.notes : null,
  };
}

function categorySlug(resource, platform) {
  if (resource === null) return null;
  const category = requireResource(resource, "appCategories", "App category");
  const slug = APP_CATEGORY_SLUGS.get(category.id);
  if (!slug) fail("ASC_RESPONSE_INVALID", `App category ${category.id} is unsupported`);
  if (!Array.isArray(category.attributes.platforms) || !category.attributes.platforms.includes(platform)) {
    fail("ASC_RESPONSE_INVALID", `App category ${category.id} is not valid for ${platform}`);
  }
  return slug;
}

function normalizeTimestamp(value) {
  if (value === null || value === undefined) return null;
  if (typeof value !== "string" || !Number.isFinite(Date.parse(value))) return value;
  return new Date(value).toISOString().replace(".000Z", "Z");
}

function ascReleaseMode(value) {
  return ({ MANUAL: "manual", AFTER_APPROVAL: "automatic", SCHEDULED: "scheduled" })[value] ?? value ?? null;
}

function ascContentRights(value) {
  return ({
    DOES_NOT_USE_THIRD_PARTY_CONTENT: "does-not-use-third-party-content",
    USES_THIRD_PARTY_CONTENT: "uses-third-party-content-rights-cleared",
  })[value] ?? value ?? null;
}

function localeMap(resources) {
  return new Map(resources.map((resource) => [resource.locale, resource]));
}

function expectedDemoAccountRequired(login) {
  if (login?.strategy === "review-account") return true;
  if (login?.strategy === "no-login") return false;
  return null;
}

function comparisonEntry(source, path, expected, actual) {
  return {
    source,
    path,
    expected: expected === undefined ? null : expected,
    actual: actual === undefined ? null : actual,
    matches: canonicalJSONString(expected === undefined ? null : expected) ===
      canonicalJSONString(actual === undefined ? null : actual),
  };
}

function buildComparison(normalizedManifest, remote, buildSnapshot) {
  const { manifest, record, platformKey, localizationByLocale, testFlightLocalizationByLocale } = normalizedManifest;
  const prefix = `records.${platformKey}`;
  const entries = [];
  const api = (path, expected, actual) => entries.push(comparisonEntry("app-store-connect-api", path, expected, actual));
  const signal = (path, expected, actual) => entries.push(comparisonEntry("api-semantic-signal", path, expected, actual));
  const attest = (path, expected, actual) => entries.push(comparisonEntry("sealed-local-evidence", path, expected, actual));

  api("productName", manifest.productName, remote.app.name);
  api(`${prefix}.appResourceId`, record.appResourceId, remote.app.resourceID);
  api(`${prefix}.bundleIdentifier`, record.bundleIdentifier, remote.app.bundleID);
  api(`${prefix}.sku`, record.sku, remote.app.sku);
  api(`${prefix}.primaryLocale`, record.primaryLocale, remote.app.primaryLocale);
  // Apple's field is lifetime history ("is or ever was"), not a complete
  // current made-for-kids declaration. Preserve the signal and its mismatch,
  // but never count it as an exact API comparison.
  signal(`${prefix}.commerce.madeForKidsLifetimeHistoryCompatible`, true,
    record.commerce.madeForKids !== true || remote.app.isOrEverWasMadeForKids === true);
  api(`${prefix}.commerce.contentRights.status`, record.commerce.contentRights?.status,
    ascContentRights(remote.app.contentRightsDeclaration));
  api(`${prefix}.categories.primary`, record.categories?.primary, remote.appInfo.primaryCategory);
  api(`${prefix}.categories.secondary`, record.categories?.secondary ?? null, remote.appInfo.secondaryCategory);
  signal(`${prefix}.appInfo.selectionStateAllowed`, true,
    STAGED_APP_INFO_STATES.has(remote.appInfo.state) || LIVE_APP_INFO_STATES.has(remote.appInfo.state));
  api(`${prefix}.version.versionString`, record.version.versionString, remote.appStoreVersion.versionString);
  api(`${prefix}.version.releaseKind`, record.version.releaseKind,
    remote.appStoreVersion.localizations.every((item) => item.whatsNew === null)
      ? "initial"
      : remote.appStoreVersion.localizations.every((item) => typeof item.whatsNew === "string" && item.whatsNew.length > 0)
        ? "update"
        : "mixed-or-invalid");
  api(`${prefix}.version.releaseMode`, record.version.releaseMode,
    ascReleaseMode(remote.appStoreVersion.releaseType));
  api(`${prefix}.version.scheduledReleaseAt`, normalizeTimestamp(record.version.scheduledReleaseAt),
    normalizeTimestamp(remote.appStoreVersion.earliestReleaseDate));
  api(`${prefix}.version.copyright`, record.version.copyright, remote.appStoreVersion.copyright);
  api(`${prefix}.version.buildNumber`, record.version.buildNumber, remote.build.buildNumber);
  api(`${prefix}.commerce.exportCompliance.usesNonExemptEncryption`,
    record.commerce.exportCompliance?.usesNonExemptEncryption,
    remote.build.usesNonExemptEncryption);
  signal(`${prefix}.version.reviewType`, "APP_STORE", remote.appStoreVersion.reviewType);
  signal(`${prefix}.version.selectionStateAllowed`, true,
    REVIEW_SELECTION_VERSION_STATES.has(remote.appStoreVersion.appVersionState));

  const infoLocalizations = localeMap(remote.appInfo.localizations);
  const versionLocalizations = localeMap(remote.appStoreVersion.localizations);
  for (const locale of REQUIRED_LOCALES) {
    const expectedLocalization = localizationByLocale.get(locale);
    const actualInfo = infoLocalizations.get(locale) ?? {};
    const actualVersion = versionLocalizations.get(locale) ?? {};
    const localePrefix = `${prefix}.localizations[${locale}]`;
    api(`${localePrefix}.name`, expectedLocalization.name, actualInfo.name);
    api(`${localePrefix}.subtitle`, expectedLocalization.subtitle, actualInfo.subtitle);
    api(`${localePrefix}.privacyPolicyURL`, expectedLocalization.privacyPolicyURL, actualInfo.privacyPolicyUrl);
    api(`${localePrefix}.promotionalText`, expectedLocalization.promotionalText, actualVersion.promotionalText);
    api(`${localePrefix}.description`, expectedLocalization.description, actualVersion.description);
    api(`${localePrefix}.keywords`, expectedLocalization.keywords, actualVersion.keywords);
    api(`${localePrefix}.whatsNew`, expectedLocalization.whatsNew, actualVersion.whatsNew);
    api(`${localePrefix}.supportURL`, expectedLocalization.supportURL, actualVersion.supportUrl);
    api(`${localePrefix}.marketingURL`, expectedLocalization.marketingURL, actualVersion.marketingUrl);
  }

  const expectedReview = record.review;
  const actualReview = remote.appStoreVersion.review;
  for (const field of ["firstName", "lastName", "email", "phone"]) {
    api(`${prefix}.review.contact.${field}`, true, actualReview.contactMatches[field]);
  }
  const reviewAccountRequired = expectedDemoAccountRequired(expectedReview.login);
  if (reviewAccountRequired !== null) {
    api(`${prefix}.review.login.accountRequired`, reviewAccountRequired, actualReview.demoAccountRequired);
  }
  api(`${prefix}.review.notes`, true, actualReview.notesMatch);

  attest("recordMode", manifest.recordMode, buildSnapshot.releaseIdentity.appStoreRecordMode);
  attest("identityLockSHA256", manifest.identityLockSHA256,
    buildSnapshot.candidate.releaseIdentityLockSHA256);
  attest(`${prefix}.version.buildNumber`, record.version.buildNumber, buildSnapshot.query.build);
  attest(`${prefix}.version.versionString`, record.version.versionString, buildSnapshot.query.version);
  attest(`${prefix}.bundleIdentifier`, record.bundleIdentifier, buildSnapshot.query.bundleID);
  attest(`${prefix}.appResourceId`, record.appResourceId, buildSnapshot.resourceIDs.app);
  attest(`${prefix}.remoteBuildResourceId`, remote.build.resourceID, buildSnapshot.resourceIDs.build);
  attest(`${prefix}.remoteBuildEncryption`, remote.build.usesNonExemptEncryption,
    buildSnapshot.build.usesNonExemptEncryption);
  if (platformKey === "ios") {
    attest(`${prefix}.widgetBundleIdentifier`, record.widgetBundleIdentifier,
      buildSnapshot.releaseIdentity.iOSWidgetBundleIdentifier);
  }

  if (platformKey === "ios") {
    const betaBuildLocalizations = localeMap(remote.testFlight.buildLocalizations);
    const betaAppLocalizations = record.testFlight.distribution === "external"
      ? localeMap(remote.testFlight.appLocalizations)
      : null;
    for (const locale of REQUIRED_LOCALES) {
      const expectedLocalization = testFlightLocalizationByLocale.get(locale);
      const actualBuild = betaBuildLocalizations.get(locale) ?? {};
      api(`${prefix}.testFlight.localizations[${locale}].whatToTest`,
        expectedLocalization.whatToTest, actualBuild.whatsNew);
      if (record.testFlight.distribution === "external") {
        const actualApp = betaAppLocalizations.get(locale) ?? {};
        api(`${prefix}.testFlight.feedbackEmail[${locale}]`, record.testFlight.feedbackEmail,
          actualApp.feedbackEmail);
        api(`${prefix}.testFlight.localizations[${locale}].betaAppDescription`,
          expectedLocalization.betaAppDescription, actualApp.description);
      }
    }
    if (record.testFlight.distribution === "external") {
      const actualBetaReview = remote.testFlight.review;
      for (const field of ["firstName", "lastName", "email", "phone"]) {
        api(`${prefix}.testFlight.betaReviewContact.${field}`, true,
          actualBetaReview?.contactMatches?.[field]);
      }
      const betaAccountRequired = expectedDemoAccountRequired(record.testFlight.login);
      if (betaAccountRequired !== null) {
        api(`${prefix}.testFlight.login.accountRequired`, betaAccountRequired,
          actualBetaReview?.demoAccountRequired);
      }
      api(`${prefix}.testFlight.betaReviewNotes`, true, actualBetaReview?.notesMatch);
    }
  }
  return entries;
}

function manualCoverage(platformKey, testFlightDistribution = null) {
  const prefix = `records.${platformKey}`;
  const result = [
    { path: "screenshotEvidencePath", reason: "validated by the separate screenshot-evidence release gate" },
    { path: "screenshotEvidenceSHA256", reason: "validated by the separate screenshot-evidence release gate" },
    { path: `${prefix}.commerce.ageRating.*`, reason: "the questionnaire and final rating require App Store Connect review" },
    { path: `${prefix}.commerce.madeForKids`, reason: "isOrEverWasMadeForKids is a lifetime-history signal, not an exact current declaration" },
    { path: `${prefix}.commerce.contentRights.notes`, reason: "local legal rationale is not an App Store Connect field" },
    { path: `${prefix}.commerce.eula.*`, reason: "not captured by this conservative read-only endpoint set" },
    { path: `${prefix}.commerce.digitalServicesAct.*`, reason: "not exposed by the verified App Store Connect API schema" },
    { path: `${prefix}.commerce.pricing.*`, reason: "territory, tax, and price decisions are outside this snapshot" },
    { path: `${prefix}.commerce.exportCompliance.status`, reason: "legal/export approval remains a manual release decision" },
    { path: `${prefix}.commerce.exportCompliance.documentationReference`, reason: "private legal evidence is validated separately" },
    { path: `${prefix}.review.login.credentialsSecretReference`, reason: "secrets are intentionally never resolved or captured" },
    { path: `${prefix}.review.login.strategy`, reason: "the API proves only whether a demo account is required, not the full local strategy enum" },
    { path: `${prefix}.review.login.instructions`, reason: "App Store Connect exposes review notes, not this local instruction field" },
    { path: `${prefix}.screenshotSets[*]`, reason: "validated by the separate screenshot-evidence release gate" },
  ];
  if (platformKey === "ios") {
    result.push(
      { path: `${prefix}.testFlight.distribution`, reason: "internal/external distribution intent is not proven by these metadata endpoints" },
      { path: `${prefix}.testFlight.login.credentialsSecretReference`, reason: "secrets are intentionally never resolved or captured" },
      { path: `${prefix}.testFlight.login.strategy`, reason: "the API proves only whether a demo account is required, not the full local strategy enum" },
      { path: `${prefix}.testFlight.login.instructions`, reason: "Beta App Review notes do not model this local instruction field" },
    );
    if (testFlightDistribution === "internal-only") {
      result.push(
        {
          path: `${prefix}.testFlight.feedbackEmail/betaReviewContact/betaReviewNotes/betaAppDescription`,
          reason: "internal-only TestFlight does not require Beta App Review or Beta App Description metadata; these fields are intentionally not queried",
        },
      );
    }
  }
  return result;
}

function buildCoverage(entries, platformKey, testFlightDistribution = null) {
  const apiEntries = entries.filter((entry) => entry.source === "app-store-connect-api");
  const semanticSignals = entries.filter((entry) => entry.source === "api-semantic-signal");
  const attestations = entries.filter((entry) => entry.source === "sealed-local-evidence");
  const manual = manualCoverage(platformKey, testFlightDistribution);
  const allAPIComparisonsMatch = apiEntries.every((entry) => entry.matches);
  const allSeparateAttestationsMatch = attestations.every((entry) => entry.matches);
  const everyRequiredFieldVerified = manual.length === 0 && allAPIComparisonsMatch && allSeparateAttestationsMatch;
  return {
    schemaVersion: 1,
    apiComparedPaths: apiEntries.map((entry) => entry.path),
    semanticSignalPaths: semanticSignals.map((entry) => entry.path),
    separatelyAttestedPaths: attestations.map((entry) => entry.path),
    manualOrUnsupported: manual,
    intentionallyUncapturedSecrets: [
      "appStoreReviewDetail.demoAccountName",
      "appStoreReviewDetail.demoAccountPassword",
      ...(platformKey === "ios"
        ? ["betaAppReviewDetail.demoAccountName", "betaAppReviewDetail.demoAccountPassword"]
        : []),
    ],
    allRequiredFieldsClassified: true,
    allAPIComparisonsMatch,
    allSeparateAttestationsMatch,
    everyRequiredFieldVerified,
    remoteMetadataComparisonComplete: everyRequiredFieldVerified,
  };
}

function buildReadiness(entries, coverage, platformKey) {
  const prefix = `records.${platformKey}`;
  const pathsMatch = (paths) => paths.every((path) =>
    entries.some((entry) => entry.path === path && entry.matches));
  const appIdentityMatches = pathsMatch([
    "productName",
    `${prefix}.appResourceId`,
    `${prefix}.bundleIdentifier`,
    `${prefix}.sku`,
    `${prefix}.primaryLocale`,
  ]);
  const versionAndSelectedBuildMatch = pathsMatch([
    `${prefix}.version.versionString`,
    `${prefix}.version.releaseKind`,
    `${prefix}.version.buildNumber`,
    `${prefix}.version.releaseMode`,
    `${prefix}.version.scheduledReleaseAt`,
    `${prefix}.version.copyright`,
    `${prefix}.commerce.exportCompliance.usesNonExemptEncryption`,
    `${prefix}.remoteBuildResourceId`,
    `${prefix}.remoteBuildEncryption`,
  ]);
  const semanticSignalsConsistent = entries
    .filter((entry) => entry.source === "api-semantic-signal")
    .every((entry) => entry.matches);
  const apiVisibleMetadataEvidenceReady = appIdentityMatches &&
    versionAndSelectedBuildMatch &&
    coverage.allAPIComparisonsMatch &&
    coverage.allSeparateAttestationsMatch &&
    semanticSignalsConsistent;
  return {
    manifestStrictStructureBound: true,
    authoritativeManifestReleaseValidationBound: false,
    buildSnapshotVerified: true,
    exactRemoteResourcesBound: true,
    appIdentityMatches,
    versionAndSelectedBuildMatch,
    apiComparableMetadataMatches: coverage.allAPIComparisonsMatch,
    semanticSignalsConsistent,
    localAttestationsMatch: coverage.allSeparateAttestationsMatch,
    apiVisibleMetadataEvidenceReady,
    manualComplianceEvidenceComplete: false,
    submissionManifestFullyVerified: false,
    remoteMetadataComparisonComplete: false,
  };
}

function snapshotTimes(now) {
  const instant = now instanceof Date ? now : new Date(now);
  if (!Number.isFinite(instant.getTime())) fail("INVALID_INPUT", "capture time is invalid");
  return {
    capturedAt: instant.toISOString(),
    expiresAt: new Date(instant.getTime() + SNAPSHOT_MAX_AGE_SECONDS * 1000).toISOString(),
  };
}

function submissionRequestSpecifications(normalizedManifest, resourceIDs) {
  const { record, platformKey } = normalizedManifest;
  const platform = platformKey === "ios" ? "IOS" : "MAC_OS";
  const externalBeta = platform === "IOS" && record.testFlight.distribution === "external";
  const appFields = [
    "name", "bundleId", "sku", "primaryLocale", "contentRightsDeclaration", "isOrEverWasMadeForKids",
  ];
  if (externalBeta) appFields.push("betaAppReviewDetail");
  const specifications = [
    {
      path: "/v1/apps",
      query: {
        "filter[bundleId]": record.bundleIdentifier,
        "fields[apps]": appFields.join(","),
        ...(externalBeta ? {
          include: "betaAppReviewDetail",
          "fields[betaAppReviewDetails]": "contactFirstName,contactLastName,contactPhone,contactEmail,demoAccountRequired,notes,app",
        } : {}),
        limit: "200",
      },
    },
    {
      path: `/v1/apps/${encodeURIComponent(resourceIDs.app)}/appInfos`,
      query: {
        "fields[appInfos]": "appStoreState,state,app,primaryCategory,secondaryCategory",
        "fields[appCategories]": "platforms",
        include: "primaryCategory,secondaryCategory",
        limit: "200",
      },
    },
    {
      path: `/v1/appInfos/${encodeURIComponent(resourceIDs.appInfo)}/appInfoLocalizations`,
      query: {
        "fields[appInfoLocalizations]": "locale,name,subtitle,privacyPolicyUrl,privacyChoicesUrl,privacyPolicyText,appInfo",
        limit: "200",
      },
    },
    {
      path: `/v1/apps/${encodeURIComponent(resourceIDs.app)}/appStoreVersions`,
      query: {
        "filter[platform]": platform,
        "filter[versionString]": record.version.versionString,
        "fields[appStoreVersions]": "platform,versionString,appStoreState,appVersionState,reviewType,copyright,releaseType,earliestReleaseDate,app,appStoreReviewDetail,build",
        "fields[appStoreReviewDetails]": "contactFirstName,contactLastName,contactPhone,contactEmail,demoAccountRequired,notes,appStoreVersion",
        "fields[builds]": "version,usesNonExemptEncryption,app",
        include: "appStoreReviewDetail,build",
        limit: "200",
      },
    },
    {
      path: `/v1/appStoreVersions/${encodeURIComponent(resourceIDs.appStoreVersion)}/appStoreVersionLocalizations`,
      query: {
        "fields[appStoreVersionLocalizations]": "description,keywords,locale,marketingUrl,promotionalText,supportUrl,whatsNew,appStoreVersion",
        limit: "200",
      },
    },
  ];
  if (platform === "IOS") {
    if (externalBeta) specifications.push(
      {
        path: `/v1/apps/${encodeURIComponent(resourceIDs.app)}/betaAppLocalizations`,
        query: {
          "fields[betaAppLocalizations]": "feedbackEmail,description,locale,marketingUrl,privacyPolicyUrl,tvOsPrivacyPolicy,app",
          limit: "200",
        },
      },
    );
    specifications.push({
      path: `/v1/builds/${encodeURIComponent(resourceIDs.build)}/betaBuildLocalizations`,
      query: {
        "fields[betaBuildLocalizations]": "locale,whatsNew,build",
        limit: "200",
      },
    });
  }
  return specifications;
}

function canonicalQueryEntries(searchParams, { omitCursor = false } = {}) {
  const entries = [];
  for (const key of new Set(searchParams.keys())) {
    if (omitCursor && key === "cursor") continue;
    const values = searchParams.getAll(key);
    if (values.length !== 1) return null;
    entries.push([key, values[0]]);
  }
  return entries.sort(([left], [right]) => left.localeCompare(right));
}

function expectedQueryEntries(query) {
  return Object.entries(query).sort(([left], [right]) => left.localeCompare(right));
}

function requestEvidenceIsValid(requests, specifications) {
  if (!Array.isArray(requests) || requests.length === 0 || !Array.isArray(specifications)) return false;
  if (requests.length > specifications.length * 10) return false;
  const initialCounts = new Map(specifications.map((specification) => [specification.path, 0]));
  const seen = new Set();
  const valid = requests.every((request) => {
    if (!isObject(request) || canonicalJSONString(Object.keys(request).sort()) !== canonicalJSONString([
      "method", "pathAndQuery", "responseBytes", "responseSHA256", "status",
    ])) return false;
    if (request.method !== "GET" || typeof request.pathAndQuery !== "string" ||
        !request.pathAndQuery.startsWith("/v1/") || request.status !== 200 ||
        !Number.isSafeInteger(request.responseBytes) || request.responseBytes < 0 ||
        !SHA256_PATTERN.test(request.responseSHA256 ?? "") || seen.has(request.pathAndQuery)) return false;
    seen.add(request.pathAndQuery);
    let url;
    try {
      url = new URL(request.pathAndQuery, ASC_ORIGIN);
    } catch {
      return false;
    }
    if (url.origin !== ASC_ORIGIN || url.hash || url.username || url.password) return false;
    const specification = specifications.find((candidate) => candidate.path === url.pathname);
    if (!specification) return false;
    const actualInvariant = canonicalQueryEntries(url.searchParams, { omitCursor: true });
    if (actualInvariant === null ||
        canonicalJSONString(actualInvariant) !== canonicalJSONString(expectedQueryEntries(specification.query))) return false;
    const cursors = url.searchParams.getAll("cursor");
    if (cursors.length === 0) {
      initialCounts.set(specification.path, initialCounts.get(specification.path) + 1);
      return true;
    }
    return cursors.length === 1 && cursors[0].length > 0 && cursors[0].length <= 4096;
  });
  return valid && specifications.every((specification) => initialCounts.get(specification.path) === 1);
}

async function readRemoteMetadata(client, normalizedManifest, buildSnapshot) {
  const { record, platformKey } = normalizedManifest;
  const platform = platformKey === "ios" ? "IOS" : "MAC_OS";
  const externalBeta = platform === "IOS" && record.testFlight.distribution === "external";
  const appFields = [
    "name", "bundleId", "sku", "primaryLocale", "contentRightsDeclaration", "isOrEverWasMadeForKids",
  ];
  if (externalBeta) appFields.push("betaAppReviewDetail");
  const appCollection = await client.getCollection("/v1/apps", {
    "filter[bundleId]": record.bundleIdentifier,
    "fields[apps]": appFields.join(","),
    ...(externalBeta ? {
      include: "betaAppReviewDetail",
      "fields[betaAppReviewDetails]": "contactFirstName,contactLastName,contactPhone,contactEmail,demoAccountRequired,notes,app",
    } : {}),
    limit: "200",
  });
  const app = uniqueCollection(appCollection, "apps", "App");
  if (app.attributes.bundleId !== record.bundleIdentifier) {
    fail("ASC_APP_MISMATCH", "App Store Connect returned a different bundle ID");
  }
  if (app.id !== buildSnapshot.resourceIDs.app) {
    fail("ASC_RESPONSE_DRIFT", "metadata App resource differs from the sealed Build snapshot");
  }
  const appIncluded = indexIncluded(appCollection.included);

  const appInfoCollection = await client.getCollection(`/v1/apps/${encodeURIComponent(app.id)}/appInfos`, {
    "fields[appInfos]": "appStoreState,state,app,primaryCategory,secondaryCategory",
    "fields[appCategories]": "platforms",
    include: "primaryCategory,secondaryCategory",
    limit: "200",
  });
  const appInfo = selectComparableAppInfo(appInfoCollection);
  if (relationshipOne(appInfo, "app", "apps", "App Info-to-App") !== app.id) {
    fail("ASC_RESPONSE_DRIFT", "App Info points to a different App resource");
  }
  const appInfoIncluded = indexIncluded(appInfoCollection.included);
  const appInfoLocalizationCollection = await client.getCollection(
    `/v1/appInfos/${encodeURIComponent(appInfo.id)}/appInfoLocalizations`,
    {
      "fields[appInfoLocalizations]": "locale,name,subtitle,privacyPolicyUrl,privacyChoicesUrl,privacyPolicyText,appInfo",
      limit: "200",
    },
  );
  const appInfoLocalizations = assertExactLocaleSet(sortAndRejectDuplicateLocales(
    collectionResources(appInfoLocalizationCollection, "appInfoLocalizations",
      "App Info localization").map((resource) => {
      if (relationshipOne(resource, "appInfo", "appInfos", "App Info localization-to-App Info") !== appInfo.id) {
        fail("ASC_RESPONSE_DRIFT", "App Info localization points to a different App Info resource");
      }
      return normalizeLocalization(resource, "appInfoLocalizations",
        ["name", "subtitle", "privacyPolicyUrl", "privacyChoicesUrl", "privacyPolicyText"],
        "App Info localization");
    }),
    "App Info localizations",
  ), "App Info localizations");
  const primaryCategory = linkedResource(appInfo, "primaryCategory", "appCategories", appInfoIncluded,
    "primary category");
  const secondaryCategory = linkedResource(appInfo, "secondaryCategory", "appCategories", appInfoIncluded,
    "secondary category", { nullable: true });

  const versionCollection = await client.getCollection(`/v1/apps/${encodeURIComponent(app.id)}/appStoreVersions`, {
    "filter[platform]": platform,
    "filter[versionString]": record.version.versionString,
    "fields[appStoreVersions]": "platform,versionString,appStoreState,appVersionState,reviewType,copyright,releaseType,earliestReleaseDate,app,appStoreReviewDetail,build",
    "fields[appStoreReviewDetails]": "contactFirstName,contactLastName,contactPhone,contactEmail,demoAccountRequired,notes,appStoreVersion",
    "fields[builds]": "version,usesNonExemptEncryption,app",
    include: "appStoreReviewDetail,build",
    limit: "200",
  });
  const appStoreVersion = selectAppStoreVersion(versionCollection);
  if (relationshipOne(appStoreVersion, "app", "apps", "App Store version-to-App") !== app.id) {
    fail("ASC_RESPONSE_DRIFT", "App Store version points to a different App resource");
  }
  if (
    appStoreVersion.attributes.platform !== platform ||
    appStoreVersion.attributes.versionString !== record.version.versionString ||
    appStoreVersion.attributes.reviewType !== "APP_STORE"
  ) {
    fail("ASC_VERSION_MISMATCH", "App Store version does not match the requested platform, version, and review type");
  }
  if (!REVIEW_SELECTION_VERSION_STATES.has(appStoreVersion.attributes.appVersionState)) {
    fail("ASC_VERSION_STATE_UNSAFE", "App Store version is not in a pre-review-selection state");
  }
  const versionIncluded = indexIncluded(versionCollection.included);
  const versionLocalizationCollection = await client.getCollection(
    `/v1/appStoreVersions/${encodeURIComponent(appStoreVersion.id)}/appStoreVersionLocalizations`,
    {
      "fields[appStoreVersionLocalizations]": "description,keywords,locale,marketingUrl,promotionalText,supportUrl,whatsNew,appStoreVersion",
      limit: "200",
    },
  );
  const versionLocalizations = assertExactLocaleSet(sortAndRejectDuplicateLocales(
    collectionResources(versionLocalizationCollection, "appStoreVersionLocalizations",
      "App Store version localization").map((resource) => {
      if (relationshipOne(resource, "appStoreVersion", "appStoreVersions",
        "App Store version localization-to-version") !== appStoreVersion.id) {
        fail("ASC_RESPONSE_DRIFT", "App Store version localization points to a different version resource");
      }
      return normalizeLocalization(resource, "appStoreVersionLocalizations",
        ["description", "keywords", "marketingUrl", "promotionalText", "supportUrl", "whatsNew"],
        "App Store version localization");
    }),
    "App Store version localizations",
  ), "App Store version localizations");
  const reviewResource = linkedResource(appStoreVersion, "appStoreReviewDetail", "appStoreReviewDetails",
    versionIncluded, "App Store review detail");
  if (relationshipOne(reviewResource, "appStoreVersion", "appStoreVersions",
    "App Store review detail-to-version") !== appStoreVersion.id) {
    fail("ASC_RESPONSE_DRIFT", "App Store review detail points to a different version resource");
  }
  const buildResource = linkedResource(appStoreVersion, "build", "builds", versionIncluded,
    "App Store version Build");
  if (buildResource.id !== buildSnapshot.resourceIDs.build) {
    fail("ASC_RESPONSE_DRIFT", "App Store version selects a different Build than the sealed candidate");
  }
  if (relationshipOne(buildResource, "app", "apps", "Build-to-App") !== app.id) {
    fail("ASC_RESPONSE_DRIFT", "selected Build points to a different App resource");
  }
  if (
    buildResource.attributes.version !== record.version.buildNumber ||
    typeof buildResource.attributes.usesNonExemptEncryption !== "boolean"
  ) {
    fail("ASC_BUILD_MISMATCH", "selected Build number or encryption declaration is unresolved");
  }
  if (
    buildResource.attributes.version !== buildSnapshot.build.buildNumber ||
    buildResource.attributes.usesNonExemptEncryption !== buildSnapshot.build.usesNonExemptEncryption
  ) {
    fail("ASC_RESPONSE_DRIFT", "selected Build changed after the sealed Build snapshot");
  }

  let testFlight = null;
  const requests = [
    ...appCollection.requests,
    ...appInfoCollection.requests,
    ...appInfoLocalizationCollection.requests,
    ...versionCollection.requests,
    ...versionLocalizationCollection.requests,
  ];
  if (platform === "IOS") {
    let betaReview = null;
    let betaAppLocalizations = null;
    if (externalBeta) {
      betaReview = linkedResource(app, "betaAppReviewDetail", "betaAppReviewDetails", appIncluded,
        "Beta App review detail");
      if (relationshipOne(betaReview, "app", "apps", "Beta App review detail-to-App") !== app.id) {
        fail("ASC_RESPONSE_DRIFT", "Beta App review detail points to a different App resource");
      }
      const betaAppCollection = await client.getCollection(`/v1/apps/${encodeURIComponent(app.id)}/betaAppLocalizations`, {
        "fields[betaAppLocalizations]": "feedbackEmail,description,locale,marketingUrl,privacyPolicyUrl,tvOsPrivacyPolicy,app",
        limit: "200",
      });
      betaAppLocalizations = assertExactLocaleSet(sortAndRejectDuplicateLocales(collectionResources(
        betaAppCollection, "betaAppLocalizations", "Beta App localization").map((resource) => {
        const normalized = normalizeLocalization(resource, "betaAppLocalizations",
          ["feedbackEmail", "description", "marketingUrl", "privacyPolicyUrl", "tvOsPrivacyPolicy"],
          "Beta App localization");
        if (relationshipOne(resource, "app", "apps", "Beta App localization-to-App") !== app.id) {
          fail("ASC_RESPONSE_DRIFT", "Beta App localization points to a different App resource");
        }
        return normalized;
      }), "Beta App localizations"), "Beta App localizations");
      requests.push(...betaAppCollection.requests);
    }

    const betaBuildCollection = await client.getCollection(
      `/v1/builds/${encodeURIComponent(buildResource.id)}/betaBuildLocalizations`,
      {
        "fields[betaBuildLocalizations]": "locale,whatsNew,build",
        limit: "200",
      },
    );
    const betaBuildLocalizations = assertExactLocaleSet(sortAndRejectDuplicateLocales(collectionResources(
      betaBuildCollection, "betaBuildLocalizations", "Beta Build localization").map((resource) => {
      const normalized = normalizeLocalization(resource, "betaBuildLocalizations", ["whatsNew"],
        "Beta Build localization");
      if (relationshipOne(resource, "build", "builds", "Beta Build localization-to-Build") !== buildResource.id) {
        fail("ASC_RESPONSE_DRIFT", "Beta Build localization points to a different Build resource");
      }
      return normalized;
    }), "Beta Build localizations"), "Beta Build localizations");
    requests.push(...betaBuildCollection.requests);
    testFlight = {
      appLocalizations: betaAppLocalizations,
      buildLocalizations: betaBuildLocalizations,
      review: externalBeta
        ? normalizeReview(betaReview, "betaAppReviewDetails", "Beta App review detail", {
          contact: record.testFlight.betaReviewContact,
          notes: record.testFlight.betaReviewNotes,
        })
        : null,
    };
  }

  const resourceIDs = {
    app: app.id,
    appInfo: appInfo.id,
    appStoreVersion: appStoreVersion.id,
    build: buildResource.id,
  };
  if (!requestEvidenceIsValid(requests,
    submissionRequestSpecifications(normalizedManifest, resourceIDs))) {
    fail("ASC_RESPONSE_INVALID", "request evidence is incomplete or does not match the required GET set");
  }
  return {
    remote: {
      app: {
        resourceID: app.id,
        name: normalizeOptionalString(app.attributes.name, "App.name"),
        bundleID: normalizeOptionalString(app.attributes.bundleId, "App.bundleId"),
        sku: normalizeOptionalString(app.attributes.sku, "App.sku"),
        primaryLocale: normalizeOptionalString(app.attributes.primaryLocale, "App.primaryLocale"),
        contentRightsDeclaration: normalizeOptionalString(app.attributes.contentRightsDeclaration,
          "App.contentRightsDeclaration"),
        isOrEverWasMadeForKids: app.attributes.isOrEverWasMadeForKids ?? null,
      },
      appInfo: {
        resourceID: appInfo.id,
        appStoreState: appInfo.attributes.appStoreState ?? null,
        state: appInfo.attributes.state ?? null,
        primaryCategory: categorySlug(primaryCategory, platform),
        secondaryCategory: categorySlug(secondaryCategory, platform),
        localizations: appInfoLocalizations,
      },
      appStoreVersion: {
        resourceID: appStoreVersion.id,
        platform: appStoreVersion.attributes.platform ?? null,
        versionString: appStoreVersion.attributes.versionString ?? null,
        appStoreState: appStoreVersion.attributes.appStoreState ?? null,
        appVersionState: appStoreVersion.attributes.appVersionState ?? null,
        reviewType: appStoreVersion.attributes.reviewType ?? null,
        copyright: normalizeOptionalString(appStoreVersion.attributes.copyright,
          "AppStoreVersion.copyright"),
        releaseType: appStoreVersion.attributes.releaseType ?? null,
        earliestReleaseDate: normalizeTimestamp(appStoreVersion.attributes.earliestReleaseDate),
        localizations: versionLocalizations,
        review: normalizeReview(reviewResource, "appStoreReviewDetails", "App Store review detail", record.review),
      },
      build: {
        resourceID: buildResource.id,
        buildNumber: buildResource.attributes.version,
        usesNonExemptEncryption: buildResource.attributes.usesNonExemptEncryption,
      },
      testFlight,
    },
    requests,
  };
}

function expectedBuildSnapshotOptions({ bundleId, platform, version, build, artifactPath, identityLockPath, projectRoot, now, maxAgeSeconds }) {
  return {
    kind: "app-store-connect-build-snapshot",
    bundleId,
    platform,
    version,
    build,
    artifactPath,
    identityLockPath,
    projectRoot,
    now,
    ...(maxAgeSeconds === undefined ? {} : { maxAgeSeconds }),
  };
}

function readAndNormalizeManifest(manifestPath, platform, expected, projectRoot) {
  const requiredPath = join(projectRoot, ".release", "app-store-submission.json");
  if (manifestPath !== requiredPath) {
    fail("MANIFEST_PATH_INVALID", "submission metadata must bind repository .release/app-store-submission.json");
  }
  const observation = inspectFile(manifestPath, "submission manifest", { maxBytes: 1024 * 1024 });
  if ((observation.mode & 0o222) !== 0) {
    fail("MANIFEST_PERMISSIONS_INVALID", "submission manifest must be write-protected");
  }
  const manifest = parseStrictJSON(observation.bytes, "submission manifest");
  return { observation, normalized: normalizeManifest(manifest, platform, expected) };
}

export async function captureSubmissionMetadataSnapshot({
  client,
  manifestPath,
  buildSnapshotPath,
  bundleId,
  platform,
  version,
  build,
  artifactPath,
  identityLockPath,
  projectRoot = DEFAULT_PROJECT_ROOT,
  now = new Date(),
}) {
  if (!client || typeof client.getCollection !== "function") fail("INVALID_INPUT", "ASC client is invalid");
  const normalizedPlatform = normalizePlatform(platform);
  const canonicalProjectRoot = realpathSync(projectRoot);
  if (canonicalProjectRoot !== projectRoot || dirname(manifestPath) !== join(projectRoot, ".release")) {
    fail("UNSAFE_PATH", "project root and manifest path must be canonical");
  }
  const expected = { bundleId, version, build };
  const { observation: manifestObservation, normalized: normalizedManifest } =
    readAndNormalizeManifest(manifestPath, normalizedPlatform, expected, projectRoot);
  const buildSnapshotObservation = inspectFile(buildSnapshotPath, "Build snapshot");
  const verifiedBuildSnapshot = verifySnapshotFile(buildSnapshotPath,
    expectedBuildSnapshotOptions({
      bundleId, platform: normalizedPlatform, version, build, artifactPath, identityLockPath,
      projectRoot, now,
    }));
  const times = snapshotTimes(now);
  const buildCapturedAt = Date.parse(verifiedBuildSnapshot.capturedAt);
  const buildExpiresAt = Date.parse(verifiedBuildSnapshot.expiresAt);
  const metadataCapturedAt = Date.parse(times.capturedAt);
  if (
    !Number.isFinite(buildCapturedAt) ||
    !Number.isFinite(buildExpiresAt) ||
    metadataCapturedAt < buildCapturedAt ||
    metadataCapturedAt > buildExpiresAt
  ) {
    fail("SNAPSHOT_BINDING_MISMATCH", "metadata capture time is outside the Build snapshot validity window");
  }
  const { remote, requests } = await readRemoteMetadata(client, normalizedManifest, verifiedBuildSnapshot);
  const comparisons = buildComparison(normalizedManifest, remote, verifiedBuildSnapshot);
  const coverage = buildCoverage(comparisons, normalizedManifest.platformKey,
    normalizedManifest.record.testFlight?.distribution ?? null);
  const readiness = buildReadiness(comparisons, coverage, normalizedManifest.platformKey);

  assertFileUnchanged(manifestObservation, "submission manifest");
  assertFileUnchanged(buildSnapshotObservation, "Build snapshot");
  verifySnapshotFile(buildSnapshotPath, expectedBuildSnapshotOptions({
    bundleId, platform: normalizedPlatform, version, build, artifactPath, identityLockPath,
    projectRoot, now,
  }));

  return sealSnapshot({
    schemaVersion: SUBMISSION_METADATA_SCHEMA_VERSION,
    kind: SUBMISSION_METADATA_KIND,
    readOnly: true,
    appleAPIOrigin: ASC_ORIGIN,
    ...times,
    query: {
      bundleID: bundleId,
      platform: normalizedPlatform,
      version,
      build,
    },
    bindings: {
      manifestPath,
      manifestSHA256: manifestObservation.sha256,
      manifestByteLength: manifestObservation.byteLength,
      buildSnapshotPath,
      buildSnapshotSHA256: buildSnapshotObservation.sha256,
      buildSnapshotEvidenceSHA256: verifiedBuildSnapshot.evidenceSHA256,
    },
    resourceIDs: {
      app: remote.app.resourceID,
      appInfo: remote.appInfo.resourceID,
      appStoreVersion: remote.appStoreVersion.resourceID,
      build: remote.build.resourceID,
    },
    remote,
    comparisons,
    coverage,
    requestEvidence: requests,
    readiness,
  });
}

function verifyEnvelope(snapshot) {
  exactKeys(snapshot, [
    "schemaVersion", "kind", "readOnly", "appleAPIOrigin", "capturedAt", "expiresAt", "query",
    "bindings", "resourceIDs", "remote", "comparisons", "coverage", "requestEvidence", "readiness",
    "evidenceSHA256",
  ], "submission metadata snapshot");
  if (
    snapshot.schemaVersion !== SUBMISSION_METADATA_SCHEMA_VERSION ||
    snapshot.kind !== SUBMISSION_METADATA_KIND ||
    snapshot.readOnly !== true ||
    snapshot.appleAPIOrigin !== ASC_ORIGIN ||
    !SHA256_PATTERN.test(snapshot.evidenceSHA256 ?? "")
  ) {
    fail("SNAPSHOT_INVALID", "submission metadata snapshot envelope is invalid");
  }
  const unsealed = { ...snapshot };
  delete unsealed.evidenceSHA256;
  const expectedSeal = createHash("sha256").update(canonicalJSONString(unsealed), "utf8").digest("hex");
  if (expectedSeal !== snapshot.evidenceSHA256) fail("SNAPSHOT_TAMPERED", "snapshot evidence digest is invalid");
}

function primitiveOrNull(value, label) {
  if (value !== null && typeof value !== "string" && typeof value !== "boolean") {
    fail("SNAPSHOT_INVALID", `${label} must be a string, Boolean, or null`);
  }
}

function verifyStoredLocalization(value, fields, label) {
  exactKeys(value, ["resourceID", "locale", ...fields], label);
  if (!RESOURCE_ID_PATTERN.test(value.resourceID ?? "") || typeof value.locale !== "string") {
    fail("SNAPSHOT_INVALID", `${label} identity is invalid`);
  }
  fields.forEach((field) => primitiveOrNull(value[field], `${label}.${field}`));
}

function verifyStoredReview(value, label) {
  exactKeys(value, ["resourceID", "contactMatches", "demoAccountRequired", "notesMatch"], label);
  exactKeys(value.contactMatches, ["firstName", "lastName", "email", "phone"],
    `${label}.contactMatches`);
  if (!RESOURCE_ID_PATTERN.test(value.resourceID ?? "") ||
      (value.demoAccountRequired !== null && typeof value.demoAccountRequired !== "boolean") ||
      (value.notesMatch !== null && typeof value.notesMatch !== "boolean") ||
      Object.values(value.contactMatches).some((item) => typeof item !== "boolean")) {
    fail("SNAPSHOT_INVALID", `${label} identity or redacted match flags are invalid`);
  }
}

function verifyStoredRemote(remote, platform, testFlightDistribution = null) {
  exactKeys(remote, ["app", "appInfo", "appStoreVersion", "build", "testFlight"], "snapshot remote");
  exactKeys(remote.app, [
    "resourceID", "name", "bundleID", "sku", "primaryLocale", "contentRightsDeclaration",
    "isOrEverWasMadeForKids",
  ], "snapshot remote App");
  if (!RESOURCE_ID_PATTERN.test(remote.app.resourceID ?? "")) {
    fail("SNAPSHOT_INVALID", "snapshot remote App ID is invalid");
  }
  for (const field of ["name", "bundleID", "sku", "primaryLocale", "contentRightsDeclaration",
    "isOrEverWasMadeForKids"]) {
    primitiveOrNull(remote.app[field], `snapshot remote App.${field}`);
  }
  exactKeys(remote.appInfo, [
    "resourceID", "appStoreState", "state", "primaryCategory", "secondaryCategory", "localizations",
  ], "snapshot remote App Info");
  if (!RESOURCE_ID_PATTERN.test(remote.appInfo.resourceID ?? "") || !Array.isArray(remote.appInfo.localizations)) {
    fail("SNAPSHOT_INVALID", "snapshot remote App Info identity or localizations are invalid");
  }
  for (const field of ["appStoreState", "state", "primaryCategory", "secondaryCategory"]) {
    primitiveOrNull(remote.appInfo[field], `snapshot remote App Info.${field}`);
  }
  if (!STAGED_APP_INFO_STATES.has(remote.appInfo.state) && !LIVE_APP_INFO_STATES.has(remote.appInfo.state)) {
    fail("SNAPSHOT_INVALID", "snapshot remote App Info state is not a selectable staged-or-live state");
  }
  remote.appInfo.localizations.forEach((localization, index) => verifyStoredLocalization(localization,
    ["name", "subtitle", "privacyPolicyUrl", "privacyChoicesUrl", "privacyPolicyText"],
    `snapshot remote App Info localization ${index}`));
  assertExactLocaleSet(remote.appInfo.localizations, "snapshot remote App Info localizations", "SNAPSHOT_INVALID");

  exactKeys(remote.appStoreVersion, [
    "resourceID", "platform", "versionString", "appStoreState", "appVersionState", "copyright",
    "reviewType", "releaseType", "earliestReleaseDate", "localizations", "review",
  ], "snapshot remote App Store version");
  if (!RESOURCE_ID_PATTERN.test(remote.appStoreVersion.resourceID ?? "") ||
      !Array.isArray(remote.appStoreVersion.localizations)) {
    fail("SNAPSHOT_INVALID", "snapshot remote App Store version identity or localizations are invalid");
  }
  for (const field of ["platform", "versionString", "appStoreState", "appVersionState", "copyright",
    "releaseType", "earliestReleaseDate"]) {
    primitiveOrNull(remote.appStoreVersion[field], `snapshot remote App Store version.${field}`);
  }
  remote.appStoreVersion.localizations.forEach((localization, index) => verifyStoredLocalization(localization,
    ["description", "keywords", "marketingUrl", "promotionalText", "supportUrl", "whatsNew"],
    `snapshot remote App Store version localization ${index}`));
  assertExactLocaleSet(remote.appStoreVersion.localizations,
    "snapshot remote App Store version localizations", "SNAPSHOT_INVALID");
  if (
    remote.appStoreVersion.platform !== platform ||
    remote.appStoreVersion.reviewType !== "APP_STORE" ||
    !REVIEW_SELECTION_VERSION_STATES.has(remote.appStoreVersion.appVersionState)
  ) {
    fail("SNAPSHOT_INVALID", "snapshot remote App Store version is not eligible for review selection");
  }
  verifyStoredReview(remote.appStoreVersion.review, "snapshot remote App Store review detail");

  exactKeys(remote.build, ["resourceID", "buildNumber", "usesNonExemptEncryption"], "snapshot remote Build");
  if (!RESOURCE_ID_PATTERN.test(remote.build.resourceID ?? "") ||
      typeof remote.build.buildNumber !== "string" ||
      typeof remote.build.usesNonExemptEncryption !== "boolean") {
    fail("SNAPSHOT_INVALID", "snapshot remote Build is invalid");
  }

  if (platform === "MAC_OS") {
    if (remote.testFlight !== null) fail("SNAPSHOT_INVALID", "macOS remote metadata must not contain TestFlight data");
    return;
  }
  if (testFlightDistribution === "internal-only") {
    if (!isObject(remote.testFlight)) {
      fail("SNAPSHOT_INVALID", "internal-only TestFlight Build metadata is missing");
    }
    exactKeys(remote.testFlight, ["appLocalizations", "buildLocalizations", "review"],
      "snapshot remote internal TestFlight metadata");
    if (remote.testFlight.appLocalizations !== null || remote.testFlight.review !== null ||
        !Array.isArray(remote.testFlight.buildLocalizations)) {
      fail("SNAPSHOT_INVALID", "internal-only TestFlight must contain only Build localization metadata");
    }
    remote.testFlight.buildLocalizations.forEach((localization, index) => verifyStoredLocalization(localization,
      ["whatsNew"], `snapshot remote internal Beta Build localization ${index}`));
    assertExactLocaleSet(remote.testFlight.buildLocalizations,
      "snapshot remote internal Beta Build localizations", "SNAPSHOT_INVALID");
    return;
  }
  if (testFlightDistribution !== "external" || !isObject(remote.testFlight)) {
    fail("SNAPSHOT_INVALID", "external TestFlight metadata is missing or the distribution is unsupported");
  }
  exactKeys(remote.testFlight, ["appLocalizations", "buildLocalizations", "review"],
    "snapshot remote TestFlight metadata");
  if (!Array.isArray(remote.testFlight.appLocalizations) ||
      !Array.isArray(remote.testFlight.buildLocalizations)) {
    fail("SNAPSHOT_INVALID", "snapshot remote TestFlight localizations are invalid");
  }
  remote.testFlight.appLocalizations.forEach((localization, index) => verifyStoredLocalization(localization,
    ["feedbackEmail", "description", "marketingUrl", "privacyPolicyUrl", "tvOsPrivacyPolicy"],
    `snapshot remote Beta App localization ${index}`));
  remote.testFlight.buildLocalizations.forEach((localization, index) => verifyStoredLocalization(localization,
    ["whatsNew"], `snapshot remote Beta Build localization ${index}`));
  assertExactLocaleSet(remote.testFlight.appLocalizations,
    "snapshot remote Beta App localizations", "SNAPSHOT_INVALID");
  assertExactLocaleSet(remote.testFlight.buildLocalizations,
    "snapshot remote Beta Build localizations", "SNAPSHOT_INVALID");
  verifyStoredReview(remote.testFlight.review, "snapshot remote Beta App review detail");
  if (typeof remote.testFlight.review.notesMatch !== "boolean") {
    fail("SNAPSHOT_INVALID", "snapshot Beta App review notes match flag is missing");
  }
}

function verifyStoredDerivations(snapshot) {
  if (!Array.isArray(snapshot.comparisons) || snapshot.comparisons.length === 0) {
    fail("SNAPSHOT_INVALID", "snapshot comparisons are missing");
  }
  const paths = new Set();
  for (const [index, entry] of snapshot.comparisons.entries()) {
    exactKeys(entry, ["source", "path", "expected", "actual", "matches"],
      `snapshot comparison ${index}`);
    if (!["app-store-connect-api", "api-semantic-signal", "sealed-local-evidence"].includes(entry.source) ||
        typeof entry.path !== "string" || entry.path.length === 0 || paths.has(`${entry.source}:${entry.path}`) ||
        typeof entry.matches !== "boolean") {
      fail("SNAPSHOT_INVALID", `snapshot comparison ${index} is invalid or duplicated`);
    }
    primitiveOrNull(entry.expected, `snapshot comparison ${index}.expected`);
    primitiveOrNull(entry.actual, `snapshot comparison ${index}.actual`);
    paths.add(`${entry.source}:${entry.path}`);
  }
  exactKeys(snapshot.coverage, [
    "schemaVersion", "apiComparedPaths", "semanticSignalPaths", "separatelyAttestedPaths",
    "manualOrUnsupported", "intentionallyUncapturedSecrets", "allRequiredFieldsClassified",
    "allAPIComparisonsMatch", "allSeparateAttestationsMatch", "everyRequiredFieldVerified",
    "remoteMetadataComparisonComplete",
  ], "snapshot coverage");
  for (const field of ["apiComparedPaths", "semanticSignalPaths", "separatelyAttestedPaths",
    "intentionallyUncapturedSecrets"]) {
    if (!Array.isArray(snapshot.coverage[field]) ||
        snapshot.coverage[field].some((value) => typeof value !== "string")) {
      fail("SNAPSHOT_INVALID", `snapshot coverage.${field} is invalid`);
    }
  }
  if (!Array.isArray(snapshot.coverage.manualOrUnsupported)) {
    fail("SNAPSHOT_INVALID", "snapshot coverage.manualOrUnsupported is invalid");
  }
  snapshot.coverage.manualOrUnsupported.forEach((entry, index) => {
    exactKeys(entry, ["path", "reason"], `manual coverage entry ${index}`);
    if (typeof entry.path !== "string" || typeof entry.reason !== "string") {
      fail("SNAPSHOT_INVALID", `manual coverage entry ${index} is invalid`);
    }
  });
  exactKeys(snapshot.readiness, [
    "manifestStrictStructureBound", "authoritativeManifestReleaseValidationBound", "buildSnapshotVerified",
    "exactRemoteResourcesBound", "appIdentityMatches", "versionAndSelectedBuildMatch",
    "apiComparableMetadataMatches", "semanticSignalsConsistent", "localAttestationsMatch",
    "apiVisibleMetadataEvidenceReady", "manualComplianceEvidenceComplete",
    "submissionManifestFullyVerified", "remoteMetadataComparisonComplete",
  ], "snapshot readiness");
  if (Object.values(snapshot.readiness).some((value) => typeof value !== "boolean")) {
    fail("SNAPSHOT_INVALID", "snapshot readiness values must be Boolean");
  }
}

export function verifySubmissionMetadataSnapshotFile(snapshotPath, {
  manifestPath,
  buildSnapshotPath,
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
  if (!Number.isSafeInteger(maxAgeSeconds) || maxAgeSeconds < 1 || maxAgeSeconds > SNAPSHOT_MAX_AGE_SECONDS) {
    fail("INVALID_INPUT", `maximum snapshot age must be between 1 and ${SNAPSHOT_MAX_AGE_SECONDS} seconds`);
  }
  const normalizedPlatform = normalizePlatform(platform);
  const snapshotObservation = inspectFile(snapshotPath, "submission metadata snapshot");
  if (snapshotObservation.mode !== 0o444) {
    fail("SNAPSHOT_PERMISSIONS_INVALID", "submission metadata snapshot must have mode 0444");
  }
  const snapshot = parseStrictJSON(snapshotObservation.bytes, "submission metadata snapshot", "SNAPSHOT_INVALID");
  verifyEnvelope(snapshot);
  const nowDate = now instanceof Date ? now : new Date(now);
  const capturedAt = Date.parse(snapshot.capturedAt);
  const expiresAt = Date.parse(snapshot.expiresAt);
  if (!Number.isFinite(nowDate.getTime()) || !Number.isFinite(capturedAt) || !Number.isFinite(expiresAt)) {
    fail("SNAPSHOT_INVALID", "snapshot timestamps are invalid");
  }
  if (expiresAt - capturedAt !== SNAPSHOT_MAX_AGE_SECONDS * 1000) {
    fail("SNAPSHOT_INVALID", "snapshot expiry window is invalid");
  }
  if (capturedAt > nowDate.getTime() + 60_000) fail("SNAPSHOT_NOT_YET_VALID", "snapshot capture is in the future");
  if (nowDate.getTime() > expiresAt || nowDate.getTime() - capturedAt > maxAgeSeconds * 1000) {
    fail("SNAPSHOT_EXPIRED", "submission metadata snapshot is stale");
  }

  exactKeys(snapshot.query, ["bundleID", "platform", "version", "build"], "snapshot query");
  if (
    snapshot.query.bundleID !== bundleId ||
    snapshot.query.platform !== normalizedPlatform ||
    snapshot.query.version !== version ||
    snapshot.query.build !== build
  ) {
    fail("SNAPSHOT_BINDING_MISMATCH", "snapshot query does not match the expected candidate");
  }
  exactKeys(snapshot.bindings, [
    "manifestPath", "manifestSHA256", "manifestByteLength", "buildSnapshotPath", "buildSnapshotSHA256",
    "buildSnapshotEvidenceSHA256",
  ], "snapshot bindings");
  if (snapshot.bindings.manifestPath !== manifestPath || snapshot.bindings.buildSnapshotPath !== buildSnapshotPath) {
    fail("SNAPSHOT_BINDING_MISMATCH", "snapshot binds different manifest or Build snapshot paths");
  }
  const { observation: manifestObservation, normalized: normalizedManifest } = readAndNormalizeManifest(
    manifestPath, normalizedPlatform, { bundleId, version, build }, projectRoot,
  );
  const buildSnapshotObservation = inspectFile(buildSnapshotPath, "Build snapshot");
  const verifiedBuildSnapshot = verifySnapshotFile(buildSnapshotPath, expectedBuildSnapshotOptions({
    bundleId, platform: normalizedPlatform, version, build, artifactPath, identityLockPath,
    projectRoot, now: nowDate, maxAgeSeconds,
  }));
  const buildCapturedAt = Date.parse(verifiedBuildSnapshot.capturedAt);
  const buildExpiresAt = Date.parse(verifiedBuildSnapshot.expiresAt);
  if (
    !Number.isFinite(buildCapturedAt) ||
    !Number.isFinite(buildExpiresAt) ||
    capturedAt < buildCapturedAt ||
    capturedAt > buildExpiresAt
  ) {
    fail("SNAPSHOT_BINDING_MISMATCH", "metadata snapshot capture time is outside the Build snapshot validity window");
  }
  if (
    snapshot.bindings.manifestSHA256 !== manifestObservation.sha256 ||
    snapshot.bindings.manifestByteLength !== manifestObservation.byteLength ||
    snapshot.bindings.buildSnapshotSHA256 !== buildSnapshotObservation.sha256 ||
    snapshot.bindings.buildSnapshotEvidenceSHA256 !== verifiedBuildSnapshot.evidenceSHA256
  ) {
    fail("SNAPSHOT_BINDING_MISMATCH", "snapshot binding hashes no longer match current evidence files");
  }
  if (!isObject(snapshot.remote) || !isObject(snapshot.remote.app) || !isObject(snapshot.remote.appInfo)
      || !isObject(snapshot.remote.appStoreVersion) || !isObject(snapshot.remote.build)) {
    fail("SNAPSHOT_INVALID", "snapshot remote metadata is incomplete");
  }
  exactKeys(snapshot.resourceIDs, ["app", "appInfo", "appStoreVersion", "build"],
    "snapshot resource IDs");
  verifyStoredRemote(snapshot.remote, normalizedPlatform,
    normalizedManifest.record.testFlight?.distribution ?? null);
  verifyStoredDerivations(snapshot);
  if (
    snapshot.resourceIDs?.app !== snapshot.remote.app.resourceID ||
    snapshot.resourceIDs?.appInfo !== snapshot.remote.appInfo.resourceID ||
    snapshot.resourceIDs?.appStoreVersion !== snapshot.remote.appStoreVersion.resourceID ||
    snapshot.resourceIDs?.build !== snapshot.remote.build.resourceID ||
    snapshot.remote.app.resourceID !== verifiedBuildSnapshot.resourceIDs.app ||
    snapshot.remote.build.resourceID !== verifiedBuildSnapshot.resourceIDs.build ||
    snapshot.remote.appStoreVersion.versionString !== version ||
    snapshot.remote.appStoreVersion.platform !== normalizedPlatform ||
    snapshot.remote.appStoreVersion.reviewType !== "APP_STORE" ||
    snapshot.remote.build.buildNumber !== build ||
    typeof snapshot.remote.build.usesNonExemptEncryption !== "boolean"
  ) {
    fail("SNAPSHOT_BINDING_MISMATCH", "snapshot remote resource IDs or Build identity are inconsistent");
  }
  if (normalizedPlatform === "IOS" && normalizedManifest.record.testFlight.distribution === "external" &&
      !isObject(snapshot.remote.testFlight)) {
    fail("SNAPSHOT_INVALID", "external iOS snapshot is missing TestFlight metadata");
  }
  if (normalizedPlatform === "IOS" && normalizedManifest.record.testFlight.distribution === "internal-only" &&
      !isObject(snapshot.remote.testFlight)) {
    fail("SNAPSHOT_INVALID", "internal-only iOS snapshot is missing TestFlight Build metadata");
  }
  if (normalizedPlatform === "MAC_OS" && snapshot.remote.testFlight !== null) {
    fail("SNAPSHOT_INVALID", "macOS snapshot must not contain TestFlight metadata");
  }
  if (!requestEvidenceIsValid(snapshot.requestEvidence,
    submissionRequestSpecifications(normalizedManifest, snapshot.resourceIDs))) {
    fail("SNAPSHOT_INVALID", "snapshot request evidence is invalid");
  }
  const comparisons = buildComparison(normalizedManifest, snapshot.remote, verifiedBuildSnapshot);
  const coverage = buildCoverage(comparisons, normalizedManifest.platformKey,
    normalizedManifest.record.testFlight?.distribution ?? null);
  const readiness = buildReadiness(comparisons, coverage, normalizedManifest.platformKey);
  if (
    canonicalJSONString(snapshot.comparisons) !== canonicalJSONString(comparisons) ||
    canonicalJSONString(snapshot.coverage) !== canonicalJSONString(coverage) ||
    canonicalJSONString(snapshot.readiness) !== canonicalJSONString(readiness) ||
    snapshot.coverage.remoteMetadataComparisonComplete !== false ||
    snapshot.coverage.everyRequiredFieldVerified !== false ||
    snapshot.readiness.remoteMetadataComparisonComplete !== false
  ) {
    fail("SNAPSHOT_INVALID", "snapshot comparison, coverage, or readiness derivation is inconsistent");
  }
  assertFileUnchanged(manifestObservation, "submission manifest");
  assertFileUnchanged(buildSnapshotObservation, "Build snapshot");
  const finalSnapshot = assertFileUnchanged(snapshotObservation, "submission metadata snapshot");
  return {
    schemaVersion: SUBMISSION_METADATA_SCHEMA_VERSION,
    kind: SUBMISSION_METADATA_KIND,
    verified: true,
    verifiedAt: nowDate.toISOString(),
    snapshotPath,
    snapshotSHA256: finalSnapshot.sha256,
    evidenceSHA256: snapshot.evidenceSHA256,
    capturedAt: snapshot.capturedAt,
    expiresAt: snapshot.expiresAt,
    query: snapshot.query,
    bindings: snapshot.bindings,
    resourceIDs: snapshot.resourceIDs,
    comparisons: snapshot.comparisons,
    coverage: snapshot.coverage,
    readiness: snapshot.readiness,
  };
}
