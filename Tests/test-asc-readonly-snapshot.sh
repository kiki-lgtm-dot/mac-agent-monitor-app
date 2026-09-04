#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"

ASC_TEST_PROJECT_DIR="$PROJECT_DIR" node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import {
  chmodSync,
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  truncateSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import {
  createHash,
  generateKeyPairSync,
  verify as verifySignature,
} from "node:crypto";

const repositoryRoot = process.env.ASC_TEST_PROJECT_DIR;
const modulePath = `${repositoryRoot}/scripts/app-store-connect-api.mjs`;
const {
  AscSnapshotError,
  captureAppSnapshot,
  captureBuildSnapshot,
  createAscClient,
  createTeamApiJwt,
  findUniqueApp,
  formatPublicError,
  sealSnapshot,
  verifySnapshotFile,
  writeImmutableSnapshot,
} = await import(`file://${modulePath}`);

const root = mkdtempSync(join(realpathSync(tmpdir()), "agentisland-asc-snapshot-test."));
const originalHome = process.env.HOME;
process.on("exit", () => {
  process.env.HOME = originalHome;
  rmSync(root, { recursive: true, force: true });
});

const projectRoot = join(root, "project");
const appliedPaths = [
  "Resources/Info.plist",
  "ApplePlatforms/iOS/Config/Project.xcconfig",
  "ApplePlatforms/macOS/Config/Project.xcconfig",
];
for (const relativePath of appliedPaths) {
  mkdirSync(join(projectRoot, relativePath, ".."), { recursive: true, mode: 0o700 });
  writeFileSync(join(projectRoot, relativePath), `identity binding for ${relativePath}\n`, { mode: 0o600 });
}
mkdirSync(join(projectRoot, ".release"), { recursive: true, mode: 0o700 });
mkdirSync(join(projectRoot, "dist"), { recursive: true, mode: 0o700 });
mkdirSync(join(projectRoot, "scripts"), { recursive: true, mode: 0o700 });
for (const script of [
  "app-store-connect-api.mjs",
  "capture-asc-app-snapshot.mjs",
  "capture-asc-build-snapshot.mjs",
]) {
  copyFileSync(join(repositoryRoot, "scripts", script), join(projectRoot, "scripts", script));
}

const artifactPath = join(projectRoot, "dist", "AgentIsland.ipa");
const identityLockPath = join(projectRoot, ".release", "identity.lock.json");
const bundleId = "com.acme.agentisland";
writeFileSync(artifactPath, "sealed candidate bytes\n", { mode: 0o600 });
const validIdentityLock = {
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
const validIdentityLockBytes = `${JSON.stringify(validIdentityLock, null, 2)}\n`;
writeFileSync(identityLockPath, validIdentityLockBytes, { mode: 0o600 });
chmodSync(identityLockPath, 0o600);

const appId = "app-123";
const preReleaseVersionId = "pre-123";
const buildId = "build-123";
const buildUploadId = "upload-123";
const version = "1.2.3";
const build = "45";
// Keep the fixture fresh for the executable --verify smoke test while still
// supplying explicit times to deterministic expiry assertions below.
const fixedNow = new Date(Date.now() - 5_000);

const appResource = (overrides = {}) => ({
  type: "apps",
  id: appId,
  attributes: {
    name: "Agent Island",
    bundleId,
    sku: "AGENT-ISLAND",
    primaryLocale: "zh-Hans",
    contentRightsDeclaration: "DOES_NOT_USE_THIRD_PARTY_CONTENT",
    isOrEverWasMadeForKids: false,
    ...overrides,
  },
});

function buildCollection({
  buildVersion = build,
  processingState = "VALID",
  expired = false,
  preVersion = version,
  platform = "IOS",
  uploadVersion = version,
  uploadBuild = build,
  uploadPlatform = "IOS",
  uploadState = "COMPLETE",
  buildAudienceType = "APP_STORE_ELIGIBLE",
  usesNonExemptEncryption = false,
  uploadErrors = [],
  uploadWarnings = [{ code: "W1", description: "preserved warning detail" }],
  duplicateBuild = false,
  includedAppOverrides = {},
  includedAppId = appId,
  omitPreReleaseAppRelationship = false,
  preReleaseAppType = "apps",
  preReleaseAppId = appId,
  omitBuildUploadBuildRelationship = false,
  buildUploadBuildType = "builds",
  buildUploadBuildId = buildId,
} = {}) {
  const buildResource = {
    type: "builds",
    id: buildId,
    attributes: {
      version: buildVersion,
      uploadedDate: "2026-09-04T04:50:00.000Z",
      expirationDate: "2026-12-03T04:50:00.000Z",
      expired,
      processingState,
      buildAudienceType,
      usesNonExemptEncryption,
    },
    relationships: {
      app: { data: { type: "apps", id: appId } },
      preReleaseVersion: { data: { type: "preReleaseVersions", id: preReleaseVersionId } },
      buildUpload: { data: { type: "buildUploads", id: buildUploadId } },
    },
  };
  return {
    data: duplicateBuild
      ? [buildResource, { ...buildResource, id: "build-duplicate" }]
      : [buildResource],
    included: [
      { ...appResource(includedAppOverrides), id: includedAppId },
      {
        type: "preReleaseVersions",
        id: preReleaseVersionId,
        attributes: { version: preVersion, platform },
        ...(omitPreReleaseAppRelationship ? {} : {
          relationships: {
            app: { data: { type: preReleaseAppType, id: preReleaseAppId } },
          },
        }),
      },
      {
        type: "buildUploads",
        id: buildUploadId,
        attributes: {
          cfBundleShortVersionString: uploadVersion,
          cfBundleVersion: uploadBuild,
          platform: uploadPlatform,
          createdDate: "2026-09-04T04:45:00.000Z",
          uploadedDate: "2026-09-04T04:47:00.000Z",
          state: {
            state: uploadState,
            errors: uploadErrors,
            warnings: uploadWarnings,
            infos: [{ code: "I1", description: "preserved information detail" }],
          },
        },
        ...(omitBuildUploadBuildRelationship ? {} : {
          relationships: {
            build: { data: { type: buildUploadBuildType, id: buildUploadBuildId } },
          },
        }),
      },
    ],
    links: { next: null },
  };
}

function jsonResponse(json, status = 200, headers = {}) {
  return {
    status,
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(json),
  };
}

function fixtureClient({ apps = [appResource()], builds = buildCollection(), clientOptions = {} } = {}) {
  const calls = [];
  const client = createAscClient({
    ...clientOptions,
    tokenProvider: async () => "SECRET.JWT.VALUE",
    transport: async (request) => {
      calls.push(request);
      assert.equal(request.method, "GET");
      assert.equal(request.url.protocol, "https:");
      assert.equal(request.url.hostname, "api.appstoreconnect.apple.com");
      assert.equal(request.headers.authorization, "Bearer SECRET.JWT.VALUE");
      if (request.url.pathname === "/v1/apps") {
        return jsonResponse({ data: apps, links: { next: null } });
      }
      if (request.url.pathname === "/v1/builds") return jsonResponse(builds);
      throw new Error("unexpected fixture route");
    },
  });
  return { client, calls };
}

async function expectCode(action, code) {
  let caught;
  try {
    await action();
  } catch (error) {
    caught = error;
  }
  assert(caught instanceof AscSnapshotError, `expected ${code}, received ${caught}`);
  assert.equal(caught.code, code);
  return caught;
}

function buildCaptureOptions(client, overrides = {}) {
  return {
    client,
    bundleId,
    platform: "iOS",
    version,
    build,
    artifactPath,
    identityLockPath,
    projectRoot,
    now: fixedNow,
    ...overrides,
  };
}

function writeIdentityLock(value) {
  writeFileSync(identityLockPath, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  chmodSync(identityLockPath, 0o600);
}

// A valid App snapshot binds the exact local candidate and contains only GET evidence.
{
  const { client, calls } = fixtureClient();
  const snapshot = await captureAppSnapshot({
    client,
    bundleId,
    artifactPath,
    identityLockPath,
    projectRoot,
    now: fixedNow,
  });
  assert.equal(snapshot.kind, "app-store-connect-app-snapshot");
  assert.equal(snapshot.resourceIDs.app, appId);
  assert.equal(snapshot.readiness.snapshotReady, true);
  assert.equal(snapshot.requestEvidence.length, 1);
  assert.equal(calls.length, 1);

  const path = join(root, "asc-app-snapshot.json");
  writeImmutableSnapshot(path, snapshot);
  assert.equal(readFileSync(path, "utf8").includes("SECRET.JWT.VALUE"), false);
  assert.equal((await import("node:fs")).statSync(path).mode & 0o777, 0o444);
  const verified = verifySnapshotFile(path, {
    kind: "app-store-connect-app-snapshot",
    bundleId,
    artifactPath,
    identityLockPath,
    projectRoot,
    now: new Date(fixedNow.getTime() + 10_000),
  });
  assert.equal(verified.verified, true);
  assert.equal(verified.resourceIDs.app, appId);
  const snapshotAlias = join(root, "asc-app-snapshot-alias.json");
  symlinkSync(path, snapshotAlias);
  await expectCode(() => Promise.resolve(verifySnapshotFile(snapshotAlias, {
    kind: "app-store-connect-app-snapshot",
    bundleId,
    artifactPath,
    identityLockPath,
    projectRoot,
    now: fixedNow,
  })), "UNSAFE_PATH");
  await expectCode(() => Promise.resolve(writeImmutableSnapshot(path, snapshot)), "SNAPSHOT_EXISTS");

  // The executable --verify path must not need credentials or network access.
  const cli = spawnSync(process.execPath, [
    `${projectRoot}/scripts/capture-asc-app-snapshot.mjs`,
    "--verify", path,
    "--bundle-id", bundleId,
    "--artifact", artifactPath,
    "--identity-lock", identityLockPath,
  ], {
    encoding: "utf8",
    env: {
      PATH: process.env.PATH,
      HOME: root,
    },
  });
  assert.equal(cli.status, 0, cli.stderr);
  const cliResult = JSON.parse(cli.stdout);
  assert.equal(cliResult.verified, true);
  assert.equal(cliResult.app.sku, "AGENT-ISLAND");
  assert.equal(cliResult.app.primaryLocale, "zh-Hans");
  assert.equal(cliResult.releaseIdentity.appStoreRecordMode, "universal-purchase");
}

// JSON:API resource IDs must never be dot path segments because URL
// normalization could otherwise escape the intended /v1 resource route.
{
  const invalid = appResource();
  invalid.id = "..";
  const { client } = fixtureClient({ apps: [invalid] });
  await expectCode(() => captureAppSnapshot({
    client,
    bundleId,
    artifactPath,
    identityLockPath,
    projectRoot,
    now: fixedNow,
  }), "ASC_RESPONSE_INVALID");
}

// Release archives can be hundreds of MiB. Hash them in bounded chunks rather
// than retaining the complete PKG/IPA Buffer until the ASC request returns.
{
  const originalArtifact = readFileSync(artifactPath);
  const largeArtifactBytes = 64 * 1024 * 1024;
  truncateSync(artifactPath, largeArtifactBytes);
  const externalBefore = process.memoryUsage().external;
  let externalAtRequest = externalBefore;
  const streamingClient = {
    getCollection: async () => {
      externalAtRequest = process.memoryUsage().external;
      return { data: [appResource()], requests: [] };
    },
  };
  const snapshot = await captureAppSnapshot({
    client: streamingClient,
    bundleId,
    artifactPath,
    identityLockPath,
    projectRoot,
    now: fixedNow,
  });
  assert.equal(snapshot.candidate.artifactByteLength, largeArtifactBytes);
  assert.match(snapshot.candidate.artifactSHA256, /^[0-9a-f]{64}$/);
  assert(
    externalAtRequest - externalBefore < 32 * 1024 * 1024,
    "release artifact hashing retained an archive-sized Buffer",
  );
  writeFileSync(artifactPath, originalArtifact);
}

// A valid Build snapshot preserves every BuildUpload issue and exposes stable gates.
let validBuildSnapshot;
{
  const { client, calls } = fixtureClient();
  validBuildSnapshot = await captureBuildSnapshot(buildCaptureOptions(client));
  assert.equal(calls.length, 2);
  assert.deepEqual(calls.map((call) => call.url.pathname), ["/v1/apps", "/v1/builds"]);
  assert.equal(calls[1].url.searchParams.get("filter[app]"), appId);
  assert.equal(calls[1].url.searchParams.get("filter[version]"), build);
  assert.equal(calls[1].url.searchParams.get("filter[preReleaseVersion.version]"), version);
  assert.equal(calls[1].url.searchParams.get("filter[preReleaseVersion.platform]"), "IOS");
  assert.equal(validBuildSnapshot.build.processingState, "VALID");
  assert.equal(validBuildSnapshot.build.buildAudienceType, "APP_STORE_ELIGIBLE");
  assert.equal(validBuildSnapshot.build.usesNonExemptEncryption, false);
  assert.equal(validBuildSnapshot.build.exportComplianceRequired, false);
  assert.equal(validBuildSnapshot.buildUpload.state, "COMPLETE");
  assert.deepEqual(validBuildSnapshot.buildUpload.errors, []);
  assert.deepEqual(validBuildSnapshot.buildUpload.warnings, [{ code: "W1", description: "preserved warning detail" }]);
  assert.equal(validBuildSnapshot.buildUpload.warningsPresent, true);
  assert.deepEqual(validBuildSnapshot.buildUpload.infos, [{ code: "I1", description: "preserved information detail" }]);
  assert.equal(validBuildSnapshot.readiness.buildProcessingValid, true);
  assert.equal(validBuildSnapshot.readiness.buildUploadComplete, true);
  assert.equal(validBuildSnapshot.readiness.buildUploadErrorFree, true);
  assert.equal(validBuildSnapshot.readiness.warningsPresent, true);
  assert.equal(validBuildSnapshot.readiness.snapshotReady, true);

  const path = join(root, "asc-build-snapshot.json");
  writeImmutableSnapshot(path, validBuildSnapshot);
  const expected = {
    kind: "app-store-connect-build-snapshot",
    bundleId,
    platform: "iOS",
    version,
    build,
    artifactPath,
    identityLockPath,
    projectRoot,
  };
  const verifiedBuild = verifySnapshotFile(path, { ...expected, now: fixedNow });
  assert.equal(verifiedBuild.verified, true);
  assert.equal(verifiedBuild.app.sku, "AGENT-ISLAND");
  assert.equal(verifiedBuild.app.primaryLocale, "zh-Hans");
  assert.equal(verifiedBuild.build.buildAudienceType, "APP_STORE_ELIGIBLE");
  assert.equal(verifiedBuild.build.usesNonExemptEncryption, false);
  assert.deepEqual(verifiedBuild.buildUpload.errors, []);
  assert.equal(verifiedBuild.buildUpload.warningsPresent, true);
  await expectCode(
    () => Promise.resolve(verifySnapshotFile(path, {
      ...expected,
      now: new Date(fixedNow.getTime() + 901_000),
    })),
    "SNAPSHOT_EXPIRED",
  );

  chmodSync(path, 0o644);
  await expectCode(
    () => Promise.resolve(verifySnapshotFile(path, { ...expected, now: fixedNow })),
    "SNAPSHOT_PERMISSIONS_INVALID",
  );
  chmodSync(path, 0o444);

  const originalArtifact = readFileSync(artifactPath);
  writeFileSync(artifactPath, "changed candidate bytes\n");
  await expectCode(
    () => Promise.resolve(verifySnapshotFile(path, { ...expected, now: fixedNow })),
    "SNAPSHOT_BINDING_MISMATCH",
  );
  writeFileSync(artifactPath, originalArtifact);

  const originalSnapshot = readFileSync(path, "utf8");
  chmodSync(path, 0o644);
  const tampered = JSON.parse(originalSnapshot);
  tampered.build.processingState = "PROCESSING";
  writeFileSync(path, `${JSON.stringify(tampered, null, 2)}\n`);
  chmodSync(path, 0o444);
  await expectCode(
    () => Promise.resolve(verifySnapshotFile(path, { ...expected, now: fixedNow })),
    "SNAPSHOT_TAMPERED",
  );
  chmodSync(path, 0o644);
  writeFileSync(path, originalSnapshot);
  chmodSync(path, 0o444);
}

// COMPLETE uploads with errors and builds needing export compliance remain
// truthful diagnostic snapshots but never become release-ready evidence.
{
  const uploadErrors = [{ code: "E1", description: "preserved error detail" }];
  const { client: errorClient } = fixtureClient({
    builds: buildCollection({ uploadErrors }),
  });
  const errorSnapshot = await captureBuildSnapshot(buildCaptureOptions(errorClient));
  assert.deepEqual(errorSnapshot.buildUpload.errors, uploadErrors);
  assert.equal(errorSnapshot.readiness.buildUploadErrorFree, false);
  assert.equal(errorSnapshot.readiness.snapshotReady, false);

  const errorPath = join(root, "asc-build-upload-errors.json");
  writeImmutableSnapshot(errorPath, errorSnapshot);
  const verifiedErrorSnapshot = verifySnapshotFile(errorPath, {
    kind: "app-store-connect-build-snapshot",
    bundleId,
    platform: "iOS",
    version,
    build,
    artifactPath,
    identityLockPath,
    projectRoot,
    now: fixedNow,
  });
  assert.equal(verifiedErrorSnapshot.verified, true);
  assert.equal(verifiedErrorSnapshot.readiness.snapshotReady, false);
  assert.deepEqual(verifiedErrorSnapshot.buildUpload.errors, uploadErrors);

  const { client: complianceClient } = fixtureClient({
    builds: buildCollection({ usesNonExemptEncryption: true }),
  });
  const complianceSnapshot = await captureBuildSnapshot(buildCaptureOptions(complianceClient));
  assert.equal(complianceSnapshot.build.usesNonExemptEncryption, true);
  assert.equal(complianceSnapshot.build.exportComplianceRequired, true);
  assert.equal(complianceSnapshot.readiness.exportComplianceRequired, true);
  assert.equal(complianceSnapshot.readiness.snapshotReady, false);
}

// The fixed repository identity lock must carry the complete production schema,
// and its selected app bundle must agree with the queried platform.
{
  let networkCalled = false;
  const noNetworkClient = createAscClient({
    tokenProvider: async () => "SECRET.JWT.VALUE",
    transport: async () => {
      networkCalled = true;
      return jsonResponse({ data: [], links: { next: null } });
    },
  });
  await expectCode(() => captureAppSnapshot({
    client: noNetworkClient,
    bundleId: "com.acme.wrong",
    artifactPath,
    identityLockPath,
    projectRoot,
    now: fixedNow,
  }), "IDENTITY_LOCK_BUNDLE_MISMATCH");
  assert.equal(networkCalled, false);

  const invalidLocks = [
    [{ ...validIdentityLock, schemaVersion: 2 }, "IDENTITY_LOCK_INVALID"],
    [{ ...validIdentityLock, identity: {} }, "IDENTITY_LOCK_INVALID"],
    [{
      ...validIdentityLock,
      identity: { ...validIdentityLock.identity, schemaVersion: 1 },
    }, "IDENTITY_LOCK_INVALID"],
    [{
      ...validIdentityLock,
      identity: { ...validIdentityLock.identity, appStoreRecordMode: "separate-records" },
    }, "IDENTITY_LOCK_INVALID"],
  ];
  for (const [invalidLock, code] of invalidLocks) {
    writeIdentityLock(invalidLock);
    await expectCode(() => captureAppSnapshot({
      client: noNetworkClient,
      bundleId,
      artifactPath,
      identityLockPath,
      projectRoot,
      now: fixedNow,
    }), code);
  }
  const separateIdentityLock = {
    ...validIdentityLock,
    identity: {
      ...validIdentityLock.identity,
      appStoreRecordMode: "separate-records",
      macOSAppBundleIdentifier: "com.acme.agentisland.macos",
    },
  };
  writeIdentityLock(separateIdentityLock);
  await expectCode(() => captureBuildSnapshot(buildCaptureOptions(noNetworkClient, {
    bundleId: "com.acme.agentisland.macos",
    platform: "iOS",
  })), "IDENTITY_LOCK_BUNDLE_MISMATCH");
  writeFileSync(identityLockPath, validIdentityLockBytes, { mode: 0o600 });
  chmodSync(identityLockPath, 0o600);

  const otherIdentityPath = join(projectRoot, ".release", "other-identity.json");
  writeFileSync(otherIdentityPath, validIdentityLockBytes, { mode: 0o600 });
  chmodSync(otherIdentityPath, 0o600);
  await expectCode(() => captureAppSnapshot({
    client: noNetworkClient,
    bundleId,
    artifactPath,
    identityLockPath: otherIdentityPath,
    projectRoot,
    now: fixedNow,
  }), "IDENTITY_LOCK_PATH_INVALID");
  assert.equal(networkCalled, false);
}

// App and build uniqueness are verified locally even if a server ignores filters.
{
  const { client: none } = fixtureClient({ apps: [] });
  await expectCode(() => findUniqueApp(none, bundleId), "ASC_APP_NOT_FOUND");
  const { client: duplicate } = fixtureClient({ apps: [appResource(), { ...appResource(), id: "app-duplicate" }] });
  await expectCode(() => findUniqueApp(duplicate, bundleId), "ASC_APP_NOT_UNIQUE");
  const { client: duplicateBuild } = fixtureClient({ builds: buildCollection({ duplicateBuild: true }) });
  await expectCode(
    () => captureBuildSnapshot(buildCaptureOptions(duplicateBuild)),
    "ASC_BUILD_NOT_UNIQUE",
  );
}

// The App representation returned with /v1/builds must be the same stable
// record observed immediately beforehand via /v1/apps.
for (const drift of [
  { includedAppId: "app-drifted" },
  { includedAppOverrides: { bundleId: "com.acme.agentisland.changed" } },
  { includedAppOverrides: { name: "Changed name" } },
  { includedAppOverrides: { sku: "CHANGED-SKU" } },
  { includedAppOverrides: { primaryLocale: "en-US" } },
  { includedAppOverrides: { contentRightsDeclaration: "USES_THIRD_PARTY_CONTENT" } },
  { includedAppOverrides: { isOrEverWasMadeForKids: true } },
]) {
  const { client } = fixtureClient({ builds: buildCollection(drift) });
  await expectCode(() => captureBuildSnapshot(buildCaptureOptions(client)), "ASC_RESPONSE_DRIFT");
}

// Included resources must preserve both reverse links requested from ASC.
// Matching version/build strings alone cannot bind them to this App and Build.
for (const drift of [
  { omitPreReleaseAppRelationship: true },
  { preReleaseAppType: "builds" },
  { preReleaseAppId: "app-other" },
  { omitBuildUploadBuildRelationship: true },
  { buildUploadBuildType: "apps" },
  { buildUploadBuildId: "build-other" },
]) {
  const { client } = fixtureClient({ builds: buildCollection(drift) });
  await expectCode(() => captureBuildSnapshot(buildCaptureOptions(client)), "ASC_RESPONSE_DRIFT");
}

// Wrong platform/version and incomplete processing fail closed.
for (const [fixture, code] of [
  [{ preVersion: "9.9.9" }, "ASC_BUILD_VERSION_MISMATCH"],
  [{ platform: "MAC_OS" }, "ASC_BUILD_VERSION_MISMATCH"],
  [{ uploadVersion: "9.9.9" }, "ASC_BUILD_UPLOAD_MISMATCH"],
  [{ uploadPlatform: "MAC_OS" }, "ASC_BUILD_UPLOAD_MISMATCH"],
  [{ processingState: "PROCESSING" }, "ASC_BUILD_NOT_VALID"],
  [{ processingState: "FAILED" }, "ASC_BUILD_NOT_VALID"],
  [{ expired: true }, "ASC_BUILD_EXPIRED"],
  [{ buildAudienceType: "INTERNAL_ONLY" }, "ASC_BUILD_AUDIENCE_INELIGIBLE"],
  [{ usesNonExemptEncryption: null }, "ASC_BUILD_ENCRYPTION_UNRESOLVED"],
  [{ uploadState: "PROCESSING" }, "ASC_BUILD_UPLOAD_INCOMPLETE"],
  [{ uploadState: "FAILED" }, "ASC_BUILD_UPLOAD_INCOMPLETE"],
]) {
  const { client } = fixtureClient({ builds: buildCollection(fixture) });
  await expectCode(() => captureBuildSnapshot(buildCaptureOptions(client)), code);
}

// Pagination follows only Apple's fixed host, detects loops, and enforces a hard page cap.
{
  let call = 0;
  const client = createAscClient({
    maxPages: 2,
    tokenProvider: async () => "SECRET.JWT.VALUE",
    transport: async ({ url }) => {
      call += 1;
      if (call === 1) {
        return jsonResponse({
          data: [appResource()],
          links: { next: "https://api.appstoreconnect.apple.com/v1/apps?cursor=page2" },
        });
      }
      assert.equal(url.searchParams.get("cursor"), "page2");
      return jsonResponse({ data: [], links: { next: null } });
    },
  });
  const paged = await client.getCollection("/v1/apps");
  assert.equal(paged.pageCount, 2);
  assert.equal(paged.requests.length, 2);

  const limited = createAscClient({
    maxPages: 1,
    tokenProvider: async () => "SECRET.JWT.VALUE",
    transport: async () => jsonResponse({
      data: [],
      links: { next: "https://api.appstoreconnect.apple.com/v1/apps?cursor=more" },
    }),
  });
  await expectCode(() => limited.getCollection("/v1/apps"), "ASC_PAGINATION_LIMIT");

  const crossOriginNext = createAscClient({
    tokenProvider: async () => "SECRET.JWT.VALUE",
    transport: async () => jsonResponse({ data: [], links: { next: "https://evil.example/v1/apps" } }),
  });
  await expectCode(() => crossOriginNext.getCollection("/v1/apps"), "ASC_UNSAFE_URL");
  await expectCode(() => client.getCollection("https://evil.example/v1/apps"), "ASC_INVALID_ENDPOINT");

  async function expectPaginationFailure(next, query, code) {
    const driftClient = createAscClient({
      tokenProvider: async () => "SECRET.JWT.VALUE",
      transport: async () => jsonResponse({ data: [], links: { next } }),
    });
    await expectCode(() => driftClient.getCollection("/v1/apps", query), code);
  }
  await expectPaginationFailure(
    "https://api.appstoreconnect.apple.com/v1/builds?cursor=page2",
    {},
    "ASC_PAGINATION_DRIFT",
  );
  await expectPaginationFailure(
    "https://api.appstoreconnect.apple.com/v1/apps?filter%5BbundleId%5D=com.acme.other&cursor=page2",
    { "filter[bundleId]": bundleId },
    "ASC_PAGINATION_DRIFT",
  );
  await expectPaginationFailure(
    "https://api.appstoreconnect.apple.com/v1/apps?limit=100&cursor=page2",
    { limit: "200" },
    "ASC_PAGINATION_DRIFT",
  );
  await expectPaginationFailure(
    "https://api.appstoreconnect.apple.com/v1/apps?cursor=one&cursor=two",
    {},
    "ASC_PAGINATION_INVALID",
  );

  let repeatPage = 0;
  const repeatedCursor = createAscClient({
    tokenProvider: async () => "SECRET.JWT.VALUE",
    transport: async () => {
      repeatPage += 1;
      return jsonResponse({
        data: [],
        links: { next: "https://api.appstoreconnect.apple.com/v1/apps?cursor=same" },
      });
    },
  });
  await expectCode(() => repeatedCursor.getCollection("/v1/apps"), "ASC_PAGINATION_LOOP");
  assert.equal(repeatPage, 2);
}

// Redirects, explicit auth failures, rate limits, oversized bodies, and timeouts are classified.
{
  function clientForResponse(response, options = {}) {
    return createAscClient({
      ...options,
      tokenProvider: async () => "SECRET.JWT.VALUE",
      transport: async () => response,
    });
  }
  await expectCode(
    () => clientForResponse({
      status: 302,
      headers: { location: "https://evil.example/steal" },
      body: "",
    }).getCollection("/v1/apps"),
    "ASC_CROSS_ORIGIN_REDIRECT",
  );
  await expectCode(
    () => clientForResponse({
      status: 302,
      headers: { location: "https://api.appstoreconnect.apple.com/v1/apps" },
      body: "",
    }).getCollection("/v1/apps"),
    "ASC_REDIRECT_REJECTED",
  );
  for (const [status, code] of [
    [401, "ASC_AUTHENTICATION_FAILED"],
    [403, "ASC_AUTHORIZATION_FAILED"],
    [429, "ASC_RATE_LIMITED"],
    [500, "ASC_HTTP_ERROR"],
  ]) {
    const secretBody = JSON.stringify({
      errors: [{ code: "AUTH", detail: "SECRET.JWT.VALUE PRIVATE_KEY_BYTES" }],
    });
    const error = await expectCode(
      () => clientForResponse({
        status,
        headers: { "content-type": "application/json", "retry-after": "30" },
        body: secretBody,
      }).getCollection("/v1/apps"),
      code,
    );
    const publicMessage = formatPublicError(error);
    assert.equal(publicMessage.includes("SECRET.JWT.VALUE"), false);
    assert.equal(publicMessage.includes("PRIVATE_KEY_BYTES"), false);
  }
  await expectCode(
    () => clientForResponse({ status: 200, headers: {}, body: "x".repeat(300) }, {
      maxResponseBytes: 256,
    }).getCollection("/v1/apps"),
    "ASC_RESPONSE_TOO_LARGE",
  );
  const timeoutClient = createAscClient({
    timeoutMs: 100,
    tokenProvider: async () => "SECRET.JWT.VALUE",
    transport: ({ signal }) => new Promise((resolve, reject) => {
      signal.addEventListener("abort", () => {
        const error = new Error("aborted");
        error.name = "AbortError";
        reject(error);
      }, { once: true });
    }),
  });
  await expectCode(() => timeoutClient.getCollection("/v1/apps"), "ASC_TIMEOUT");
}

// JWT generation uses only the conventional key location and emits P1363 ES256.
{
  const keyId = "ABCDEF1234";
  const issuerId = "57246542-96fe-1a63-e053-0824d011072a";
  const privateDirectory = join(root, "home", ".appstoreconnect", "private_keys");
  mkdirSync(privateDirectory, { recursive: true, mode: 0o700 });
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const keyPath = join(privateDirectory, `AuthKey_${keyId}.p8`);
  writeFileSync(keyPath, privateKey.export({ type: "pkcs8", format: "pem" }), { mode: 0o600 });
  chmodSync(keyPath, 0o600);
  process.env.HOME = join(root, "home");
  const jwt = createTeamApiJwt({
    keyId,
    issuerId,
    scope: "GET /v1/apps?filter%5BbundleId%5D=com.example.agentisland",
    nowSeconds: 1_700_000_000,
  });
  const segments = jwt.split(".");
  assert.equal(segments.length, 3);
  const header = JSON.parse(Buffer.from(segments[0], "base64url"));
  const payload = JSON.parse(Buffer.from(segments[1], "base64url"));
  assert.deepEqual(header, { alg: "ES256", kid: keyId, typ: "JWT" });
  assert.equal(payload.iss, issuerId);
  assert.equal(payload.aud, "appstoreconnect-v1");
  assert.equal(payload.exp - payload.iat, 120);
  assert.deepEqual(payload.scope, ["GET /v1/apps?filter%5BbundleId%5D=com.example.agentisland"]);
  assert.equal(
    verifySignature("sha256", Buffer.from(`${segments[0]}.${segments[1]}`), {
      key: publicKey,
      dsaEncoding: "ieee-p1363",
    }, Buffer.from(segments[2], "base64url")),
    true,
  );
  assert.equal(jwt.includes(readFileSync(keyPath, "utf8")), false);

  const unsafeKeyPath = join(privateDirectory, "AuthKey_ZYXWVU9876.p8");
  const outsideKeyPath = join(root, "outside-private-key.p8");
  writeFileSync(outsideKeyPath, privateKey.export({ type: "pkcs8", format: "pem" }), { mode: 0o600 });
  symlinkSync(outsideKeyPath, unsafeKeyPath);
  await expectCode(() => Promise.resolve(createTeamApiJwt({
    keyId: "ZYXWVU9876",
    issuerId,
    scope: "GET /v1/apps",
    nowSeconds: 1_700_000_000,
  })), "ASC_PRIVATE_KEY_UNSAFE");
}

// Self-sealing cannot silently accept an already sealed object.
await expectCode(
  () => Promise.resolve(sealSnapshot({ evidenceSHA256: "0".repeat(64) })),
  "SNAPSHOT_INVALID",
);

process.stdout.write("App Store Connect read-only snapshot tests passed\n");
NODE
