#!/usr/bin/env node

import {
  closeSync,
  existsSync,
  lstatSync,
  openSync,
  readFileSync,
  readSync,
  realpathSync,
} from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const projectRoot = realpathSync(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..'));
const args = new Set(process.argv.slice(2));
const knownArgs = new Set(['--release']);
for (const argument of args) {
  if (!knownArgs.has(argument)) {
    console.error(`Unknown option: ${argument}`);
    process.exit(2);
  }
}

const releaseMode = args.has('--release');
const structuralErrors = [];
const releaseBlockers = [];

function readPlist(relativePath) {
  const absolutePath = path.join(projectRoot, relativePath);
  const result = spawnSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', absolutePath], {
    encoding: 'utf8',
  });
  if (result.status !== 0) {
    structuralErrors.push(`${relativePath} is not a readable property list`);
    return {};
  }
  try {
    return JSON.parse(result.stdout);
  } catch (error) {
    structuralErrors.push(`${relativePath} did not convert to JSON: ${error.message}`);
    return {};
  }
}

function sorted(values) {
  return [...values].sort((left, right) => left.localeCompare(right));
}

function expectEqual(actual, expected, label) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    structuralErrors.push(`${label}; expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`);
  }
}

function validateCommon(relativePath, manifest) {
  expectEqual(manifest.NSPrivacyTracking, false, `${relativePath} must disable tracking`);
  expectEqual(manifest.NSPrivacyTrackingDomains, [], `${relativePath} must have no tracking domains`);
}

function validateCollectedData(relativePath, manifest) {
  const dataTypes = manifest.NSPrivacyCollectedDataTypes ?? [];
  expectEqual(
    sorted(dataTypes.map((entry) => entry.NSPrivacyCollectedDataType)),
    sorted([
      'NSPrivacyCollectedDataTypeOtherUsageData',
      'NSPrivacyCollectedDataTypeOtherUserContent',
    ]),
    `${relativePath} collected-data types must match the App Privacy worksheet`,
  );
  for (const entry of dataTypes) {
    expectEqual(entry.NSPrivacyCollectedDataTypeLinked, true, `${relativePath} data must be linked`);
    expectEqual(entry.NSPrivacyCollectedDataTypeTracking, false, `${relativePath} data must not track`);
    expectEqual(
      entry.NSPrivacyCollectedDataTypePurposes,
      ['NSPrivacyCollectedDataTypePurposeAppFunctionality'],
      `${relativePath} data must be used only for app functionality`,
    );
  }
}

function accessedAPIEntries(relativePath, manifest) {
  const entries = manifest.NSPrivacyAccessedAPITypes ?? [];
  const categories = entries.map((entry) => entry.NSPrivacyAccessedAPIType);
  if (new Set(categories).size !== categories.length) {
    structuralErrors.push(`${relativePath} contains duplicate required-reason API categories`);
  }
  return entries;
}

function expectUserDefaults(relativePath, entries) {
  const userDefaults = entries.find(
    (entry) => entry.NSPrivacyAccessedAPIType === 'NSPrivacyAccessedAPICategoryUserDefaults',
  );
  if (!userDefaults) {
    structuralErrors.push(`${relativePath} must declare UserDefaults`);
    return;
  }
  expectEqual(
    userDefaults.NSPrivacyAccessedAPITypeReasons,
    ['CA92.1'],
    `${relativePath} UserDefaults reason must be CA92.1`,
  );
}

function validateIOSManifest(relativePath) {
  const manifest = readPlist(relativePath);
  validateCommon(relativePath, manifest);
  validateCollectedData(relativePath, manifest);
  const entries = accessedAPIEntries(relativePath, manifest);
  expectEqual(entries.length, 1, `${relativePath} must declare exactly one required-reason API category`);
  expectUserDefaults(relativePath, entries);
}

function validateWidgetManifest(relativePath) {
  const manifest = readPlist(relativePath);
  validateCommon(relativePath, manifest);
  expectEqual(manifest.NSPrivacyCollectedDataTypes, [], `${relativePath} must not declare collected data`);
  expectEqual(manifest.NSPrivacyAccessedAPITypes, [], `${relativePath} must not declare required-reason APIs`);
}

