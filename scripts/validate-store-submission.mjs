#!/usr/bin/env node

import { execFileSync, spawnSync } from "node:child_process";
import {
  existsSync,
  lstatSync,
  readFileSync,
  readdirSync,
  realpathSync,
} from "node:fs";
import {
  dirname,
  extname,
  isAbsolute,
  join,
  normalize,
  relative,
  resolve,
  sep,
} from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const canonicalProjectRoot = realpathSync(projectRoot);
const args = new Set(process.argv.slice(2));
const knownArgs = new Set(["--release"]);
for (const argument of args) {
  if (!knownArgs.has(argument)) {
    console.error(`Unknown option: ${argument}`);
    process.exit(2);
  }
}

const releaseMode = args.has("--release");
const structuralErrors = [];
const releaseBlockers = [];
const storePlatforms = ["macOS", "iOS"];
const platformStructuralErrors = {
  macOS: [],
  iOS: [],
};
const platformReleaseBlockers = {
  macOS: [],
  iOS: [],
};

function addIssue(allIssues, platformIssues, message, platforms = storePlatforms) {
  allIssues.push(message);
  for (const platform of platforms) {
    platformIssues[platform].push(message);
  }
}

function addStructuralError(message, platforms = storePlatforms) {
  addIssue(structuralErrors, platformStructuralErrors, message, platforms);
}

function addReleaseBlocker(message, platforms = storePlatforms) {
  addIssue(releaseBlockers, platformReleaseBlockers, message, platforms);
}

const metadataDocuments = [
  {
    platform: "macOS",
    path: join(projectRoot, "docs/release/APP_STORE_METADATA.md"),
    locales: [
      {
        locale: "zh-Hans",
        section: "## 简体中文（zh-Hans）",
        headings: {
          name: /^### 名称/,
          subtitle: /^### 副标题/,
          promotionalText: /^### 推广文本/,
          description: /^### 描述/,
          keywords: /^### 关键词/,
        },
      },
      {
        locale: "en-US",
        section: "## English (U.S.)",
        headings: {
          name: /^### Name/,
          subtitle: /^### Subtitle/,
          promotionalText: /^### Promotional text/i,
          description: /^### Description/,
          keywords: /^### Keywords/,
        },
      },
    ],
  },
  {
    platform: "iOS",
    path: join(projectRoot, "docs/release/IOS_APP_STORE_AND_TESTFLIGHT_METADATA.md"),
    locales: [
      {
        locale: "zh-Hans",
        section: "## 2. 简体中文（zh-Hans）",
        headings: {
          name: /^### 名称/,
          subtitle: /^### 副标题/,
          promotionalText: /^### 推广文本/,
          description: /^### 描述/,
          keywords: /^### 关键词/,
        },
      },
      {
        locale: "en-US",
        section: "## 3. English (U.S.)",
        headings: {
          name: /^### Name/,
          subtitle: /^### Subtitle/,
          promotionalText: /^### Promotional text/i,
          description: /^### Description/,
          keywords: /^### Keywords/,
        },
      },
    ],
  },
];

function characterCount(value) {
  return Array.from(value).length;
}

