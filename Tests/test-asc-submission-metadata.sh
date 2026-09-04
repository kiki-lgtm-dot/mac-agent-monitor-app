#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"

ASC_METADATA_TEST_PROJECT_DIR="$PROJECT_DIR" node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const repositoryRoot = process.env.ASC_METADATA_TEST_PROJECT_DIR;
const base = await import(`file://${repositoryRoot}/scripts/app-store-connect-api.mjs`);
const metadata = await import(`file://${repositoryRoot}/scripts/app-store-connect-submission-metadata.mjs`);
const root = mkdtempSync(join(realpathSync(tmpdir()), "agentisland-asc-metadata-test."));
process.on("exit", () => rmSync(root, { recursive: true, force: true }));

const projectRoot = join(root, "project");
const releaseDir = join(projectRoot, ".release");
const appliedPaths = [
  "Resources/Info.plist",
  "ApplePlatforms/iOS/Config/Project.xcconfig",
  "ApplePlatforms/macOS/Config/Project.xcconfig",
];
for (const relativePath of appliedPaths) {
  mkdirSync(join(projectRoot, relativePath, ".."), { recursive: true, mode: 0o700 });
  writeFileSync(join(projectRoot, relativePath), `${relativePath} binding\n`, { mode: 0o600 });
}
mkdirSync(releaseDir, { recursive: true, mode: 0o700 });
mkdirSync(join(projectRoot, "dist"), { recursive: true, mode: 0o700 });

const bundleId = "com.acme.agentisland";
const version = "1.2.3";
const build = "45";
const appId = "1234567890";
const appInfoId = "info-123";
const versionId = "version-123";
const buildId = "build-123";
const macBuildId = "build-mac-123";
const buildUploadId = "upload-123";
const macBuildUploadId = "upload-mac-123";
const preReleaseVersionId = "pre-123";
const macPreReleaseVersionId = "pre-mac-123";
const artifactPath = join(projectRoot, "dist", "AgentIsland.ipa");
const macArtifactPath = join(projectRoot, "dist", "AgentIsland.pkg");
const identityLockPath = join(releaseDir, "identity.lock.json");
const manifestPath = join(releaseDir, "app-store-submission.json");
const buildSnapshotPath = join(releaseDir, "asc-build-snapshot.json");
const macBuildSnapshotPath = join(releaseDir, "asc-mac-build-snapshot.json");
const metadataSnapshotPath = join(releaseDir, "asc-submission-metadata.json");
const macMetadataSnapshotPath = join(releaseDir, "asc-mac-submission-metadata.json");
const now = new Date("2026-09-04T05:00:00.000Z");

writeFileSync(artifactPath, "sealed app candidate\n", { mode: 0o600 });
writeFileSync(macArtifactPath, "sealed mac package candidate\n", { mode: 0o600 });
const identityLock = {
  schemaVersion: 1,
  firstAppliedAt: "2026-09-04T00:00:00Z",
  identity: {
    schemaVersion: 2,
    appStoreRecordMode: "universal-purchase",
    macOSAppBundleIdentifier: bundleId,
    iOSAppBundleIdentifier: bundleId,
    iOSWidgetBundleIdentifier: `${bundleId}.liveactivity`,
    teamIdentifier: "AB12CD34EF",
    iCloudContainerIdentifier: "iCloud.com.acme.agentisland",
    cloudKit: {
      databaseScope: "private",
      environment: "Production",
      recordType: "AgentIslandSnapshot",
      recordName: "latest",
      payloadField: "payloadJSON",
    },
  },
  provisioningProfile: null,
  generatedEntitlements: null,
  appliedFiles: appliedPaths.map((relativePath) => ({
    path: relativePath,
    sha256: createHash("sha256").update(readFileSync(join(projectRoot, relativePath))).digest("hex"),
  })),
};
writeFileSync(identityLockPath, `${JSON.stringify(identityLock, null, 2)}\n`, { mode: 0o600 });