function validateMacManifest(relativePath) {
  const manifest = readPlist(relativePath);
  validateCommon(relativePath, manifest);
  validateCollectedData(relativePath, manifest);
  // Apple's required-reason API declaration requirement applies to iOS,
  // iPadOS, tvOS, visionOS, and watchOS, not a native macOS target. Keep the
  // Mac sandbox/file-authorization audit separate from its collected-data
  // privacy manifest instead of forcing mobile-only reasons into this file.
}

validateMacManifest('Resources/PrivacyInfo.xcprivacy');
validateIOSManifest('ApplePlatforms/iOS/Config/PrivacyInfo.xcprivacy');
validateWidgetManifest('ApplePlatforms/iOS/WidgetExtension/PrivacyInfo.xcprivacy');

const nativeSourcePath = path.join(projectRoot, 'Native/AgentIsland.m');
const nativeSource = readFileSync(nativeSourcePath, 'utf8');
const timestampAPIUsed = /NSFileModificationDate|NSURLContentModificationDateKey/.test(nativeSource);
const automaticHomeScanMarkers = [
  'stringByAppendingPathComponent:@".codex"',
  'stringByAppendingPathComponent:@".claude/projects"',
  'Library/Application Support/Code/User/globalStorage/agent-host.db',
  'stringByAppendingPathComponent:@".vscode/extensions/extensions.json"',
  'stringByAppendingPathComponent:@".cursor/extensions/extensions.json"',
  'stringByAppendingPathComponent:@".windsurf/extensions/extensions.json"',
  'Library/Application Support/Cursor',
  'Library/Application Support/Windsurf',
  'Library/Application Support/Zed',
  'stringByAppendingPathComponent:@".config/zed"',
];
const automaticHomeScanPresent = automaticHomeScanMarkers.some((marker) => nativeSource.includes(marker));
const bookmarkMarkers = [
  'bookmarkDataWithOptions',
  'URLByResolvingBookmarkData',
  'startAccessingSecurityScopedResource',
  'stopAccessingSecurityScopedResource',
];
const securityScopedBookmarkMarkersPresent = bookmarkMarkers.every((marker) => nativeSource.includes(marker));

const worksheetPath = path.join(projectRoot, 'docs/release/APP_PRIVACY_SUBMISSION_WORKSHEET.md');
const worksheet = readFileSync(worksheetPath, 'utf8');
const requiredWorksheetMarkers = [
  'Yes, we collect data from this app',
  'Usage Data → Other Usage Data',
  'User Content → Other User Content',
  'App Functionality',
  'Linked to the user\'s identity?',
  'Used for tracking?',
  'Xcode Privacy Report',
  'App 记录级别',
  'AGENT_ISLAND_APP_PRIVACY_EVIDENCE',
  'candidateArchiveSHA256s',
];
for (const marker of requiredWorksheetMarkers) {
  if (!worksheet.includes(marker)) {
    structuralErrors.push(`the submission worksheet is missing required marker: ${marker}`);
  }
}

const sha256Pattern = /^[0-9a-f]{64}$/;
const requiredEvidenceKinds = [
  'privacyManifests',
  'xcodePrivacyReport',
  'networkAudit',
  'cloudKitVerification',
  'titleSyncVerification',
  'translationProviderDecision',
  'publicPagesVerification',
  'appStoreConnectPublication',
];

function productionBundleID(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9.-]+$/.test(value) || !value.includes('.')) return false;
  const normalized = value.toLowerCase();
  return !normalized.startsWith('local.')
    && !/(?:example|placeholder|yourname|yourdomain)/.test(normalized);
}

function projectFile(relativePath, label, blockers, maximumBytes = Number.POSITIVE_INFINITY) {
  if (typeof relativePath !== 'string' || relativePath.trim() === '' || path.isAbsolute(relativePath)) {
    blockers.push(`${label}.path must be a non-empty repository-relative path`);
    return null;
  }
  const absolutePath = path.resolve(projectRoot, relativePath);
  const projectRelative = path.relative(projectRoot, absolutePath);
  if (projectRelative.startsWith('..') || path.isAbsolute(projectRelative)) {
    blockers.push(`${label}.path must stay inside the repository`);
    return null;
  }
  if (!existsSync(absolutePath)) {
    blockers.push(`${label}.path does not exist: ${relativePath}`);
    return null;
  }
  // `path.resolve()` is only lexical: repo/link/file still looks repository-
  // relative when `link` points outside. Reject a symlink in every component,
  // then confirm the canonical file remains below the canonical repository.
  let componentPath = projectRoot;
  for (const component of projectRelative.split(path.sep).filter(Boolean)) {
    componentPath = path.join(componentPath, component);
    const componentStat = lstatSync(componentPath);
    if (componentStat.isSymbolicLink()) {
      blockers.push(`${label}.path must not contain a symbolic-link component`);
      return null;
    }
  }
  const canonicalPath = realpathSync(absolutePath);
  const canonicalRelative = path.relative(projectRoot, canonicalPath);
  if (canonicalRelative.startsWith('..') || path.isAbsolute(canonicalRelative)) {
    blockers.push(`${label}.path real location must stay inside the repository`);
    return null;
  }
  const stat = lstatSync(canonicalPath);
  if (!stat.isFile()) {
    blockers.push(`${label}.path must be a regular file, not a directory or symlink`);
    return null;
  }
  if (stat.size > maximumBytes) {
    blockers.push(`${label}.path exceeds the ${maximumBytes}-byte evidence-file limit`);
    return null;
  }
  return canonicalPath;
}