function containsUnsupportedStoreMarkup(value) {
  return /`|\*\*|__|\[[^\]\n]+\]\([^)]+\)/.test(value);
}

function sectionLines(markdown, heading) {
  const lines = markdown.split(/\r?\n/);
  const start = lines.findIndex((line) => line.trim() === heading);
  if (start < 0) return null;
  let end = lines.length;
  for (let index = start + 1; index < lines.length; index += 1) {
    if (/^##\s+/.test(lines[index])) {
      end = index;
      break;
    }
  }
  return lines.slice(start + 1, end);
}

function fieldValue(lines, headingPattern, multiline) {
  const start = lines.findIndex((line) => headingPattern.test(line));
  if (start < 0) return null;
  let end = lines.length;
  for (let index = start + 1; index < lines.length; index += 1) {
    if (/^###\s+/.test(lines[index])) {
      end = index;
      break;
    }
  }
  const content = lines
    .slice(start + 1, end)
    .filter((line) => !/^\s*>/.test(line))
    .join("\n")
    .trim();
  if (multiline) {
    return content
      .replace(/^\s*[•*-]\s*/gm, "")
      .replace(/\n{3,}/g, "\n\n")
      .trim();
  }
  return content.split(/\r?\n/).find((line) => line.trim())?.trim() ?? "";
}

function validateMetadataLocale(document, localeConfig, markdown) {
  const lines = sectionLines(markdown, localeConfig.section);
  const key = `${document.platform}/${localeConfig.locale}`;
  if (!lines) {
    addStructuralError(`${key}: missing locale section ${localeConfig.section}`, [document.platform]);
    return { platform: document.platform, locale: localeConfig.locale, fields: null };
  }

  const fields = {};
  for (const [field, pattern] of Object.entries(localeConfig.headings)) {
    const value = fieldValue(lines, pattern, field === "description");
    if (value === null || value === "") {
      addStructuralError(`${key}: missing ${field}`, [document.platform]);
    }
    fields[field] = value ?? "";
  }

  const limits = {
    name: { minimum: 2, maximum: 30, unit: "characters" },
    subtitle: { maximum: 30, unit: "characters" },
    promotionalText: { maximum: 170, unit: "characters" },
    description: { maximum: 4000, unit: "characters" },
    keywords: { maximum: 100, unit: "bytes" },
  };
  const measurements = {};
  for (const [field, limit] of Object.entries(limits)) {
    const value = fields[field];
    const measured = limit.unit === "bytes" ? Buffer.byteLength(value, "utf8") : characterCount(value);
    measurements[field] = { value, measured, ...limit };
    if (limit.minimum !== undefined && measured < limit.minimum) {
      addStructuralError(
        `${key}: ${field} is shorter than ${limit.minimum} ${limit.unit}`,
        [document.platform],
      );
    }
    if (measured > limit.maximum) {
      addStructuralError(
        `${key}: ${field} is ${measured} ${limit.unit}; maximum is ${limit.maximum}`,
        [document.platform],
      );
    }
  }

  const keywords = fields.keywords.split(",").map((item) => item.trim()).filter(Boolean);
  if (keywords.length === 0 || keywords.some((item) => characterCount(item) <= 2)) {
    addStructuralError(
      `${key}: every comma-separated keyword must contain more than two characters`,
      [document.platform],
    );
  }
  if (/\[[^\]]+\]/.test(Object.values(fields).join("\n"))) {
    addReleaseBlocker(`${key}: extracted store metadata still contains a placeholder`, [document.platform]);
  }
  for (const [field, value] of Object.entries(fields)) {
    if (containsUnsupportedStoreMarkup(value)) {
      addStructuralError(
        `${key}: ${field} contains Markdown that App Store Connect renders as plain text`,
        [document.platform],
      );
    }
  }
  if (/^(agent island|tasklume)$/i.test(fields.name.trim())) {
    addReleaseBlocker(
      `${key}: ${JSON.stringify(fields.name)} is a known conflicted release name`,
      [document.platform],
    );
  }

  return {
    platform: document.platform,
    locale: localeConfig.locale,
    measurements,
  };
}

const metadata = [];
for (const document of metadataDocuments) {
  if (!existsSync(document.path)) {
    addStructuralError(`missing metadata document: ${document.path}`, [document.platform]);
    continue;
  }
  const markdown = readFileSync(document.path, "utf8");
  for (const locale of document.locales) {
    metadata.push(validateMetadataLocale(document, locale, markdown));
  }
}

// These files contain the operator-, account-, and build-specific values that
// App Store Connect and App Review need. Draft validation deliberately allows
// placeholders so the repository stays reusable, but release validation must
// never become green merely because screenshots and marketing copy are ready.
const submissionDocumentConfigs = [
  { relativePath: "docs/release/APP_STORE_METADATA.md", platforms: ["macOS"] },
  { relativePath: "docs/release/IOS_APP_STORE_AND_TESTFLIGHT_METADATA.md", platforms: ["iOS"] },
  { relativePath: "docs/release/APP_REVIEW_NOTES.md", platforms: ["macOS"] },
  { relativePath: "docs/release/IOS_APP_REVIEW_NOTES.md", platforms: ["iOS"] },
  { relativePath: "docs/release/PRIVACY_POLICY_ZH.md", platforms: storePlatforms },
  { relativePath: "docs/release/PRIVACY_POLICY_EN.md", platforms: storePlatforms },
  { relativePath: "docs/release/APP_PRIVACY_SUBMISSION_WORKSHEET.md", platforms: storePlatforms },
];

function unresolvedBracketPlaceholders(markdown) {
  const placeholders = [];
  // Ignore inline links, reference links/definitions, and task-list boxes.
  // Submission placeholders remain deliberately explicit as bare [value].
  const matcher = /(?<!\])\[([^\]\n]+)\](?!\s*(?:\(|\[|:))/g;
  for (const match of markdown.matchAll(matcher)) {
    const value = match[1].trim();
    if (!value || value.toLowerCase() === "x") continue;
    placeholders.push(`[${value}]`);
  }
  for (const match of markdown.matchAll(/<((?:正式|待填|YOUR)[^>\n]*)>/g)) {
    placeholders.push(`<${match[1].trim()}>`);
  }
  return [...new Set(placeholders)];
}

function releaseDraftSentinels(markdown) {
  const sentinels = [];
  const expression = /(?:草案|不可提交|\bdraft\b|owner-only|当前预览)/iu;
  for (const [index, line] of markdown.split(/\r?\n/).entries()) {
    const match = line.match(expression);
    if (match) {
      sentinels.push({ line: index + 1, value: match[0] });
    }
  }
  return sentinels;
}

const placeholderParserRegression = unresolvedBracketPlaceholders([
  '[Apple](https://developer.apple.com)',
  '[privacy][policy]',
  '[policy]: https://example.invalid',
  '- [ ] unfinished task',
  '- [x] finished task',
  '[支持邮箱]',
].join('\n'));
if (JSON.stringify(placeholderParserRegression) !== JSON.stringify(['[支持邮箱]'])) {
  addStructuralError('submission placeholder parser regression failed');
}
const sentinelParserRegression = releaseDraftSentinels([
  '# Final document',
  'This submission draft must not ship.',
  '当前状态：不可提交。',
].join('\n'));
if (sentinelParserRegression.length !== 2
    || sentinelParserRegression[0].line !== 2
    || sentinelParserRegression[1].line !== 3) {
  addStructuralError('submission draft-sentinel parser regression failed');
}
const storeMarkupParserRegression = [
  containsUnsupportedStoreMarkup('cloud `latest` snapshot'),
  containsUnsupportedStoreMarkup('**Local first**'),
  containsUnsupportedStoreMarkup('[Privacy](https://example.invalid)'),
  !containsUnsupportedStoreMarkup('cloud "latest" snapshot'),
].every(Boolean);
if (!storeMarkupParserRegression) {
  addStructuralError('store plain-text markup parser regression failed');
}

const submissionDocuments = submissionDocumentConfigs.map(({ relativePath, platforms }) => {
  const path = join(projectRoot, relativePath);
  if (!existsSync(path)) {
    addStructuralError(`missing submission document: ${path}`, platforms);
    return {
      path,
      platforms,
      heading: "",
      unresolvedPlaceholders: [],
      draftHeading: false,
      releaseDraftSentinels: [],
    };
  }
  const markdown = readFileSync(path, "utf8");
  const heading = markdown.split(/\r?\n/).find((line) => /^#\s+/.test(line))?.trim() ?? "";
  const unresolvedPlaceholders = unresolvedBracketPlaceholders(markdown);
  const draftHeading = /(?:草案|\bdraft\b)/i.test(heading);
  const draftSentinels = releaseDraftSentinels(markdown);
  for (const placeholder of unresolvedPlaceholders) {
    addReleaseBlocker(`${relativePath}: unresolved placeholder ${placeholder}`, platforms);
  }
  for (const sentinel of draftSentinels) {
    addReleaseBlocker(
      `${relativePath}:${sentinel.line}: release document still contains ${JSON.stringify(sentinel.value)}`,
      platforms,
    );
  }
  return {
    path,
    platforms,
    heading,
    unresolvedPlaceholders,
    draftHeading,
    releaseDraftSentinels: draftSentinels,
  };
});

function inspectAppPrivacyReleaseGate() {
  const validatorPath = join(projectRoot, "scripts/validate-app-privacy.mjs");
  if (!existsSync(validatorPath)) {
    addStructuralError(`missing App Privacy validator: ${validatorPath}`);
    return null;
  }
  const child = spawnSync(process.execPath, [validatorPath], {
    cwd: projectRoot,
    encoding: "utf8",
    env: process.env,
    maxBuffer: 10 * 1024 * 1024,
  });
  let validation;
  try {
    validation = JSON.parse(child.stdout);
  } catch (error) {
    addStructuralError(`App Privacy validator did not return JSON: ${error.message}`);
    return null;
  }
  if (child.status !== 0 || validation.draftValid !== true) {
    addStructuralError("App Privacy source validation failed");
    for (const error of validation.structuralErrors ?? []) {
      addStructuralError(`App Privacy: ${error}`);
    }
  }
  if (validation.releaseReady !== true) {
    const blockers = validation.releaseBlockers ?? [];
    if (blockers.length === 0) {
      addReleaseBlocker("App Privacy release evidence is not ready");
    } else {
      for (const blocker of blockers) {
        addReleaseBlocker(`App Privacy: ${blocker}`);
      }
    }
  }
  return {
    draftValid: validation.draftValid === true,
    sourcePrivacyReady: validation.sourcePrivacyReady === true,
    releaseEvidenceReady: validation.releaseEvidenceReady === true,
    releaseReady: validation.releaseReady === true,
    releaseEvidencePath: validation.releaseEvidencePath ?? null,
    releaseEvidence: validation.releaseEvidence ?? null,
  };
}

const appPrivacy = inspectAppPrivacyReleaseGate();

// Apple requires the Support URL to lead to actual contact information. An
// issue tracker is useful, but it does not replace a reachable email, an
// international telephone number, or a legal contact address when required.
const supportSitePath = join(projectRoot, "docs/site/support/index.html");
let supportContact = {
  path: supportSitePath,
  emailLinks: [],
  telephoneLinks: [],
  addressBlocks: 0,
  configured: false,
};
if (!existsSync(supportSitePath)) {
  addStructuralError(`missing public support page: ${supportSitePath}`);
} else {
  const supportHTML = readFileSync(supportSitePath, "utf8");
  const emailLinks = [...supportHTML.matchAll(/href=["']mailto:([^"']+)["']/gi)]
    .map((match) => match[1].trim())
    .filter((value) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)
      && !/(?:example|placeholder|\.invalid$|\.test$)/i.test(value));
  const telephoneLinks = [...supportHTML.matchAll(/href=["']tel:(\+[0-9][0-9 -]{6,})["']/gi)]
    .map((match) => match[1].trim());
  const addressBlocks = [...supportHTML.matchAll(/<address\b[^>]*>([\s\S]*?)<\/address>/gi)]
    .map((match) => match[1].replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim())
    .filter((value) => value.length >= 12 && !/(?:placeholder|\[[^\]]+\])/i.test(value));
  supportContact = {
    path: supportSitePath,
    emailLinks,
    telephoneLinks,
    addressBlocks: addressBlocks.length,
    configured: emailLinks.length > 0 || telephoneLinks.length > 0 || addressBlocks.length > 0,
  };
  if (!supportContact.configured) {
    addReleaseBlocker(
      "public Support URL has no actual email, international telephone number, or legal contact address",
    );
  }
}

const allowedScreenshotDimensions = {
  macos: new Set(["1280x800", "1440x900", "2560x1600", "2880x1800"]),
  ios: new Set([
    "1260x2736", "2736x1260",
    "1290x2796", "2796x1290",
    "1320x2868", "2868x1320",
  ]),
};

function imageProperties(path) {
  try {
    const output = execFileSync(
      "/usr/bin/sips",
      ["-g", "format", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", path],
      { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
    );
    const format = (output.match(/format:\s*([^\s]+)/)?.[1] ?? "").toLowerCase();
    const width = Number(output.match(/pixelWidth:\s*(\d+)/)?.[1] ?? 0);
    const height = Number(output.match(/pixelHeight:\s*(\d+)/)?.[1] ?? 0);
    const hasAlpha = (output.match(/hasAlpha:\s*(\w+)/)?.[1] ?? "unknown") === "yes";
    return { format, width, height, hasAlpha, readable: format !== "" && width > 0 && height > 0 };
  } catch {
    return { format: "", width: 0, height: 0, hasAlpha: false, readable: false };
  }
}

function pathInside(root, target) {
  const value = relative(root, target);
  return value === "" || (!value.startsWith(`..${sep}`) && value !== ".." && !isAbsolute(value));
}

function inspectProjectPath(absolutePath, expectedKind = "file") {
  const lexicalPath = resolve(absolutePath);
  if (!pathInside(projectRoot, lexicalPath)) {
    return { valid: false, reason: "must stay inside the repository" };
  }
  if (!existsSync(lexicalPath)) {
    try {
      // `existsSync` is false for a dangling symbolic link. `lstatSync` lets us
      // report it as an unsafe link rather than silently treating it as absent.
      if (lstatSync(lexicalPath).isSymbolicLink()) {
        return { valid: false, reason: "must not contain a symbolic-link component" };
      }
    } catch {
      // The path simply does not exist.
    }
    return { valid: false, reason: "does not exist" };
  }

  const projectRelative = relative(projectRoot, lexicalPath);
  let componentPath = projectRoot;
  for (const component of projectRelative.split(sep).filter(Boolean)) {
    componentPath = join(componentPath, component);
    let componentStat;
    try {
      componentStat = lstatSync(componentPath);
    } catch {
      return { valid: false, reason: "does not exist" };
    }
    if (componentStat.isSymbolicLink()) {
      return { valid: false, reason: "must not contain a symbolic-link component" };
    }
  }

  let canonicalPath;
  try {
    canonicalPath = realpathSync(lexicalPath);
  } catch {
    return { valid: false, reason: "could not be resolved" };
  }
  if (!pathInside(canonicalProjectRoot, canonicalPath)) {
    return { valid: false, reason: "real location must stay inside the repository" };
  }
  const stat = lstatSync(canonicalPath);
  if (expectedKind === "file" && !stat.isFile()) {
    return { valid: false, reason: "must be a regular file" };
  }
  if (expectedKind === "directory" && !stat.isDirectory()) {
    return { valid: false, reason: "must be a directory" };
  }
  return { valid: true, path: canonicalPath, stat };
}

function imageFormatMatchesExtension(path, format) {
  const extension = extname(path).toLowerCase();
  if (extension === ".png") return format === "png";
  if (extension === ".jpg" || extension === ".jpeg") return format === "jpeg";
  if (extension === ".icns") return format === "icns";
  return false;
}

function imageFiles(directory, label, platforms, required) {
  const directoryInspection = inspectProjectPath(directory, "directory");
  if (!directoryInspection.valid) {
    if (directoryInspection.reason !== "does not exist") {
      const message = `${label}: screenshot directory ${directoryInspection.reason}`;
      if (required) addReleaseBlocker(message, platforms);
      else addStructuralError(message, platforms);
    }
    return [];
  }
  return readdirSync(directory, { withFileTypes: true })
    .filter((entry) => [".png", ".jpg", ".jpeg"].includes(extname(entry.name).toLowerCase()))
    .map((entry) => entry.name)
    .sort()
    .map((name) => join(directory, name));
}

function inspectScreenshots(platform, locale, directory, required) {
  const storePlatform = platform === "macos" ? "macOS" : "iOS";
  const label = `${platform}/${locale}`;
  const files = imageFiles(directory, label, [storePlatform], required);
  const images = files.map((path) => {
    const pathInspection = inspectProjectPath(path, "file");
    const properties = imageProperties(path);
    const dimensions = `${properties.width}x${properties.height}`;
    const acceptedDimensions = allowedScreenshotDimensions[platform].has(dimensions);
    const formatMatchesExtension = imageFormatMatchesExtension(path, properties.format);
    const valid = pathInspection.valid
      && properties.readable
      && formatMatchesExtension
      && acceptedDimensions
      && !properties.hasAlpha;
    if (required && !valid) {
      const reasons = [];
      if (!pathInspection.valid) reasons.push(pathInspection.reason);
      if (!properties.readable) reasons.push("must be a readable image");
      if (properties.readable && !formatMatchesExtension) {
        reasons.push(`actual ${properties.format || "unknown"} format must match the filename extension`);
      }
      if (properties.readable && !acceptedDimensions) reasons.push("must use an accepted size");
      if (properties.hasAlpha) reasons.push("must have no alpha channel");
      addReleaseBlocker(
        `${label}: ${path} ${reasons.join(", ")}`,
        [storePlatform],
      );
    }
    return {
      path,
      format: properties.format,
      dimensions,
      hasAlpha: properties.hasAlpha,
      pathSafe: pathInspection.valid,
      formatMatchesExtension,
      acceptedDimensions,
      valid,
    };
  });
  if (required && (files.length < 1 || files.length > 10)) {
    addReleaseBlocker(
      `${platform}/${locale}: expected 1-10 final screenshots, found ${files.length}`,
      [storePlatform],
    );
  }
  return { platform, locale, directory, count: files.length, images };
}

const finalScreenshotRoot = join(projectRoot, "docs/release-assets");
const finalScreenshots = [];
for (const platform of ["macos", "ios"]) {
  for (const locale of ["zh-Hans", "en-US"]) {
    finalScreenshots.push(inspectScreenshots(platform, locale, join(finalScreenshotRoot, platform, locale), true));
  }
}

// Public demo images are tracked so a clean clone exercises this draft check.
// Local QA captures remain intentionally ignored under docs/screenshots/.
const referenceDirectory = join(projectRoot, "docs/media");
const referenceScreenshots = imageFiles(referenceDirectory, "docs/media", storePlatforms, false).map((path) => {
  const pathInspection = inspectProjectPath(path, "file");
  const properties = imageProperties(path);
  const dimensions = `${properties.width}x${properties.height}`;
  return {
    path,
    format: properties.format,
    dimensions,
    hasAlpha: properties.hasAlpha,
    storeEligibleAsMacScreenshot: pathInspection.valid
      && imageFormatMatchesExtension(path, properties.format)
      && allowedScreenshotDimensions.macos.has(dimensions)
      && !properties.hasAlpha,
  };
});

const sha256Pattern = /^[0-9a-f]{64}$/;

function fileSHA256(path) {
  const result = spawnSync("/usr/bin/shasum", ["-a", "256", path], {
    encoding: "utf8",
    env: { ...process.env, LC_ALL: "C", LANG: "C" },
  });
  const digest = result.status === 0 ? result.stdout.trim().split(/\s+/)[0] : "";
  return sha256Pattern.test(digest) ? digest : null;
}

function repositoryRelativePath(value, label, blockers, expectedPrefix = null) {
  if (typeof value !== "string"
      || value.trim() === ""
      || value !== value.trim()
      || value.includes("\\")
      || isAbsolute(value)
      || normalize(value) !== value
      || value === ".") {
    blockers.push(`${label}.path must be a normalized repository-relative path`);
    return null;
  }
  if (expectedPrefix && value !== expectedPrefix && !value.startsWith(`${expectedPrefix}/`)) {
    blockers.push(`${label}.path must stay under ${expectedPrefix}/`);
    return null;
  }
  const absolutePath = resolve(projectRoot, value);
  const inspection = inspectProjectPath(absolutePath, "file");
  if (!inspection.valid) {
    blockers.push(`${label}.path ${inspection.reason}: ${value}`);
    return null;
  }
  return inspection.path;
}

function exactObjectKeys(value, expectedKeys, label, blockers) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    blockers.push(`${label} must be an object`);
    return false;
  }
  const actual = Object.keys(value).sort();
  const expected = [...expectedKeys].sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    blockers.push(`${label} must contain exactly: ${expected.join(", ")}`);
    return false;
  }
  return true;
}

function productionBundleIdentifier(value) {
  return typeof value === "string"
    && /^[A-Za-z0-9.-]+$/.test(value)
    && value.includes(".")
    && !/(?:^local\.|example|placeholder|yourname|yourdomain)/i.test(value);
}

function validateEvidenceSHA(configuredSHA, absolutePath, label, blockers) {
  if (typeof configuredSHA !== "string" || !sha256Pattern.test(configuredSHA)) {
    blockers.push(`${label}.sha256 must contain 64 lowercase hexadecimal characters`);
    return null;
  }
  const actualSHA = absolutePath ? fileSHA256(absolutePath) : null;
  if (!actualSHA) {
    if (absolutePath) blockers.push(`${label}.path could not be hashed with SHA-256`);
  } else if (actualSHA !== configuredSHA) {
    blockers.push(`${label}.sha256 does not match the file`);
  }
  return actualSHA;
}

function validUTCTimestamp(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value)) return false;
  const milliseconds = Date.parse(value);
  return Number.isFinite(milliseconds)
    && new Date(milliseconds).toISOString().replace(".000Z", "Z") === value
    && milliseconds <= Date.now() + 5 * 60 * 1000;
}

function projectRelativePOSIX(path) {
  return relative(projectRoot, path).split(sep).join("/");
}

function matchingValidatedPrivacyArchives(candidate, actualArtifactSHA) {
  if (appPrivacy?.releaseEvidenceReady !== true
      || !Array.isArray(appPrivacy.releaseEvidence?.archives)
      || !actualArtifactSHA) {
    return [];
  }
  const privacyPlatform = candidate.platform === "macos" ? "macOS" : "iOS";
  return appPrivacy.releaseEvidence.archives.filter((archive) => (
    archive?.platform === privacyPlatform
    && archive?.bundleID === candidate.bundleIdentifier
    && archive?.version === candidate.version
    && archive?.build === candidate.build
    && archive?.path === candidate.artifact?.path
    && archive?.sha256 === actualArtifactSHA
  ));
}

function validateScreenshotEvidence() {
  const configuredPath = (process.env.AGENT_ISLAND_STORE_SCREENSHOT_EVIDENCE
    ?? ".release/store-screenshot-evidence.json").trim();
  const sharedBlockers = [];
  const platformBlockers = { macos: [], ios: [] };
  const evidencePath = repositoryRelativePath(
    configuredPath,
    "Store screenshot evidence",
    sharedBlockers,
  );
  let record = null;
  if (evidencePath) {
    if (lstatSync(evidencePath).size > 1024 * 1024) {
      sharedBlockers.push("Store screenshot evidence exceeds the 1 MiB limit");
    } else {
      try {
        record = JSON.parse(readFileSync(evidencePath, "utf8"));
      } catch (error) {
        sharedBlockers.push(`Store screenshot evidence is not valid JSON: ${error.message}`);
      }
    }
  }

  const candidatesByPlatform = { macos: [], ios: [] };
  const candidateSummaries = { macos: [], ios: [] };
  if (record) {
    exactObjectKeys(record, ["schemaVersion", "candidates"], "Store screenshot evidence", sharedBlockers);
    if (record.schemaVersion !== 1) {
      sharedBlockers.push("Store screenshot evidence schemaVersion must equal 1");
    }
    if (!Array.isArray(record.candidates) || record.candidates.length < 1 || record.candidates.length > 2) {
      sharedBlockers.push("Store screenshot evidence candidates must contain one or two platform records");
    } else {
      for (const [index, candidate] of record.candidates.entries()) {
        const label = `Store screenshot evidence candidates[${index}]`;
        const candidatePlatform = candidate?.platform;
        const blockers = Object.hasOwn(platformBlockers, candidatePlatform)
          ? platformBlockers[candidatePlatform]
          : sharedBlockers;
        exactObjectKeys(
          candidate,
          ["platform", "bundleIdentifier", "version", "build", "artifact", "screenshots"],
          label,
          blockers,
        );
        if (!Object.hasOwn(platformBlockers, candidatePlatform)) {
          blockers.push(`${label}.platform must be macos or ios`);
          continue;
        }
        candidatesByPlatform[candidatePlatform].push(candidate);
        if (!productionBundleIdentifier(candidate.bundleIdentifier)) {
          blockers.push(`${label}.bundleIdentifier must be a production bundle identifier`);
        }
        if (typeof candidate.version !== "string" || !/^\d+(?:\.\d+){1,2}$/.test(candidate.version)) {
          blockers.push(`${label}.version must be a numeric marketing version`);
        }
        if (typeof candidate.build !== "string" || !/^[1-9]\d*$/.test(candidate.build)) {
          blockers.push(`${label}.build must be a positive integer string`);
        }

        const artifactLabel = `${label}.artifact`;
        let actualArtifactSHA = null;
        const artifactIsObject = exactObjectKeys(candidate.artifact, ["path", "sha256"], artifactLabel, blockers);
        if (artifactIsObject) {
          const artifactPath = repositoryRelativePath(candidate.artifact.path, artifactLabel, blockers, "dist");
          const lowerPath = String(candidate.artifact.path).toLowerCase();
          const acceptedArtifactName = candidatePlatform === "ios"
            ? (lowerPath.endsWith(".ipa") || lowerPath.endsWith(".xcarchive.zip"))
            : (lowerPath.endsWith(".pkg") || lowerPath.endsWith(".zip"));
          if (!acceptedArtifactName) {
            blockers.push(
              `${artifactLabel}.path must identify an iOS .ipa/.xcarchive.zip or macOS .pkg/.zip candidate`,
            );
          }
          actualArtifactSHA = validateEvidenceSHA(
            candidate.artifact.sha256,
            artifactPath,
            artifactLabel,
            blockers,
          );
        }
        const matchingPrivacyArchives = matchingValidatedPrivacyArchives(candidate, actualArtifactSHA);
        const candidateIdentityVerified = matchingPrivacyArchives.length === 1;
        if (!candidateIdentityVerified) {
          blockers.push(
            `${label} must exactly match one candidate archive already validated by App Privacy evidence`,
          );
        }
        candidateSummaries[candidatePlatform].push({
          platform: candidatePlatform,
          bundleIdentifier: candidate.bundleIdentifier ?? null,
          version: candidate.version ?? null,
          build: candidate.build ?? null,
          artifact: {
            path: candidate.artifact?.path ?? null,
            configuredSHA256: candidate.artifact?.sha256 ?? null,
            actualSHA256: actualArtifactSHA,
          },
          candidateIdentityVerified,
          screenshotCount: Array.isArray(candidate.screenshots) ? candidate.screenshots.length : 0,
        });

        if (!Array.isArray(candidate.screenshots) || candidate.screenshots.length < 2 || candidate.screenshots.length > 20) {
          blockers.push(`${label}.screenshots must contain the final screenshots for both locales`);
          continue;
        }
        const configuredScreenshotPaths = [];
        const screenshotDigests = [];
        for (const [screenshotIndex, screenshot] of candidate.screenshots.entries()) {
          const screenshotLabel = `${label}.screenshots[${screenshotIndex}]`;
          const screenshotIsObject = exactObjectKeys(
            screenshot,
            ["path", "sha256", "locale", "device", "capturedAt", "source", "attestations"],
            screenshotLabel,
            blockers,
          );
          if (!screenshotIsObject) continue;
          if (!["zh-Hans", "en-US"].includes(screenshot.locale)) {
            blockers.push(`${screenshotLabel}.locale must be zh-Hans or en-US`);
          }
          const requiredPrefix = `docs/release-assets/${candidatePlatform}/${screenshot.locale}`;
          const screenshotPath = repositoryRelativePath(
            screenshot.path,
            screenshotLabel,
            blockers,
            requiredPrefix,
          );
          if (typeof screenshot.path === "string") configuredScreenshotPaths.push(screenshot.path);
          const properties = screenshotPath ? imageProperties(screenshotPath) : null;
          if (screenshotPath
              && (!properties.readable || !imageFormatMatchesExtension(screenshotPath, properties.format))) {
            blockers.push(`${screenshotLabel}.path must be an image whose format matches its extension`);
          }
          const actualScreenshotSHA = validateEvidenceSHA(
            screenshot.sha256,
            screenshotPath,
            screenshotLabel,
            blockers,
          );
          if (actualScreenshotSHA && ["zh-Hans", "en-US"].includes(screenshot.locale)) {
            screenshotDigests.push({ sha256: actualScreenshotSHA, locale: screenshot.locale });
          }
          if (typeof screenshot.device !== "string"
              || screenshot.device.trim() !== screenshot.device
              || screenshot.device.length < 2
              || screenshot.device.length > 80
              || /(?:placeholder|example|\[|\])/i.test(screenshot.device)) {
            blockers.push(`${screenshotLabel}.device must identify the capture device or display`);
          }
          if (!validUTCTimestamp(screenshot.capturedAt)) {
            blockers.push(`${screenshotLabel}.capturedAt must be a valid, non-future UTC timestamp`);
          }
          if (screenshot.source !== "exact-candidate-build") {
            blockers.push(`${screenshotLabel}.source must equal exact-candidate-build`);
          }
          if (exactObjectKeys(
            screenshot.attestations,
            [
              "exactCandidateBuild",
              "localizedForLocale",
              "noSensitiveDataReviewed",
              "notStretchedOrSynthetic",
            ],
            `${screenshotLabel}.attestations`,
            blockers,
          )) {
            for (const attestation of [
              "exactCandidateBuild",
              "localizedForLocale",
              "noSensitiveDataReviewed",
              "notStretchedOrSynthetic",
            ]) {
              if (screenshot.attestations[attestation] !== true) {
                blockers.push(`${screenshotLabel}.attestations.${attestation} must equal true`);
              }
            }
          }
        }

        if (new Set(configuredScreenshotPaths).size !== configuredScreenshotPaths.length) {
          blockers.push(`${label}.screenshots must not contain duplicate paths`);
        }
        const localesByDigest = new Map();
        for (const item of screenshotDigests) {
          const locales = localesByDigest.get(item.sha256) ?? new Set();
          locales.add(item.locale);
          localesByDigest.set(item.sha256, locales);
        }
        if ([...localesByDigest.values()].some((locales) => locales.size > 1)) {
          blockers.push(`${label}.screenshots must not reuse identical image bytes across locales`);
        }
        const actualScreenshotPaths = finalScreenshots
          .filter((set) => set.platform === candidatePlatform)
          .flatMap((set) => set.images.map((image) => projectRelativePOSIX(image.path)))
          .sort();
        const evidenceScreenshotPaths = [...configuredScreenshotPaths].sort();
        if (JSON.stringify(actualScreenshotPaths) !== JSON.stringify(evidenceScreenshotPaths)) {
          blockers.push(`${label}.screenshots must bind every and only final ${candidatePlatform} screenshot`);
        }
      }
    }
  }

  for (const platform of ["macos", "ios"]) {
    if (candidatesByPlatform[platform].length !== 1) {
      platformBlockers[platform].push(
        `Store screenshot evidence must contain exactly one ${platform} candidate record`,
      );
    }
  }
  for (const blocker of sharedBlockers) addReleaseBlocker(blocker);
  for (const blocker of platformBlockers.macos) addReleaseBlocker(blocker, ["macOS"]);
  for (const blocker of platformBlockers.ios) addReleaseBlocker(blocker, ["iOS"]);

  return {
    path: configuredPath,
    schemaVersion: record?.schemaVersion ?? null,
    candidates: Array.isArray(record?.candidates)
      ? record.candidates.map((candidate) => ({
        platform: candidate?.platform ?? null,
        bundleIdentifier: candidate?.bundleIdentifier ?? null,
        version: candidate?.version ?? null,
        build: candidate?.build ?? null,
        artifact: candidate?.artifact ?? null,
        screenshotCount: Array.isArray(candidate?.screenshots) ? candidate.screenshots.length : 0,
      }))
      : [],
    platforms: {
      macos: {
        ready: sharedBlockers.length === 0
          && platformBlockers.macos.length === 0
          && candidatesByPlatform.macos.length === 1,
        blockers: [...sharedBlockers, ...platformBlockers.macos],
        candidate: candidateSummaries.macos.length === 1 ? candidateSummaries.macos[0] : null,
      },
      ios: {
        ready: sharedBlockers.length === 0
          && platformBlockers.ios.length === 0
          && candidatesByPlatform.ios.length === 1,
        blockers: [...sharedBlockers, ...platformBlockers.ios],
        candidate: candidateSummaries.ios.length === 1 ? candidateSummaries.ios[0] : null,
      },
    },
  };
}

const screenshotEvidence = validateScreenshotEvidence();

const iconManifestPath = join(
  projectRoot,
  "ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json",
);
const iconChecks = [];
let iosIconManifestValid = true;
if (!existsSync(iconManifestPath)) {
  addStructuralError(`missing iOS AppIcon manifest: ${iconManifestPath}`, ["iOS"]);
  iosIconManifestValid = false;
} else {
  const manifestInspection = inspectProjectPath(iconManifestPath, "file");
  if (!manifestInspection.valid) {
    addStructuralError(`invalid iOS AppIcon manifest: ${manifestInspection.reason}`, ["iOS"]);
    iosIconManifestValid = false;
  }
  let manifest = null;
  if (manifestInspection.valid) {
    try {
      manifest = JSON.parse(readFileSync(iconManifestPath, "utf8"));
    } catch (error) {
      addStructuralError(`iOS AppIcon manifest is not valid JSON: ${error.message}`, ["iOS"]);
      iosIconManifestValid = false;
    }
  }
  const manifestImages = Array.isArray(manifest?.images) ? manifest.images : [];
  if (manifest && manifestImages.length === 0) {
    addStructuralError(`iOS AppIcon manifest has no image entries: ${iconManifestPath}`, ["iOS"]);
    iosIconManifestValid = false;
  }
  const slotKeys = [];
  const filenames = [];
  for (const [index, entry] of manifestImages.entries()) {
    const label = `iOS AppIcon images[${index}]`;
    const sizeMatch = typeof entry?.size === "string"
      ? entry.size.match(/^(\d+(?:\.\d+)?)x\1$/)
      : null;
    const scaleMatch = typeof entry?.scale === "string" ? entry.scale.match(/^([123])x$/) : null;
    const filename = typeof entry?.filename === "string" ? entry.filename : "";
    const validFilename = filename !== ""
      && filename === filename.trim()
      && !filename.includes("/")
      && !filename.includes("\\")
      && extname(filename).toLowerCase() === ".png";
    if (!sizeMatch || !scaleMatch || !validFilename || typeof entry?.idiom !== "string") {
      addStructuralError(`invalid ${label} descriptor`, ["iOS"]);
      iosIconManifestValid = false;
      continue;
    }
    const expectedPixels = Number(sizeMatch[1]) * Number(scaleMatch[1]);
    const path = join(dirname(iconManifestPath), filename);
    const pathInspection = inspectProjectPath(path, "file");
    const properties = imageProperties(path);
    const valid = pathInspection.valid
      && properties.readable
      && properties.format === "png"
      && properties.width === expectedPixels
      && properties.height === expectedPixels
      && !properties.hasAlpha;
    if (!valid) {
      addStructuralError(`invalid iOS AppIcon asset: ${path}`, ["iOS"]);
      iosIconManifestValid = false;
    }
    const slotKey = `${entry.idiom}|${entry.size}|${entry.scale}`;
    slotKeys.push(slotKey);
    filenames.push(filename);
    iconChecks.push({ path, idiom: entry.idiom, size: entry.size, scale: entry.scale, expectedPixels, ...properties, valid });
  }
  if (new Set(slotKeys).size !== slotKeys.length) {
    addStructuralError("iOS AppIcon manifest contains duplicate idiom/size/scale slots", ["iOS"]);
    iosIconManifestValid = false;
  }
  if (new Set(filenames).size !== filenames.length) {
    addStructuralError("iOS AppIcon manifest must use a unique PNG file for every slot", ["iOS"]);
    iosIconManifestValid = false;
  }
  for (const requiredSlot of [
    "ios-marketing|1024x1024|1x",
    "iphone|60x60|2x",
    "iphone|60x60|3x",
  ]) {
    if (slotKeys.filter((value) => value === requiredSlot).length !== 1) {
      addStructuralError(`iOS AppIcon manifest must contain exactly one required slot: ${requiredSlot}`, ["iOS"]);
      iosIconManifestValid = false;
    }
  }
}

const macIconPath = join(projectRoot, "Resources/AgentIsland.icns");
const macIconInspection = inspectProjectPath(macIconPath, "file");
const macIconProperties = imageProperties(macIconPath);
const macIconValid = macIconInspection.valid
  && macIconProperties.readable
  && macIconProperties.format === "icns"
  && macIconProperties.width === 1024
  && macIconProperties.height === 1024;
if (!macIconValid) {
  addStructuralError(`invalid macOS AppIcon asset: ${macIconPath}`, ["macOS"]);
}

const metadataStructurallyValid = structuralErrors.length === 0;
function screenshotSetsReady(platform) {
  const sets = finalScreenshots.filter((set) => set.platform === platform);
  return sets.length === 2 && sets.every(
    (set) => set.count >= 1 && set.count <= 10 && set.images.every((image) => image.valid),
  );
}

const iosIconsReady = iosIconManifestValid
  && iconChecks.length >= 3
  && iconChecks.every((item) => item.valid);
const iconsReady = iosIconsReady && macIconValid;
const macStoreSubmissionAssetsReady = platformStructuralErrors.macOS.length === 0
  && platformReleaseBlockers.macOS.length === 0
  && screenshotSetsReady("macos")
  && screenshotEvidence.platforms.macos.ready
  && macIconValid;
const iosStoreSubmissionAssetsReady = platformStructuralErrors.iOS.length === 0
  && platformReleaseBlockers.iOS.length === 0
  && screenshotSetsReady("ios")
  && screenshotEvidence.platforms.ios.ready
  && iosIconsReady;
const storeSubmissionAssetsReady = macStoreSubmissionAssetsReady && iosStoreSubmissionAssetsReady;
const releaseReady = storeSubmissionAssetsReady;

const result = {
  schemaVersion: 1,
  mode: releaseMode ? "release" : "draft",
  authoritativeRequirements: {
    metadata: "Apple App Store Connect field limits",
    macScreenshots: [...allowedScreenshotDimensions.macos],
    iPhoneScreenshots: [...allowedScreenshotDimensions.ios],
    screenshotsPerLocale: { minimum: 1, maximum: 10 },
    screenshotsMustNotHaveAlpha: true,
  },
  metadata,
  submissionDocuments,
  appPrivacy,
  supportContact,
  icons: {
    ready: iconsReady,
    macOS: { path: macIconPath, ...macIconProperties, valid: macIconValid },
    iOS: { ready: iosIconsReady, manifestPath: iconManifestPath, images: iconChecks },
    images: iconChecks,
  },
  referenceScreenshots,
  finalScreenshots,
  screenshotEvidence,
  structuralErrors,
  releaseBlockers,
  macStoreSubmissionStructuralErrors: platformStructuralErrors.macOS,
  iosStoreSubmissionStructuralErrors: platformStructuralErrors.iOS,
  macStoreSubmissionBlockers: platformReleaseBlockers.macOS,
  iosStoreSubmissionBlockers: platformReleaseBlockers.iOS,
  draftValid: metadataStructurallyValid,
  macStoreSubmissionAssetsReady,
  iosStoreSubmissionAssetsReady,
  storeSubmissionAssetsReady,
  releaseReady,
  validatorSelfTests: {
    placeholderParser: JSON.stringify(placeholderParserRegression) === JSON.stringify(['[支持邮箱]']),
    releaseDraftSentinelParser: sentinelParserRegression.length === 2
      && sentinelParserRegression[0].line === 2
      && sentinelParserRegression[1].line === 3,
    storeMarkupParser: storeMarkupParserRegression,
  },
};

process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
if (!metadataStructurallyValid || (releaseMode && !releaseReady)) {
  process.exit(1);
}