const appAttributes = {
  name: "MAC版灵动岛--Agent运行监测",
  bundleId,
  sku: "AGENT-ISLAND",
  primaryLocale: "zh-Hans",
  contentRightsDeclaration: "DOES_NOT_USE_THIRD_PARTY_CONTENT",
  isOrEverWasMadeForKids: false,
};
const baseApp = {
  type: "apps",
  id: appId,
  attributes: appAttributes,
};
const buildCollection = {
  data: [{
    type: "builds",
    id: buildId,
    attributes: {
      version: build,
      uploadedDate: "2026-09-04T04:50:00.000Z",
      expirationDate: "2026-12-03T04:50:00.000Z",
      expired: false,
      processingState: "VALID",
      buildAudienceType: "APP_STORE_ELIGIBLE",
      usesNonExemptEncryption: false,
    },
    relationships: {
      app: { data: { type: "apps", id: appId } },
      preReleaseVersion: { data: { type: "preReleaseVersions", id: preReleaseVersionId } },
      buildUpload: { data: { type: "buildUploads", id: buildUploadId } },
    },
  }],
  included: [
    baseApp,
    {
      type: "preReleaseVersions",
      id: preReleaseVersionId,
      attributes: { version, platform: "IOS" },
      relationships: { app: { data: { type: "apps", id: appId } } },
    },
    {
      type: "buildUploads",
      id: buildUploadId,
      attributes: {
        cfBundleShortVersionString: version,
        cfBundleVersion: build,
        platform: "IOS",
        createdDate: "2026-09-04T04:40:00.000Z",
        uploadedDate: "2026-09-04T04:50:00.000Z",
        state: { state: "COMPLETE", errors: [], warnings: [], infos: [] },
      },
      relationships: { build: { data: { type: "builds", id: buildId } } },
    },
  ],
  links: { next: null },
};
const baseClient = {
  getCollection: async (path) => {
    if (path === "/v1/apps") {
      return { data: [baseApp], included: [], requests: [request(path, {})] };
    }
    if (path === "/v1/builds") {
      return { ...buildCollection, requests: [request(path, {})] };
    }
    throw new Error(`unexpected base route ${path}`);
  },
};
const buildSnapshot = await base.captureBuildSnapshot({
  client: baseClient,
  bundleId,
  platform: "IOS",
  version,
  build,
  artifactPath,
  identityLockPath,
  projectRoot,
  now,
});
base.writeImmutableSnapshot(buildSnapshotPath, buildSnapshot);
const macBuildCollection = structuredClone(buildCollection);
macBuildCollection.data[0].id = macBuildId;
macBuildCollection.data[0].relationships.preReleaseVersion.data.id = macPreReleaseVersionId;
macBuildCollection.data[0].relationships.buildUpload.data.id = macBuildUploadId;
const macPreRelease = macBuildCollection.included.find((item) => item.type === "preReleaseVersions");
macPreRelease.id = macPreReleaseVersionId;
macPreRelease.attributes.platform = "MAC_OS";
const macUpload = macBuildCollection.included.find((item) => item.type === "buildUploads");
macUpload.id = macBuildUploadId;
macUpload.attributes.platform = "MAC_OS";
macUpload.relationships.build.data.id = macBuildId;
const macBaseClient = {
  getCollection: async (path) => {
    if (path === "/v1/apps") {
      return { data: [baseApp], included: [], requests: [request(path, {})] };
    }
    if (path === "/v1/builds") {
      return { ...macBuildCollection, requests: [request(path, {})] };
    }
    throw new Error(`unexpected mac base route ${path}`);
  },
};
const macBuildSnapshot = await base.captureBuildSnapshot({
  client: macBaseClient,
  bundleId,
  platform: "MAC_OS",
  version,
  build,
  artifactPath: macArtifactPath,
  identityLockPath,
  projectRoot,
  now,
});
base.writeImmutableSnapshot(macBuildSnapshotPath, macBuildSnapshot);

function localization(locale) {
  const chinese = locale === "zh-Hans";
  return {
    locale,
    name: "MAC版灵动岛--Agent运行监测",
    subtitle: chinese ? "Mac AI Agent 运行看板" : "AI Agent Monitor for Mac",
    promotionalText: chinese ? "中文推广文本" : "English promotional text",
    description: chinese ? "中文说明" : "English description",
    keywords: chinese ? "智能体,监测" : "agent,monitor",
    whatsNew: null,
    privacyPolicyURL: "https://example.acme/privacy/",
    supportURL: "https://example.acme/support/",
    marketingURL: null,
  };
}

function testFlightLocalization(locale) {
  return {
    locale,
    betaAppDescription: locale === "zh-Hans" ? "中文测试说明" : "English beta description",
    whatToTest: locale === "zh-Hans" ? "测试中文流程" : "Test the English flow",
  };
}

const review = {
  contact: { firstName: "Review", lastName: "Owner", email: "review@acme.test", phone: "+8613812345678" },
  login: {
    strategy: "review-account",
    credentialsSecretReference: "keychain://agentisland/review-account",
    instructions: "Use the private review account reference.",
  },
  notes: "Use the bundled offline example.",
};
const commerce = {
  madeForKids: false,
  contentRights: { status: "does-not-use-third-party-content", notes: "Owned content." },
  exportCompliance: { usesNonExemptEncryption: false, status: "exempt", documentationReference: null },
  ageRating: { questionnaireStatus: "complete", declaredRating: "4+" },
  eula: { type: "apple-standard", customText: null, territories: [] },
  digitalServicesAct: { traderStatus: "non-trader", verificationStatus: "not-required" },
  pricing: { model: "free", pricePointReference: null, taxCategory: "APP", availableTerritories: ["CHN"] },
};
const record = {
  appResourceId: appId,
  bundleIdentifier: bundleId,
  widgetBundleIdentifier: `${bundleId}.liveactivity`,
  sku: "AGENT-ISLAND",
  primaryLocale: "zh-Hans",
  version: {
    versionString: version,
    buildNumber: build,
    releaseKind: "initial",
    releaseMode: "manual",
    scheduledReleaseAt: null,
    copyright: "2026 Acme",
  },
  categories: { primary: "developer-tools", secondary: "productivity" },
  commerce,
  review,
  localizations: [localization("zh-Hans"), localization("en-US")],
  screenshotSets: [
    { locale: "zh-Hans", device: "iPhone", orderedPaths: ["docs/ios-zh.png"] },
    { locale: "en-US", device: "iPhone", orderedPaths: ["docs/ios-en.png"] },
  ],
  testFlight: {
    distribution: "external",
    feedbackEmail: "feedback@acme.test",
    betaReviewContact: review.contact,
    betaReviewNotes: "Verify the offline example, private sync, title hiding, and account isolation.",
    login: review.login,
    localizations: [testFlightLocalization("zh-Hans"), testFlightLocalization("en-US")],
  },
};
const { widgetBundleIdentifier: _widget, testFlight: _testFlight, ...macRecord } = record;
macRecord.screenshotSets = [
  { locale: "zh-Hans", device: "macOS", orderedPaths: ["docs/mac-zh.png"] },
  { locale: "en-US", device: "macOS", orderedPaths: ["docs/mac-en.png"] },
];
const manifest = {
  schemaVersion: 1,
  productName: "MAC版灵动岛--Agent运行监测",
  recordMode: "universal-purchase",
  identityLockSHA256: createHash("sha256").update(readFileSync(identityLockPath)).digest("hex"),
  screenshotEvidencePath: ".release/store-screenshot-evidence.json",
  screenshotEvidenceSHA256: "a".repeat(64),
  records: {
    macos: macRecord,
    ios: record,
  },
};
writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o444 });
chmodSync(manifestPath, 0o444);