function fileSHA256(absolutePath, label, blockers) {
  const result = spawnSync('/usr/bin/shasum', ['-a', '256', absolutePath], {
    encoding: 'utf8',
    env: { ...process.env, LC_ALL: 'C', LANG: 'C' },
  });
  const digest = result.status === 0 ? result.stdout.trim().split(/\s+/)[0]?.toLowerCase() : '';
  if (!sha256Pattern.test(digest)) {
    blockers.push(`${label} could not be hashed with SHA-256`);
    return null;
  }
  return digest;
}

function expectedSHA256(record, label, blockers) {
  const digest = typeof record?.sha256 === 'string' ? record.sha256.toLowerCase() : '';
  if (!sha256Pattern.test(digest)) {
    blockers.push(`${label}.sha256 must contain 64 lowercase hexadecimal characters`);
    return null;
  }
  return digest;
}

function fileMagic(absolutePath) {
  const descriptor = openSync(absolutePath, 'r');
  try {
    const buffer = Buffer.alloc(4);
    const bytesRead = readSync(descriptor, buffer, 0, buffer.length, 0);
    return buffer.subarray(0, bytesRead);
  } finally {
    closeSync(descriptor);
  }
}

function plistValue(plistBuffer, key) {
  const result = spawnSync('/usr/bin/plutil', ['-extract', key, 'raw', '-o', '-', '-'], {
    input: plistBuffer,
    encoding: 'utf8',
    maxBuffer: 1024 * 1024,
  });
  return result.status === 0 ? result.stdout.trim() : '';
}

