#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
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
    structuralErrors.push(`${key}: missing locale section ${localeConfig.section}`);
    return { platform: document.platform, locale: localeConfig.locale, fields: null };
  }

  const fields = {};
  for (const [field, pattern] of Object.entries(localeConfig.headings)) {
    const value = fieldValue(lines, pattern, field === "description");
    if (value === null || value === "") {
      structuralErrors.push(`${key}: missing ${field}`);
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
      structuralErrors.push(`${key}: ${field} is shorter than ${limit.minimum} ${limit.unit}`);
    }
    if (measured > limit.maximum) {
      structuralErrors.push(`${key}: ${field} is ${measured} ${limit.unit}; maximum is ${limit.maximum}`);
    }
  }

  const keywords = fields.keywords.split(",").map((item) => item.trim()).filter(Boolean);
  if (keywords.length === 0 || keywords.some((item) => characterCount(item) <= 2)) {
    structuralErrors.push(`${key}: every comma-separated keyword must contain more than two characters`);
  }
  if (/\[[^\]]+\]/.test(Object.values(fields).join("\n"))) {
    releaseBlockers.push(`${key}: extracted store metadata still contains a placeholder`);
  }
  if (/^(agent island|tasklume)$/i.test(fields.name.trim())) {
    releaseBlockers.push(`${key}: ${JSON.stringify(fields.name)} is a known conflicted release name`);
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
    structuralErrors.push(`missing metadata document: ${document.path}`);
    continue;
  }
  const markdown = readFileSync(document.path, "utf8");
  for (const locale of document.locales) {
    metadata.push(validateMetadataLocale(document, locale, markdown));
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
    const output = execFileSync("/usr/bin/sips", ["-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", path], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    const width = Number(output.match(/pixelWidth:\s*(\d+)/)?.[1] ?? 0);
    const height = Number(output.match(/pixelHeight:\s*(\d+)/)?.[1] ?? 0);
    const hasAlpha = (output.match(/hasAlpha:\s*(\w+)/)?.[1] ?? "unknown") === "yes";
    return { width, height, hasAlpha, readable: width > 0 && height > 0 };
  } catch {
    return { width: 0, height: 0, hasAlpha: false, readable: false };
  }
}

function imageFiles(directory) {
  if (!existsSync(directory)) return [];
  return readdirSync(directory)
    .filter((name) => [".png", ".jpg", ".jpeg"].includes(extname(name).toLowerCase()))
    .sort()
    .map((name) => join(directory, name));
}

function inspectScreenshots(platform, locale, directory, required) {
  const files = imageFiles(directory);
  const images = files.map((path) => {
    const properties = imageProperties(path);
    const dimensions = `${properties.width}x${properties.height}`;
    const acceptedDimensions = allowedScreenshotDimensions[platform].has(dimensions);
    const valid = properties.readable && acceptedDimensions && !properties.hasAlpha;
    if (required && !valid) {
      releaseBlockers.push(`${platform}/${locale}: ${path} must use an accepted size and have no alpha channel`);
    }
    return { path, dimensions, hasAlpha: properties.hasAlpha, acceptedDimensions, valid };
  });
  if (required && (files.length < 1 || files.length > 10)) {
    releaseBlockers.push(`${platform}/${locale}: expected 1-10 final screenshots, found ${files.length}`);
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

const referenceDirectory = join(projectRoot, "docs/screenshots");
const referenceScreenshots = imageFiles(referenceDirectory).map((path) => {
  const properties = imageProperties(path);
  const dimensions = `${properties.width}x${properties.height}`;
  return {
    path,
    dimensions,
    hasAlpha: properties.hasAlpha,
    storeEligibleAsMacScreenshot: allowedScreenshotDimensions.macos.has(dimensions) && !properties.hasAlpha,
  };
});

const iconManifestPath = join(
  projectRoot,
  "ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json",
);
const iconChecks = [];
if (!existsSync(iconManifestPath)) {
  structuralErrors.push(`missing iOS AppIcon manifest: ${iconManifestPath}`);
} else {
  const manifest = JSON.parse(readFileSync(iconManifestPath, "utf8"));
  for (const entry of manifest.images ?? []) {
    const expectedPoints = Number.parseFloat(entry.size?.split("x")[0] ?? "0");
    const scale = Number.parseFloat(entry.scale?.replace("x", "") ?? "0");
    const expectedPixels = expectedPoints * scale;
    const path = join(dirname(iconManifestPath), entry.filename ?? "");
    const properties = imageProperties(path);
    const valid = existsSync(path)
      && properties.readable
      && properties.width === expectedPixels
      && properties.height === expectedPixels
      && !properties.hasAlpha;
    if (!valid) {
      structuralErrors.push(`invalid iOS AppIcon asset: ${path}`);
    }
    iconChecks.push({ path, expectedPixels, ...properties, valid });
  }
}

const metadataStructurallyValid = structuralErrors.length === 0;
const finalScreenshotSetsReady = finalScreenshots.every(
  (set) => set.count >= 1 && set.count <= 10 && set.images.every((image) => image.valid),
);
const releaseReady = metadataStructurallyValid && releaseBlockers.length === 0 && finalScreenshotSetsReady;

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
  icons: { ready: iconChecks.length > 0 && iconChecks.every((item) => item.valid), images: iconChecks },
  referenceScreenshots,
  finalScreenshots,
  structuralErrors,
  releaseBlockers,
  draftValid: metadataStructurallyValid,
  releaseReady,
};

process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
if (!metadataStructurallyValid || (releaseMode && !releaseReady)) {
  process.exit(1);
}