const infoLocIds = { "zh-Hans": "info-zh", "en-US": "info-en" };
const versionLocIds = { "zh-Hans": "version-zh", "en-US": "version-en" };
const betaAppLocIds = { "zh-Hans": "beta-app-zh", "en-US": "beta-app-en" };
const betaBuildLocIds = { "zh-Hans": "beta-build-zh", "en-US": "beta-build-en" };
const reviewId = "review-123";
const betaReviewId = "beta-review-123";

function request(path, query) {
  const search = new URLSearchParams(Object.entries(query ?? {})).toString();
  return {
    method: "GET",
    pathAndQuery: `${path}${search ? `?${search}` : ""}`,
    status: 200,
    responseBytes: 2,
    responseSHA256: createHash("sha256").update("{}").digest("hex"),
  };
}

function remoteFixtures({
  englishDescription = "English description",
  duplicateBetaLocale = false,
  includeReplacedAppInfo = false,
  duplicateActiveAppInfo = false,
  platform = "IOS",
} = {}) {
  const selectedBuildId = platform === "MAC_OS" ? macBuildId : buildId;
  const infoLocalizations = ["zh-Hans", "en-US"].map((locale) => ({
    type: "appInfoLocalizations",
    id: infoLocIds[locale],
    attributes: {
      locale,
      name: localization(locale).name,
      subtitle: localization(locale).subtitle,
      privacyPolicyUrl: localization(locale).privacyPolicyURL,
      privacyChoicesUrl: null,
      privacyPolicyText: null,
    },
    relationships: { appInfo: { data: { type: "appInfos", id: appInfoId } } },
  }));
  const versionLocalizations = ["zh-Hans", "en-US"].map((locale) => ({
    type: "appStoreVersionLocalizations",
    id: versionLocIds[locale],
    attributes: {
      locale,
      description: locale === "en-US" ? englishDescription : localization(locale).description,
      keywords: localization(locale).keywords,
      marketingUrl: localization(locale).marketingURL,
      promotionalText: localization(locale).promotionalText,
      supportUrl: localization(locale).supportURL,
      whatsNew: localization(locale).whatsNew,
    },
    relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: versionId } } },
  }));
  const commonReviewAttributes = {
    contactFirstName: review.contact.firstName,
    contactLastName: review.contact.lastName,
    contactPhone: review.contact.phone,
    contactEmail: review.contact.email,
    demoAccountName: "reviewer@example.acme",
    demoAccountPassword: "SECRET-DEMO-PASSWORD",
    demoAccountRequired: true,
  };
  const appStoreReviewAttributes = {
    ...commonReviewAttributes,
    notes: review.notes,
  };
  const betaReviewAttributes = {
    ...commonReviewAttributes,
    notes: record.testFlight.betaReviewNotes,
  };
  const app = {
    ...baseApp,
    relationships: { betaAppReviewDetail: { data: { type: "betaAppReviewDetails", id: betaReviewId } } },
  };
  const appInfo = {
    type: "appInfos",
    id: appInfoId,
    attributes: { appStoreState: "PREPARE_FOR_SUBMISSION", state: "PREPARE_FOR_SUBMISSION" },
    relationships: {
      app: { data: { type: "apps", id: appId } },
      appInfoLocalizations: {
        data: infoLocalizations.map((item) => ({ type: item.type, id: item.id })),
      },
      primaryCategory: { data: { type: "appCategories", id: "DEVELOPER_TOOLS" } },
      secondaryCategory: { data: { type: "appCategories", id: "PRODUCTIVITY" } },
    },
  };
  const appVersion = {
    type: "appStoreVersions",
    id: versionId,
    attributes: {
      platform,
      versionString: version,
      appStoreState: "PREPARE_FOR_SUBMISSION",
      appVersionState: "PREPARE_FOR_SUBMISSION",
      reviewType: "APP_STORE",
      copyright: "2026 Acme",
      releaseType: "MANUAL",
      earliestReleaseDate: null,
    },
    relationships: {
      app: { data: { type: "apps", id: appId } },
      appStoreVersionLocalizations: {
        data: versionLocalizations.map((item) => ({ type: item.type, id: item.id })),
      },
      appStoreReviewDetail: { data: { type: "appStoreReviewDetails", id: reviewId } },
      build: { data: { type: "builds", id: selectedBuildId } },
    },
  };
  const appInfoData = [appInfo];
  if (includeReplacedAppInfo) {
    appInfoData.unshift({
      ...appInfo,
      id: "info-replaced",
      attributes: { ...appInfo.attributes, state: "REPLACED_WITH_NEW_INFO" },
    });
  }
  if (duplicateActiveAppInfo) {
    appInfoData.push({ ...appInfo, id: "info-active-duplicate" });
  }
  const betaAppLocalizations = ["zh-Hans", "en-US"].map((locale) => ({
    type: "betaAppLocalizations",
    id: betaAppLocIds[locale],
    attributes: {
      locale,
      feedbackEmail: record.testFlight.feedbackEmail,
      description: testFlightLocalization(locale).betaAppDescription,
      marketingUrl: null,
      privacyPolicyUrl: localization(locale).privacyPolicyURL,
      tvOsPrivacyPolicy: null,
    },
    relationships: { app: { data: { type: "apps", id: appId } } },
  }));
  if (duplicateBetaLocale) {
    betaAppLocalizations.push({
      ...betaAppLocalizations[0],
      id: "duplicate-beta-app-zh",
    });
  }
  const betaBuildLocalizations = ["zh-Hans", "en-US"].map((locale) => ({
    type: "betaBuildLocalizations",
    id: betaBuildLocIds[locale],
    attributes: { locale, whatsNew: testFlightLocalization(locale).whatToTest },
    relationships: { build: { data: { type: "builds", id: selectedBuildId } } },
  }));
  return {
    apps: { data: [app], included: [{
      type: "betaAppReviewDetails",
      id: betaReviewId,
      attributes: betaReviewAttributes,
      relationships: { app: { data: { type: "apps", id: appId } } },
    }] },
    appInfos: {
      data: appInfoData,
      included: [
        { type: "appCategories", id: "DEVELOPER_TOOLS", attributes: { platforms: ["IOS", "MAC_OS"] } },
        { type: "appCategories", id: "PRODUCTIVITY", attributes: { platforms: ["IOS", "MAC_OS"] } },
      ],
    },
    infoLocalizations: { data: infoLocalizations, included: [] },
    versions: {
      data: [appVersion],
      included: [
        {
          type: "appStoreReviewDetails",
          id: reviewId,
          attributes: appStoreReviewAttributes,
          relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: versionId } } },
        },
        {
          type: "builds",
          id: selectedBuildId,
          attributes: { version: build, usesNonExemptEncryption: false },
          relationships: { app: { data: { type: "apps", id: appId } } },
        },
      ],
    },
    versionLocalizations: { data: versionLocalizations, included: [] },
    betaApps: { data: betaAppLocalizations, included: [] },
    betaBuilds: { data: betaBuildLocalizations, included: [] },
  };
}