function validateZIPCandidate(archive, absolutePath, label, blockers) {
  const magic = fileMagic(absolutePath);
  if (magic.length < 2 || magic[0] !== 0x50 || magic[1] !== 0x4b) {
    blockers.push(`${label}.path has a .zip/.ipa name but is not a ZIP file`);
    return;
  }
  const listingResult = spawnSync('/usr/bin/unzip', ['-Z1', absolutePath], {
    encoding: 'utf8',
    maxBuffer: 50 * 1024 * 1024,
  });
  if (listingResult.status !== 0) {
    blockers.push(`${label}.path is not a readable ZIP archive`);
    return;
  }
  const entries = listingResult.stdout
    .split(/\r?\n/)
    .map((entry) => entry.replace(/^\.\//, ''))
    .filter(Boolean);
  const lowerName = archive.path.toLowerCase();
  let infoPattern;
  if (archive.platform === 'iOS' && lowerName.endsWith('.ipa')) {
    infoPattern = /^Payload\/[^/]+\.app\/Info\.plist$/;
  } else if (archive.platform === 'iOS') {
    infoPattern = /^[^/]+\.xcarchive\/Products\/Applications\/[^/]+\.app\/Info\.plist$/;
  } else if (lowerName.endsWith('.xcarchive.zip')) {
    infoPattern = /^[^/]+\.xcarchive\/Products\/Applications\/[^/]+\.app\/Contents\/Info\.plist$/;
  } else {
    infoPattern = /^[^/]+\.app\/Contents\/Info\.plist$/;
  }
  const infoEntries = entries.filter((entry) => infoPattern.test(entry));
  if (infoEntries.length !== 1) {
    blockers.push(`${label}.path must contain exactly one platform App Info.plist`);
    return;
  }

  const infoEntry = infoEntries[0];
  const infoResult = spawnSync('/usr/bin/unzip', ['-p', absolutePath, infoEntry], {
    encoding: null,
    maxBuffer: 5 * 1024 * 1024,
  });
  if (infoResult.status !== 0 || infoResult.stdout.length === 0) {
    blockers.push(`${label}.path App Info.plist could not be extracted`);
    return;
  }
  const actualBundleID = plistValue(infoResult.stdout, 'CFBundleIdentifier');
  const actualVersion = plistValue(infoResult.stdout, 'CFBundleShortVersionString');
  const actualBuild = plistValue(infoResult.stdout, 'CFBundleVersion');
  const executable = plistValue(infoResult.stdout, 'CFBundleExecutable');
  if (actualBundleID !== archive.bundleID) {
    blockers.push(`${label}.bundleID does not match the App inside the candidate archive`);
  }
  if (actualVersion !== archive.version) {
    blockers.push(`${label}.version does not match the App inside the candidate archive`);
  }
  if (actualBuild !== archive.build) {
    blockers.push(`${label}.build does not match the App inside the candidate archive`);
  }
  if (!executable) {
    blockers.push(`${label}.path App Info.plist is missing CFBundleExecutable`);
  } else {
    const infoPrefix = infoEntry.slice(0, -'Info.plist'.length);
    const executableEntry = archive.platform === 'macOS'
      ? `${infoPrefix}MacOS/${executable}`
      : `${infoPrefix}${executable}`;
    if (!entries.includes(executableEntry)) {
      blockers.push(`${label}.path does not contain the App executable declared by Info.plist`);
    }
  }
  const infoPrefix = infoEntry.slice(0, -'Info.plist'.length);
  const privacyManifestEntry = archive.platform === 'macOS'
    ? `${infoPrefix}Resources/PrivacyInfo.xcprivacy`
    : `${infoPrefix}PrivacyInfo.xcprivacy`;
  if (!entries.includes(privacyManifestEntry)) {
    blockers.push(`${label}.path does not contain the main App PrivacyInfo.xcprivacy`);
  }
  if (archive.platform === 'iOS'
      && !entries.some((entry) => /^Payload\/[^/]+\.app\/PlugIns\/[^/]+\.appex\/PrivacyInfo\.xcprivacy$/.test(entry)
        || /^[^/]+\.xcarchive\/Products\/Applications\/[^/]+\.app\/PlugIns\/[^/]+\.appex\/PrivacyInfo\.xcprivacy$/.test(entry))) {
    blockers.push(`${label}.path does not contain the Widget Extension PrivacyInfo.xcprivacy`);
  }
}

function validateCandidateArchive(archive, absolutePath, label, blockers) {
  if (!absolutePath || !['macOS', 'iOS'].includes(archive?.platform) || typeof archive?.path !== 'string') {
    return;
  }
  const projectRelative = path.relative(projectRoot, absolutePath);
  if (projectRelative !== 'dist' && !projectRelative.startsWith(`dist${path.sep}`)) {
    blockers.push(`${label}.path must identify a candidate file under dist/`);
  }
  const lowerName = archive.path.toLowerCase();
  if (archive.platform === 'iOS') {
    if (!lowerName.endsWith('.ipa') && !lowerName.endsWith('.xcarchive.zip')) {
      blockers.push(`${label}.path must end in .ipa or .xcarchive.zip for iOS`);
      return;
    }
    validateZIPCandidate(archive, absolutePath, label, blockers);
    return;
  }
  if (lowerName.endsWith('.pkg')) {
    if (fileMagic(absolutePath).toString('ascii') !== 'xar!') {
      blockers.push(`${label}.path has a .pkg name but is not an XAR package`);
      return;
    }
    const listing = spawnSync('/usr/bin/xar', ['-tf', absolutePath], {
      encoding: 'utf8',
      maxBuffer: 10 * 1024 * 1024,
    });
    if (listing.status !== 0 || !/(?:^|\/)(?:PackageInfo|Distribution)$/m.test(listing.stdout)) {
      blockers.push(`${label}.path is not a readable macOS installer package`);
    }
    return;
  }
  if (!lowerName.endsWith('.zip')) {
    blockers.push(`${label}.path must end in .pkg, .zip, or .xcarchive.zip for macOS`);
    return;
  }
  validateZIPCandidate(archive, absolutePath, label, blockers);
}

function validateReleaseEvidence() {
  const blockers = [];
  const configuredPath = (process.env.AGENT_ISLAND_APP_PRIVACY_EVIDENCE
    ?? '.release/app-privacy-evidence.json').trim();
  const absoluteEvidencePath = projectFile(configuredPath, 'App Privacy evidence', blockers, 1024 * 1024);
  if (!absoluteEvidencePath) {
    return { path: configuredPath, record: null, blockers };
  }

  let record;
  try {
    record = JSON.parse(readFileSync(absoluteEvidencePath, 'utf8'));
  } catch (error) {
    blockers.push(`App Privacy evidence is not valid JSON: ${error.message}`);
    return { path: configuredPath, record: null, blockers };
  }

  if (record?.schemaVersion !== 1) {
    blockers.push('App Privacy evidence schemaVersion must equal 1');
  }
  const allowedScopes = new Set(['macOS', 'iOS', 'universal-purchase', 'separate-records']);
  if (!allowedScopes.has(record?.recordScope)) {
    blockers.push('App Privacy evidence recordScope must be macOS, iOS, universal-purchase, or separate-records');
  }
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(record?.reviewedAt ?? '')) {
    blockers.push('App Privacy evidence reviewedAt must be a UTC timestamp such as 2026-09-03T12:00:00Z');
  }

  const archives = Array.isArray(record?.archives) ? record.archives : [];
  if (archives.length < 1 || archives.length > 2) {
    blockers.push('App Privacy evidence must identify one or two candidate archives');
  }
  const archivePlatforms = [];
  const archiveBundleIDs = [];
  const archiveSHA256s = [];
  for (const [index, archive] of archives.entries()) {
    const label = `App Privacy evidence archives[${index}]`;
    if (!['macOS', 'iOS'].includes(archive?.platform)) {
      blockers.push(`${label}.platform must be macOS or iOS`);
    } else {
      archivePlatforms.push(archive.platform);
    }
    const expectedDistribution = archive?.platform === 'macOS' ? 'mac-app-store' : 'app-store';
    if (archive?.distribution !== expectedDistribution) {
      blockers.push(`${label}.distribution must be ${expectedDistribution}`);
    }
    if (!productionBundleID(archive?.bundleID)) {
      blockers.push(`${label}.bundleID must be a production bundle identifier`);
    } else {
      archiveBundleIDs.push(archive.bundleID);
    }
    if (typeof archive?.version !== 'string' || !/^\d+(?:\.\d+){1,2}$/.test(archive.version)) {
      blockers.push(`${label}.version must be a numeric marketing version`);
    }
    if (typeof archive?.build !== 'string' || !/^[1-9]\d*$/.test(archive.build)) {
      blockers.push(`${label}.build must be a positive integer string`);
    }
    const absoluteArchivePath = projectFile(archive?.path, label, blockers);
    validateCandidateArchive(archive, absoluteArchivePath, label, blockers);
    const configuredSHA256 = expectedSHA256(archive, label, blockers);
    const actualSHA256 = absoluteArchivePath ? fileSHA256(absoluteArchivePath, label, blockers) : null;
    if (configuredSHA256 && actualSHA256 && configuredSHA256 !== actualSHA256) {
      blockers.push(`${label}.sha256 does not match the candidate archive file`);
    }
    if (configuredSHA256) archiveSHA256s.push(configuredSHA256);
  }

  if (new Set(archivePlatforms).size !== archivePlatforms.length) {
    blockers.push('App Privacy evidence contains duplicate archive platforms');
  }
  const platformKey = [...archivePlatforms].sort().join(',');
  if (record?.recordScope === 'macOS' && platformKey !== 'macOS') {
    blockers.push('recordScope macOS must bind exactly one macOS archive');
  } else if (record?.recordScope === 'iOS' && platformKey !== 'iOS') {
    blockers.push('recordScope iOS must bind exactly one iOS archive');
  } else if (['universal-purchase', 'separate-records'].includes(record?.recordScope)
      && platformKey !== 'iOS,macOS') {
    blockers.push(`${record.recordScope} must bind one iOS and one macOS archive`);
  }
  if (record?.recordScope === 'universal-purchase'
      && archiveBundleIDs.length === 2
      && new Set(archiveBundleIDs).size !== 1) {
    blockers.push('universal-purchase evidence must use the same App bundle ID on iOS and macOS');
  }
  if (record?.recordScope === 'separate-records'
      && archiveBundleIDs.length === 2
      && new Set(archiveBundleIDs).size !== 2) {
    blockers.push('separate-records evidence must use different App bundle IDs on iOS and macOS');
  }

  const expectedArchiveSHA256s = [...new Set(archiveSHA256s)].sort();
  const evidence = record?.evidence && typeof record.evidence === 'object' ? record.evidence : {};
  const evidencePaths = [];
  for (const kind of requiredEvidenceKinds) {
    const item = evidence[kind];
    const label = `App Privacy evidence.${kind}`;
    const absoluteItemPath = projectFile(item?.path, label, blockers, 10 * 1024 * 1024);
    if (absoluteItemPath) evidencePaths.push(absoluteItemPath);
    const configuredSHA256 = expectedSHA256(item, label, blockers);
    const actualSHA256 = absoluteItemPath ? fileSHA256(absoluteItemPath, label, blockers) : null;
    if (configuredSHA256 && actualSHA256 && configuredSHA256 !== actualSHA256) {
      blockers.push(`${label}.sha256 does not match its evidence file`);
    }
    const boundArchiveSHA256s = Array.isArray(item?.candidateArchiveSHA256s)
      ? [...new Set(item.candidateArchiveSHA256s.map((value) => String(value).toLowerCase()))].sort()
      : [];
    if (JSON.stringify(boundArchiveSHA256s) !== JSON.stringify(expectedArchiveSHA256s)
        || expectedArchiveSHA256s.length !== archives.length) {
      blockers.push(`${label}.candidateArchiveSHA256s must exactly match every candidate archive`);
    }
    if (absoluteItemPath && expectedArchiveSHA256s.length === archives.length) {
      const evidenceText = readFileSync(absoluteItemPath, 'utf8');
      for (const digest of expectedArchiveSHA256s) {
        if (!evidenceText.toLowerCase().includes(digest)) {
          blockers.push(`${label}.path must mention candidate archive SHA-256 ${digest}`);
        }
      }
    }
  }
  if (new Set(evidencePaths).size !== requiredEvidenceKinds.length) {
    blockers.push('each required App Privacy evidence kind must use a distinct evidence file');
  }

  return {
    path: configuredPath,
    record: {
      schemaVersion: record?.schemaVersion ?? null,
      recordScope: record?.recordScope ?? null,
      reviewedAt: record?.reviewedAt ?? null,
      archives: archives.map((archive) => ({
        platform: archive?.platform ?? null,
        distribution: archive?.distribution ?? null,
        path: archive?.path ?? null,
        sha256: archive?.sha256 ?? null,
        bundleID: archive?.bundleID ?? null,
        version: archive?.version ?? null,
        build: archive?.build ?? null,
      })),
      evidenceKinds: Object.keys(evidence).sort(),
    },
    blockers,
  };
}

const releaseEvidence = validateReleaseEvidence();
releaseBlockers.push(...releaseEvidence.blockers);

const evidenceContractSelfTest = (() => {
  const sampleSHA = 'a'.repeat(64);
  const distinctSHA = 'b'.repeat(64);
  return sha256Pattern.test(sampleSHA)
    && !sha256Pattern.test('not-a-sha')
    && JSON.stringify([...new Set([sampleSHA, sampleSHA])].sort()) === JSON.stringify([sampleSHA])
    && JSON.stringify([sampleSHA].sort()) !== JSON.stringify([distinctSHA].sort());
})();
if (!evidenceContractSelfTest) {
  structuralErrors.push('App Privacy evidence contract self-test failed');
}

const result = {
  schemaVersion: 1,
  mode: releaseMode ? 'release' : 'draft',
  draftValid: structuralErrors.length === 0,
  sourcePrivacyReady: structuralErrors.length === 0,
  macOS: {
    timestampAPIUsed,
    automaticHomeScanPresent,
    securityScopedBookmarkMarkersPresent,
    sandboxAuthorizationIsSeparateGate: true,
  },
  releaseEvidence: releaseEvidence.record,
  releaseEvidencePath: releaseEvidence.path,
  releaseEvidenceReady: releaseEvidence.blockers.length === 0,
  releaseReady: structuralErrors.length === 0 && releaseBlockers.length === 0,
  validatorSelfTests: { evidenceContract: evidenceContractSelfTest },
  structuralErrors,
  releaseBlockers,
};

console.log(JSON.stringify(result, null, 2));

if (structuralErrors.length > 0 || (releaseMode && releaseBlockers.length > 0)) {
  process.exit(1);
}