function fixtureClient(options = {}) {
  const fixtures = remoteFixtures(options);
  const calls = [];
  return {
    calls,
    fixtures,
    client: {
      getCollection: async (path, query) => {
        calls.push({ path, query });
        let response;
        if (path === "/v1/apps") response = fixtures.apps;
        else if (path === `/v1/apps/${appId}/appInfos`) response = fixtures.appInfos;
        else if (path === `/v1/appInfos/${appInfoId}/appInfoLocalizations`) response = fixtures.infoLocalizations;
        else if (path === `/v1/apps/${appId}/appStoreVersions`) response = fixtures.versions;
        else if (path === `/v1/appStoreVersions/${versionId}/appStoreVersionLocalizations`) response = fixtures.versionLocalizations;
        else if (path === `/v1/apps/${appId}/betaAppLocalizations`) response = fixtures.betaApps;
        else if (path === `/v1/builds/${buildId}/betaBuildLocalizations`) response = fixtures.betaBuilds;
        else throw new Error(`unexpected metadata route ${path}`);
        return { ...response, requests: [request(path, query)] };
      },
    },
  };
}

function writeLockedJSON(path, value, mode = 0o444) {
  try { chmodSync(path, 0o600); } catch {}
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  chmodSync(path, mode);
}

function verificationOptions(overrides = {}) {
  return {
    ...captureOptions(null),
    now: new Date(now.getTime() + 5_000),
    ...overrides,
  };
}

function captureOptions(client, overrides = {}) {
  return {
    client,
    manifestPath,
    buildSnapshotPath,
    bundleId,
    platform: "iOS",
    version,
    build,
    artifactPath,
    identityLockPath,
    projectRoot,
    now,
    ...overrides,
  };
}

async function expectCode(action, code) {
  let caught;
  try {
    await action();
  } catch (error) {
    caught = error;
  }
  assert(caught instanceof base.AscSnapshotError, `expected ${code}, received ${caught}`);
  assert.equal(caught.code, code);
}

// A fully matching API-visible subset is useful evidence, while the coverage
// contract truthfully keeps the overall remote comparison incomplete.
let validSnapshot;
{
  const { client, calls } = fixtureClient();
  validSnapshot = await metadata.captureSubmissionMetadataSnapshot(captureOptions(client));
  assert.deepEqual(calls.map((call) => call.path), [
    "/v1/apps",
    `/v1/apps/${appId}/appInfos`,
    `/v1/appInfos/${appInfoId}/appInfoLocalizations`,
    `/v1/apps/${appId}/appStoreVersions`,
    `/v1/appStoreVersions/${versionId}/appStoreVersionLocalizations`,
    `/v1/apps/${appId}/betaAppLocalizations`,
    `/v1/builds/${buildId}/betaBuildLocalizations`,
  ]);
  assert.equal(validSnapshot.kind, metadata.SUBMISSION_METADATA_KIND);
  assert.equal(validSnapshot.readiness.apiComparableMetadataMatches, true);
  assert.equal(validSnapshot.readiness.apiVisibleMetadataEvidenceReady, true);
  assert.equal(validSnapshot.readiness.remoteMetadataComparisonComplete, false);
  assert.equal(validSnapshot.coverage.everyRequiredFieldVerified, false);
  assert.equal(validSnapshot.coverage.remoteMetadataComparisonComplete, false);
  assert(validSnapshot.coverage.manualOrUnsupported.length > 0);
  assert(validSnapshot.coverage.apiComparedPaths.includes("records.ios.localizations[zh-Hans].description"));
  assert(validSnapshot.coverage.apiComparedPaths.includes("records.ios.testFlight.localizations[en-US].whatToTest"));
  assert(validSnapshot.coverage.apiComparedPaths.includes("records.ios.testFlight.betaReviewNotes"));
  assert.equal(JSON.stringify(validSnapshot).includes("demoAccountPassword\":\""), false);
  assert.equal(JSON.stringify(validSnapshot).includes("SECRET-DEMO-PASSWORD"), false);
  assert.equal(JSON.stringify(validSnapshot).includes(review.contact.email), false);
  assert.equal(JSON.stringify(validSnapshot).includes(review.contact.phone), false);
  assert.equal(JSON.stringify(validSnapshot).includes(review.notes), false);
  assert.equal(JSON.stringify(validSnapshot).includes(record.testFlight.betaReviewNotes), false);
  base.writeImmutableSnapshot(metadataSnapshotPath, validSnapshot);
  const verified = metadata.verifySubmissionMetadataSnapshotFile(metadataSnapshotPath, {
    ...captureOptions(null),
    now: new Date(now.getTime() + 5_000),
  });
  assert.equal(verified.verified, true);
  assert.equal(verified.readiness.apiVisibleMetadataEvidenceReady, true);
  assert.equal(verified.readiness.remoteMetadataComparisonComplete, false);
}

// Beta App Review notes are API-visible release metadata. Compare them while
// persisting only a redacted Boolean result.
{
  const { client, fixtures } = fixtureClient();
  const betaReviewResource = fixtures.apps.included.find((item) => item.type === "betaAppReviewDetails");
  betaReviewResource.attributes.notes = "Remote Beta review note drift";
  const snapshot = await metadata.captureSubmissionMetadataSnapshot(captureOptions(client));
  assert.equal(snapshot.readiness.apiVisibleMetadataEvidenceReady, false);
  const mismatch = snapshot.comparisons.find((entry) =>
    entry.path === "records.ios.testFlight.betaReviewNotes");
  assert.equal(mismatch.matches, false);
  assert.equal(JSON.stringify(snapshot).includes("Remote Beta review note drift"), false);
}

// Initial releases model App Store "What's New" as unavailable. Updates must
// instead provide and exactly match non-empty release notes.
{
  const updatedManifest = structuredClone(manifest);
  for (const platformRecord of [updatedManifest.records.macos, updatedManifest.records.ios]) {
    platformRecord.version.releaseKind = "update";
    for (const item of platformRecord.localizations) {
      item.whatsNew = item.locale === "zh-Hans" ? "本次更新说明" : "Update release notes";
    }
  }
  writeLockedJSON(manifestPath, updatedManifest);
  const { client, fixtures } = fixtureClient();
  for (const item of fixtures.versionLocalizations.data) {
    item.attributes.whatsNew = item.attributes.locale === "zh-Hans" ? "本次更新说明" : "Update release notes";
  }
  const updateSnapshot = await metadata.captureSubmissionMetadataSnapshot(captureOptions(client));
  assert.equal(updateSnapshot.readiness.apiVisibleMetadataEvidenceReady, true);
  assert(updateSnapshot.comparisons.some((entry) =>
    entry.path === "records.ios.version.releaseKind" && entry.matches));
  writeLockedJSON(manifestPath, manifest);
}

// A lifetime made-for-kids history of true is inconclusive for a current false
// declaration and therefore does not falsely fail the API-comparable subset.
{
  const { client, fixtures } = fixtureClient();
  fixtures.apps.data[0].attributes = {
    ...fixtures.apps.data[0].attributes,
    isOrEverWasMadeForKids: true,
  };
  const snapshot = await metadata.captureSubmissionMetadataSnapshot(captureOptions(client));
  assert.equal(snapshot.readiness.apiVisibleMetadataEvidenceReady, true);
  assert(snapshot.coverage.manualOrUnsupported.some((entry) =>
    entry.path === "records.ios.commerce.madeForKids"));
}

// Nullable review completeness is a valid ASC response: preserve it as a
// mismatch instead of misclassifying the response as malformed.
{
  const { client, fixtures } = fixtureClient();
  const reviewResource = fixtures.versions.included.find((item) => item.type === "appStoreReviewDetails");
  reviewResource.attributes.demoAccountRequired = null;
  const snapshot = await metadata.captureSubmissionMetadataSnapshot(captureOptions(client));
  assert.equal(snapshot.readiness.apiVisibleMetadataEvidenceReady, false);
  assert(snapshot.comparisons.some((entry) =>
    entry.path === "records.ios.review.login.accountRequired" && !entry.matches));
}

// Category IDs use an explicit Apple-ID-to-manifest mapping rather than a
// lossy underscore replacement.
{
  const foodManifest = structuredClone(manifest);
  foodManifest.records.ios.categories.primary = "food-drink";
  writeLockedJSON(manifestPath, foodManifest);
  const { client, fixtures } = fixtureClient();
  fixtures.appInfos.data[0].relationships.primaryCategory.data.id = "FOOD_AND_DRINK";
  fixtures.appInfos.included = fixtures.appInfos.included.filter((item) => item.id !== "DEVELOPER_TOOLS");
  fixtures.appInfos.included.push({
    type: "appCategories", id: "FOOD_AND_DRINK", attributes: { platforms: ["IOS"] },
  });
  const snapshot = await metadata.captureSubmissionMetadataSnapshot(captureOptions(client));
  assert.equal(snapshot.readiness.apiVisibleMetadataEvidenceReady, true);
  writeLockedJSON(manifestPath, manifest);
}

// Every localization endpoint is paginated independently and must expose the
// exact two-locale contract. An undeclared extra locale is never ignored.
for (const target of ["infoLocalizations", "versionLocalizations", "betaApps", "betaBuilds"]) {
  const { client, fixtures } = fixtureClient();
  const collection = fixtures[target];
  const extra = structuredClone(collection.data[0]);
  extra.id = `${target}-fr`;
  extra.attributes.locale = "fr-FR";
  collection.data.push(extra);
  await expectCode(() => metadata.captureSubmissionMetadataSnapshot(captureOptions(client)),
    "ASC_RESPONSE_INVALID");
}

// Reverse JSON:API relationships bind every included or related resource to
// the exact App/AppInfo/version selected by the sealed Build evidence.
{
  const { client, fixtures } = fixtureClient();
  fixtures.infoLocalizations.data[0].relationships.appInfo.data.id = "different-info";
  await expectCode(() => metadata.captureSubmissionMetadataSnapshot(captureOptions(client)),
    "ASC_RESPONSE_DRIFT");
}
{
  const { client, fixtures } = fixtureClient();
  const reviewResource = fixtures.versions.included.find((item) => item.type === "appStoreReviewDetails");
  reviewResource.relationships.appStoreVersion.data.id = "different-version";
  await expectCode(() => metadata.captureSubmissionMetadataSnapshot(captureOptions(client)),
    "ASC_RESPONSE_DRIFT");
}

// The APP_STORE review resource and pre-selection lifecycle are explicit; a
// notarization version or an already-submitted version cannot qualify.
{
  const { client, fixtures } = fixtureClient();
  fixtures.versions.data[0].attributes.reviewType = "NOTARIZATION";
  await expectCode(() => metadata.captureSubmissionMetadataSnapshot(captureOptions(client)),
    "ASC_METADATA_NOT_UNIQUE");
}
{
  const { client, fixtures } = fixtureClient();
  fixtures.versions.data[0].attributes.appVersionState = "WAITING_FOR_REVIEW";
  await expectCode(() => metadata.captureSubmissionMetadataSnapshot(captureOptions(client)),
    "ASC_VERSION_STATE_UNSAFE");
}

// Internal-only TestFlight does not require or claim Beta App Review evidence.
{
  const internalManifest = structuredClone(manifest);
  internalManifest.records.ios.testFlight.distribution = "internal-only";
  writeLockedJSON(manifestPath, internalManifest);
  const { client, calls } = fixtureClient();
  const snapshot = await metadata.captureSubmissionMetadataSnapshot(captureOptions(client));
  assert.equal(snapshot.remote.testFlight.appLocalizations, null);
  assert.equal(snapshot.remote.testFlight.review, null);
  assert.equal(calls.some((call) => call.path.includes("betaAppLocalizations")), false);
  assert.equal(calls.some((call) => call.path.includes("betaBuildLocalizations")), true);
  assert(snapshot.coverage.apiComparedPaths.includes(
    "records.ios.testFlight.localizations[en-US].whatToTest"));
  assert.equal(snapshot.requestEvidence.some((entry) => entry.pathAndQuery.includes("betaAppReviewDetail")), false);
  writeLockedJSON(manifestPath, manifest);
}

// The same snapshot contract covers the macOS record without pretending that
// iOS-only TestFlight resources exist.
{
  const { client, calls } = fixtureClient({ platform: "MAC_OS" });
  const snapshot = await metadata.captureSubmissionMetadataSnapshot(captureOptions(client, {
    platform: "macOS",
    buildSnapshotPath: macBuildSnapshotPath,
    artifactPath: macArtifactPath,
  }));
  assert.deepEqual(calls.map((call) => call.path), [
    "/v1/apps",
    `/v1/apps/${appId}/appInfos`,
    `/v1/appInfos/${appInfoId}/appInfoLocalizations`,
    `/v1/apps/${appId}/appStoreVersions`,
    `/v1/appStoreVersions/${versionId}/appStoreVersionLocalizations`,
  ]);
  assert.equal(snapshot.query.platform, "MAC_OS");
  assert.equal(snapshot.remote.testFlight, null);
  assert.equal(snapshot.readiness.apiVisibleMetadataEvidenceReady, true);
  assert.equal(snapshot.readiness.remoteMetadataComparisonComplete, false);
  base.writeImmutableSnapshot(macMetadataSnapshotPath, snapshot);
  const verified = metadata.verifySubmissionMetadataSnapshotFile(macMetadataSnapshotPath, {
    ...captureOptions(null),
    platform: "macOS",
    buildSnapshotPath: macBuildSnapshotPath,
    artifactPath: macArtifactPath,
    now: new Date(now.getTime() + 5_000),
  });
  assert.equal(verified.verified, true);
  assert.equal(statSync(macMetadataSnapshotPath).mode & 0o777, 0o444);
}

// A remote mismatch is preserved as a diagnostic snapshot and cannot pass the
// API-visible evidence gate.
{
  const { client } = fixtureClient({ englishDescription: "Remote drift" });
  const snapshot = await metadata.captureSubmissionMetadataSnapshot(captureOptions(client));
  assert.equal(snapshot.readiness.apiComparableMetadataMatches, false);
  assert.equal(snapshot.readiness.apiVisibleMetadataEvidenceReady, false);
  const mismatch = snapshot.comparisons.find((entry) =>
    entry.path === "records.ios.localizations[en-US].description");
  assert.equal(mismatch.matches, false);
  assert.equal(mismatch.actual, "Remote drift");
}

// Locale ambiguity fails closed instead of silently selecting one resource.
{
  const { client } = fixtureClient({ duplicateBetaLocale: true });
  await expectCode(() => metadata.captureSubmissionMetadataSnapshot(captureOptions(client)),
    "ASC_RESPONSE_INVALID");
}

// Historical App Info is ignored by an explicit state rule; two current
// records are rejected as ambiguous.
{
  const { client } = fixtureClient({ includeReplacedAppInfo: true });
  const snapshot = await metadata.captureSubmissionMetadataSnapshot(captureOptions(client));
  assert.equal(snapshot.remote.appInfo.resourceID, appInfoId);
}
{
  const { client, fixtures } = fixtureClient();
  const live = structuredClone(fixtures.appInfos.data[0]);
  live.id = "info-current-live";
  live.attributes.state = "READY_FOR_DISTRIBUTION";
  fixtures.appInfos.data.unshift(live);
  const snapshot = await metadata.captureSubmissionMetadataSnapshot(captureOptions(client));
  assert.equal(snapshot.remote.appInfo.resourceID, appInfoId);
}
{
  const { client, fixtures } = fixtureClient();
  fixtures.appInfos.data[0].attributes.state = "FUTURE_UNKNOWN_STATE";
  await expectCode(() => metadata.captureSubmissionMetadataSnapshot(captureOptions(client)),
    "ASC_RESPONSE_INVALID");
}
{
  const { client } = fixtureClient({ duplicateActiveAppInfo: true });
  await expectCode(() => metadata.captureSubmissionMetadataSnapshot(captureOptions(client)),
    "ASC_METADATA_NOT_UNIQUE");
}

// Even a self-consistently resealed snapshot cannot claim complete remote
// coverage while manual fields remain in the contract.
{
  const forged = structuredClone(validSnapshot);
  delete forged.evidenceSHA256;
  forged.readiness.remoteMetadataComparisonComplete = true;
  const forgedPath = join(releaseDir, "forged-complete-metadata.json");
  base.writeImmutableSnapshot(forgedPath, base.sealSnapshot(forged));
  await expectCode(() => Promise.resolve(metadata.verifySubmissionMetadataSnapshotFile(forgedPath, {
    ...captureOptions(null),
    now,
  })), "SNAPSHOT_INVALID");
}

// Evidence is time-bounded and the immutable Build snapshot remains part of
// every offline verification.
await expectCode(() => Promise.resolve(metadata.verifySubmissionMetadataSnapshotFile(metadataSnapshotPath, {
  ...captureOptions(null),
  now: new Date(now.getTime() + 901_000),
})), "SNAPSHOT_EXPIRED");

// Time boundaries are inclusive, while a 61-second future capture and a
// caller-selected shorter freshness window fail closed.
assert.equal(metadata.verifySubmissionMetadataSnapshotFile(metadataSnapshotPath, {
  ...captureOptions(null), now: new Date(now.getTime() + 900_000),
}).verified, true);
assert.equal(metadata.verifySubmissionMetadataSnapshotFile(metadataSnapshotPath, {
  ...captureOptions(null), now: new Date(now.getTime() - 60_000),
}).verified, true);
await expectCode(() => Promise.resolve(metadata.verifySubmissionMetadataSnapshotFile(metadataSnapshotPath, {
  ...captureOptions(null), now: new Date(now.getTime() - 60_001),
})), "SNAPSHOT_NOT_YET_VALID");
assert.equal(metadata.verifySubmissionMetadataSnapshotFile(metadataSnapshotPath, {
  ...captureOptions(null), now: new Date(now.getTime() + 5_000), maxAgeSeconds: 5,
}).verified, true);
await expectCode(() => Promise.resolve(metadata.verifySubmissionMetadataSnapshotFile(metadataSnapshotPath, {
  ...captureOptions(null), now: new Date(now.getTime() + 5_001), maxAgeSeconds: 5,
})), "SNAPSHOT_EXPIRED");

// Offline verification rejects permission drift, byte tampering, duplicate
// JSON members, self-resealed duplicate locales, platform drift, and request
// evidence that is not the exact GET-only endpoint/query set.
{
  const path = join(releaseDir, "metadata-writable.json");
  writeLockedJSON(path, validSnapshot, 0o644);
  await expectCode(() => Promise.resolve(metadata.verifySubmissionMetadataSnapshotFile(path,
    verificationOptions())), "SNAPSHOT_PERMISSIONS_INVALID");
}
{
  const path = join(releaseDir, "metadata-tampered.json");
  const tampered = JSON.stringify(validSnapshot, null, 2).replace(
    "MAC版灵动岛--Agent运行监测", "MAC版灵动岛--Agent运行监测-篡改");
  writeFileSync(path, `${tampered}\n`, { mode: 0o600 });
  chmodSync(path, 0o444);
  await expectCode(() => Promise.resolve(metadata.verifySubmissionMetadataSnapshotFile(path,
    verificationOptions())), "SNAPSHOT_TAMPERED");
}
{
  const path = join(releaseDir, "metadata-duplicate-key.json");
  const duplicate = JSON.stringify(validSnapshot).replace("{", '{"readOnly":true,');
  writeFileSync(path, duplicate, { mode: 0o600 });
  chmodSync(path, 0o444);
  await expectCode(() => Promise.resolve(metadata.verifySubmissionMetadataSnapshotFile(path,
    verificationOptions())), "SNAPSHOT_INVALID");
}
for (const mutation of [
  (snapshot) => snapshot.remote.appInfo.localizations.push(
    structuredClone(snapshot.remote.appInfo.localizations[0])),
  (snapshot) => { snapshot.remote.appStoreVersion.platform = "MAC_OS"; },
  (snapshot) => { snapshot.requestEvidence[0].pathAndQuery = "/v1/apps?limit=200"; },
]) {
  const forged = structuredClone(validSnapshot);
  mutation(forged);
  delete forged.evidenceSHA256;
  const path = join(releaseDir, `metadata-resealed-${Math.random().toString(16).slice(2)}.json`);
  base.writeImmutableSnapshot(path, base.sealSnapshot(forged));
  await expectCode(() => Promise.resolve(metadata.verifySubmissionMetadataSnapshotFile(path,
    verificationOptions())), "SNAPSHOT_INVALID");
}

// The snapshot is actually published read-only, and the public CLI can perform
// a successful offline verification against an explicit canonical project root.
assert.equal(statSync(metadataSnapshotPath).mode & 0o777, 0o444);
{
  const preloadPath = join(root, "fixed-clock.cjs");
  const verifyTime = new Date(now.getTime() + 5_000).toISOString();
  writeFileSync(preloadPath, `const NativeDate = Date; const fixed = NativeDate.parse(${JSON.stringify(verifyTime)});\n` +
    "global.Date = class extends NativeDate { constructor(...args) { super(...(args.length ? args : [fixed])); } static now() { return fixed; } };\n");
  const command = spawnSync(process.execPath, [
    `${repositoryRoot}/scripts/capture-asc-submission-metadata.mjs`,
    "--verify", metadataSnapshotPath,
    "--manifest", manifestPath,
    "--build-snapshot", buildSnapshotPath,
    "--bundle-id", bundleId,
    "--platform", "iOS",
    "--version", version,
    "--build", build,
    "--artifact", artifactPath,
    "--identity-lock", identityLockPath,
    "--project-root", projectRoot,
  ], { encoding: "utf8", env: { ...process.env, NODE_OPTIONS: `--require=${preloadPath}` } });
  assert.equal(command.status, 0, command.stderr);
  assert.match(command.stdout, /"verified": true/);
  for (const secret of ["SECRET-DEMO-PASSWORD", review.contact.email, review.contact.phone, review.notes,
    record.testFlight.betaReviewNotes,
    review.login.credentialsSecretReference]) {
    assert.equal(command.stdout.includes(secret), false);
    assert.equal(command.stderr.includes(secret), false);
  }
}

// The snapshot layer independently rejects unknown/missing manifest fields;
// it never treats an absent value and an absent remote value as a match.
{
  const invalidManifest = structuredClone(manifest);
  invalidManifest.records.ios.version.unexpected = "must fail closed";
  chmodSync(manifestPath, 0o600);
  writeFileSync(manifestPath, `${JSON.stringify(invalidManifest, null, 2)}\n`);
  chmodSync(manifestPath, 0o444);
  const { client } = fixtureClient();
  await expectCode(() => metadata.captureSubmissionMetadataSnapshot(captureOptions(client)),
    "MANIFEST_INVALID");
  chmodSync(manifestPath, 0o600);
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  chmodSync(manifestPath, 0o444);
}

// Strict manifest parsing, permissions, and immutable bindings are checked
// before any App Store Connect request is allowed to run.
{
  const duplicateManifestPath = manifestPath;
  chmodSync(duplicateManifestPath, 0o600);
  const duplicate = JSON.stringify(manifest).replace("{", '{"schemaVersion":1,');
  writeFileSync(duplicateManifestPath, duplicate);
  chmodSync(duplicateManifestPath, 0o444);
  const { client, calls } = fixtureClient();
  await expectCode(() => metadata.captureSubmissionMetadataSnapshot(captureOptions(client)),
    "MANIFEST_INVALID");
  assert.equal(calls.length, 0);
  writeLockedJSON(manifestPath, manifest);
}
{
  chmodSync(manifestPath, 0o644);
  const { client, calls } = fixtureClient();
  await expectCode(() => metadata.captureSubmissionMetadataSnapshot(captureOptions(client)),
    "MANIFEST_PERMISSIONS_INVALID");
  assert.equal(calls.length, 0);
  chmodSync(manifestPath, 0o444);
}
{
  const driftedManifest = structuredClone(manifest);
  driftedManifest.records.ios.review.notes = "A valid but different review note.";
  writeLockedJSON(manifestPath, driftedManifest);
  await expectCode(() => Promise.resolve(metadata.verifySubmissionMetadataSnapshotFile(metadataSnapshotPath,
    verificationOptions())), "SNAPSHOT_BINDING_MISMATCH");
  writeLockedJSON(manifestPath, manifest);
}
{
  const copiedBuildSnapshotPath = join(releaseDir, "copied-build-snapshot.json");
  writeFileSync(copiedBuildSnapshotPath, readFileSync(buildSnapshotPath), { mode: 0o600 });
  chmodSync(copiedBuildSnapshotPath, 0o444);
  await expectCode(() => Promise.resolve(metadata.verifySubmissionMetadataSnapshotFile(metadataSnapshotPath,
    verificationOptions({ buildSnapshotPath: copiedBuildSnapshotPath }))), "SNAPSHOT_BINDING_MISMATCH");
}
{
  const { client, fixtures } = fixtureClient();
  fixtures.apps.data[0].id = "..";
  await expectCode(() => metadata.captureSubmissionMetadataSnapshot(captureOptions(client)),
    "ASC_RESPONSE_INVALID");
}

// The CLI help documents capture versus offline verification without touching
// credentials or the network.
{
  const command = spawnSync(process.execPath, [
    `${repositoryRoot}/scripts/capture-asc-submission-metadata.mjs`, "--help",
  ], { encoding: "utf8" });
  assert.equal(command.status, 0, command.stderr);
  assert.match(command.stdout, /remoteMetadataComparisonComplete/);
  assert.match(command.stdout, /never requested or written/);
}

process.stdout.write("ASC submission metadata snapshot tests passed\n");
NODE
