#!/bin/zsh
set -euo pipefail
export LC_ALL=C
export LANG=C

PROJECT_DIR="${0:A:h:h}"
VALIDATOR="$PROJECT_DIR/scripts/validate-app-store-submission.mjs"
STORE_VALIDATOR="$PROJECT_DIR/scripts/validate-store-submission.mjs"
EXAMPLE="$PROJECT_DIR/Config/AppStoreSubmission.example.json"
SCHEMA="$PROJECT_DIR/docs/release/APP_STORE_SUBMISSION.schema.json"
FIXTURE_ROOT="$(mktemp -d /private/tmp/agentisland-app-store-submission.XXXXXX)"
trap '/bin/rm -rf "$FIXTURE_ROOT"' EXIT HUP INT TERM

node --check "$VALIDATOR"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$EXAMPLE"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$SCHEMA"

# The checked-in example is intentionally usable only as a draft. A finalized
# manifest must live under the ignored .release directory and bind real local
# evidence; it can never become green merely by copying example placeholders.
EXAMPLE_RESULT="$FIXTURE_ROOT/example-result.json"
(
  cd "$PROJECT_DIR"
  AGENT_ISLAND_APP_STORE_SUBMISSION="Config/AppStoreSubmission.example.json" \
    node "$VALIDATOR" >"$EXAMPLE_RESULT"
)
/usr/bin/jq -e '
  .schemaContract.implementationKeysBound == true and
  .manifest.present == true and
  .manifest.finalizedLocation == false and
  .draftValid == true and
  .localPreflightReady == false and
  .appStoreSubmissionManifestReady == false and
  .submissionReadyForRemoteAction == false and
  (.releaseBlockers | any(contains("unresolved placeholder"))) and
  (.releaseBlockers | any(contains("gitignored .release/")))
' "$EXAMPLE_RESULT" >/dev/null
if (
  cd "$PROJECT_DIR"
  AGENT_ISLAND_APP_STORE_SUBMISSION="Config/AppStoreSubmission.example.json" \
    node "$VALIDATOR" --release >/dev/null 2>&1
); then
  echo "Example manifest unexpectedly passed finalized validation" >&2
  exit 1
fi

/bin/mkdir -p \
  "$FIXTURE_ROOT/scripts" \
  "$FIXTURE_ROOT/Config" \
  "$FIXTURE_ROOT/ApplePlatforms/iOS/Config" \
  "$FIXTURE_ROOT/ApplePlatforms/macOS/Config" \
  "$FIXTURE_ROOT/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset" \
  "$FIXTURE_ROOT/docs/release" \
  "$FIXTURE_ROOT/docs/site/support" \
  "$FIXTURE_ROOT/docs/release-assets/macos/zh-Hans" \
  "$FIXTURE_ROOT/docs/release-assets/macos/en-US" \
  "$FIXTURE_ROOT/docs/release-assets/ios/zh-Hans" \
  "$FIXTURE_ROOT/docs/release-assets/ios/en-US" \
  "$FIXTURE_ROOT/.release" \
  "$FIXTURE_ROOT/Resources" \
  "$FIXTURE_ROOT/dist" \
  "$FIXTURE_ROOT/candidates/MacCandidate.app/Contents" \
  "$FIXTURE_ROOT/candidates/iOSCandidate.xcarchive/Products/Applications/AgentMonitor.app"
/bin/cp "$VALIDATOR" "$FIXTURE_ROOT/scripts/validate-app-store-submission.mjs"
/bin/cp "$STORE_VALIDATOR" "$FIXTURE_ROOT/scripts/validate-store-submission.mjs"
/bin/cp "$SCHEMA" "$FIXTURE_ROOT/docs/release/APP_STORE_SUBMISSION.schema.json"
/bin/cp "$EXAMPLE" "$FIXTURE_ROOT/Config/example.json"
/bin/cp "$PROJECT_DIR/Resources/AgentIsland.icns" "$FIXTURE_ROOT/Resources/AgentIsland.icns"

/usr/bin/printf '%s\n' \
  'AGENT_ISLAND_DISPLAY_NAME = MAC版灵动岛--Agent运行监测' \
  'AGENT_ISLAND_APP_BUNDLE_ID = app.agentmonitor.ios' \
  'AGENT_ISLAND_WIDGET_BUNDLE_ID = $(AGENT_ISLAND_APP_BUNDLE_ID).liveactivity' \
  'MARKETING_VERSION = 0.6.1' \
  'CURRENT_PROJECT_VERSION = 8' \
  >"$FIXTURE_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig"
/usr/bin/printf '%s\n' \
  'AGENT_ISLAND_MAC_APP_BUNDLE_ID = app.agentmonitor.mac' \
  'MARKETING_VERSION = 0.6.1' \
  'CURRENT_PROJECT_VERSION = 8' \
  >"$FIXTURE_ROOT/ApplePlatforms/macOS/Config/Project.xcconfig"
/usr/bin/printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.agentmonitor.mac</string></dict></plist>' \
  >"$FIXTURE_ROOT/Resources/Info.plist"

# Store metadata is deliberately synthetic but structurally final. Contact
# addresses use a non-reserved documentation subdomain and are checked only
# for syntax here; this test never claims they are publicly reachable.
/bin/cat >"$FIXTURE_ROOT/docs/release/APP_STORE_METADATA.md" <<'EOF'
# macOS Store Metadata

## 简体中文（zh-Hans）
### 名称
MAC版灵动岛--Agent运行监测
### 副标题
Agent 本地运行看板
### 推广文本
查看本地 Agent 运行状态与用量摘要。
### 描述
隐私优先的本地 Agent 运行看板。
### 关键词
智能体监测,令牌统计

## English (U.S.)
### Name
MAC版灵动岛--Agent运行监测
### Subtitle
AI Agent Monitor for Mac
### Promotional text
See local agent status and usage summaries.
### Description
A privacy-first local agent activity dashboard.
### Keywords
agents,monitoring
EOF
/bin/cp "$FIXTURE_ROOT/docs/release/APP_STORE_METADATA.md" \
  "$FIXTURE_ROOT/docs/release/IOS_APP_STORE_AND_TESTFLIGHT_METADATA.md"
/usr/bin/perl -0pi -e 's/## 简体中文（zh-Hans）/## 2. 简体中文（zh-Hans）/; s/## English \(U\.S\.\)/## 3. English (U.S.)/' \
  "$FIXTURE_ROOT/docs/release/IOS_APP_STORE_AND_TESTFLIGHT_METADATA.md"

for document in \
  APP_REVIEW_NOTES.md \
  IOS_APP_REVIEW_NOTES.md \
  PRIVACY_POLICY_ZH.md \
  PRIVACY_POLICY_EN.md \
  APP_PRIVACY_SUBMISSION_WORKSHEET.md; do
  /usr/bin/printf '# Final submission material\n\nVerified fixture content.\n' \
    >"$FIXTURE_ROOT/docs/release/$document"
done
/bin/cat >"$FIXTURE_ROOT/docs/site/support/index.html" <<'EOF'
<!doctype html><html><body><a href="mailto:support@fixture.agentisland.app">Email support</a></body></html>
EOF

# Produce real JPEG files with accepted dimensions. The Mac captures are
# cropped, and the iPhone parser fixtures are padded rather than stretched.
# They exercise the asset contract only and are not represented as real
# candidate-build screenshots outside this isolated test tree.
for locale in zh-Hans en-US; do
  SOURCE="$PROJECT_DIR/docs/media/mac-agent-monitor-overview-en.png"
  [[ "$locale" == "zh-Hans" ]] && SOURCE="$PROJECT_DIR/docs/media/mac-agent-monitor-overview-zh.png"
  /usr/bin/sips -s format jpeg -c 800 1280 "$SOURCE" \
    --out "$FIXTURE_ROOT/docs/release-assets/macos/$locale/final.jpg" >/dev/null 2>&1
  /usr/bin/sips -s format jpeg -p 1260 2736 --padColor 000000 \
    "$FIXTURE_ROOT/docs/release-assets/macos/$locale/final.jpg" \
    --out "$FIXTURE_ROOT/docs/release-assets/ios/$locale/final.jpg" >/dev/null 2>&1
done
ICON_SOURCE="$PROJECT_DIR/docs/media/mac-agent-monitor-overview-en.png"
/usr/bin/sips -s format png -z 120 120 "$ICON_SOURCE" \
  --out "$FIXTURE_ROOT/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Icon120.png" >/dev/null 2>&1
/usr/bin/sips -s format png -z 180 180 "$ICON_SOURCE" \
  --out "$FIXTURE_ROOT/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Icon180.png" >/dev/null 2>&1
/usr/bin/sips -s format png -z 1024 1024 "$ICON_SOURCE" \
  --out "$FIXTURE_ROOT/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Icon1024.png" >/dev/null 2>&1
/bin/cat >"$FIXTURE_ROOT/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json" <<'EOF'
{
  "images": [
    { "filename": "Icon120.png", "idiom": "iphone", "scale": "2x", "size": "60x60" },
    { "filename": "Icon180.png", "idiom": "iphone", "scale": "3x", "size": "60x60" },
    { "filename": "Icon1024.png", "idiom": "ios-marketing", "scale": "1x", "size": "1024x1024" }
  ],
  "info": { "author": "xcode", "version": 1 }
}
EOF

# Candidate fixtures are actual ZIP containers with minimal App/Archive
# structure, not plain text renamed to .pkg/.ipa. Signing validity belongs to
# the independent archive gates and is intentionally outside this metadata test.
/usr/bin/printf 'fixture executable payload\n' \
  >"$FIXTURE_ROOT/candidates/MacCandidate.app/Contents/AgentMonitor"
/usr/bin/printf 'fixture mobile payload\n' \
  >"$FIXTURE_ROOT/candidates/iOSCandidate.xcarchive/Products/Applications/AgentMonitor.app/AgentMonitor"
/usr/bin/ditto -c -k --keepParent "$FIXTURE_ROOT/candidates/MacCandidate.app" \
  "$FIXTURE_ROOT/dist/AgentMonitorMac.zip"
/usr/bin/ditto -c -k --keepParent "$FIXTURE_ROOT/candidates/iOSCandidate.xcarchive" \
  "$FIXTURE_ROOT/dist/AgentMonitor.xcarchive.zip"
/usr/bin/unzip -t "$FIXTURE_ROOT/dist/AgentMonitorMac.zip" >/dev/null
/usr/bin/unzip -t "$FIXTURE_ROOT/dist/AgentMonitor.xcarchive.zip" >/dev/null

/bin/cat >"$FIXTURE_ROOT/scripts/validate-app-privacy.mjs" <<'EOF'
#!/usr/bin/env node
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
const sha256 = (path) => createHash("sha256").update(readFileSync(path)).digest("hex");
process.stdout.write(JSON.stringify({
  draftValid: true,
  sourcePrivacyReady: true,
  releaseEvidenceReady: true,
  releaseReady: true,
  releaseEvidencePath: ".release/app-privacy-evidence.json",
  releaseEvidence: {
    schemaVersion: 1,
    recordScope: "separate-records",
    archives: [
      {platform: "macOS", path: "dist/AgentMonitorMac.zip", sha256: sha256("dist/AgentMonitorMac.zip"), bundleID: "app.agentmonitor.mac", version: "0.6.1", build: "8"},
      {platform: "iOS", path: "dist/AgentMonitor.xcarchive.zip", sha256: sha256("dist/AgentMonitor.xcarchive.zip"), bundleID: "app.agentmonitor.ios", version: "0.6.1", build: "8"}
    ]
  },
  structuralErrors: [],
  releaseBlockers: []
}));
EOF

file_sha256() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

MAC_CONFIG_SHA="$(file_sha256 "$FIXTURE_ROOT/ApplePlatforms/macOS/Config/Project.xcconfig")"
IOS_CONFIG_SHA="$(file_sha256 "$FIXTURE_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig")"
INFO_SHA="$(file_sha256 "$FIXTURE_ROOT/Resources/Info.plist")"
/usr/bin/jq -n \
  --arg infoSHA "$INFO_SHA" \
  --arg iosSHA "$IOS_CONFIG_SHA" \
  --arg macSHA "$MAC_CONFIG_SHA" '
  {
    schemaVersion: 1,
    firstAppliedAt: "2026-09-04T00:00:00Z",
    identity: {
      schemaVersion: 2,
      appStoreRecordMode: "separate-records",
      macOSAppBundleIdentifier: "app.agentmonitor.mac",
      iOSAppBundleIdentifier: "app.agentmonitor.ios",
      iOSWidgetBundleIdentifier: "app.agentmonitor.ios.liveactivity",
      teamIdentifier: "ABCDE12345",
      iCloudContainerIdentifier: "iCloud.app.agentmonitor.release",
      cloudKit: {
        databaseScope: "private",
        environment: "Production",
        recordType: "AgentIslandSnapshot",
        recordName: "latest",
        payloadField: "payloadJSON"
      }
    },
    provisioningProfile: null,
    generatedEntitlements: null,
    appliedFiles: [
      {path: "Resources/Info.plist", sha256: $infoSHA},
      {path: "ApplePlatforms/iOS/Config/Project.xcconfig", sha256: $iosSHA},
      {path: "ApplePlatforms/macOS/Config/Project.xcconfig", sha256: $macSHA}
    ]
  }
' >"$FIXTURE_ROOT/.release/identity.lock.json"

MAC_ARTIFACT_SHA="$(file_sha256 "$FIXTURE_ROOT/dist/AgentMonitorMac.zip")"
IOS_ARTIFACT_SHA="$(file_sha256 "$FIXTURE_ROOT/dist/AgentMonitor.xcarchive.zip")"
MAC_ZH_SHA="$(file_sha256 "$FIXTURE_ROOT/docs/release-assets/macos/zh-Hans/final.jpg")"
MAC_EN_SHA="$(file_sha256 "$FIXTURE_ROOT/docs/release-assets/macos/en-US/final.jpg")"
IOS_ZH_SHA="$(file_sha256 "$FIXTURE_ROOT/docs/release-assets/ios/zh-Hans/final.jpg")"
IOS_EN_SHA="$(file_sha256 "$FIXTURE_ROOT/docs/release-assets/ios/en-US/final.jpg")"
CAPTURED_AT="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
/usr/bin/jq -n \
  --arg capturedAt "$CAPTURED_AT" \
  --arg macArtifactSHA "$MAC_ARTIFACT_SHA" \
  --arg iosArtifactSHA "$IOS_ARTIFACT_SHA" \
  --arg macZhSHA "$MAC_ZH_SHA" \
  --arg macEnSHA "$MAC_EN_SHA" \
  --arg iosZhSHA "$IOS_ZH_SHA" \
  --arg iosEnSHA "$IOS_EN_SHA" '
  def attestations: {
    exactCandidateBuild: true,
    localizedForLocale: true,
    noSensitiveDataReviewed: true,
    notStretchedOrSynthetic: true
  };
  {
    schemaVersion: 1,
    candidates: [
      {
        platform: "macos", bundleIdentifier: "app.agentmonitor.mac", version: "0.6.1", build: "8",
        artifact: {path: "dist/AgentMonitorMac.zip", sha256: $macArtifactSHA},
        screenshots: [
          {path: "docs/release-assets/macos/zh-Hans/final.jpg", sha256: $macZhSHA, locale: "zh-Hans", device: "Mac 1280 by 800 display", capturedAt: $capturedAt, source: "exact-candidate-build", attestations: attestations},
          {path: "docs/release-assets/macos/en-US/final.jpg", sha256: $macEnSHA, locale: "en-US", device: "Mac 1280 by 800 display", capturedAt: $capturedAt, source: "exact-candidate-build", attestations: attestations}
        ]
      },
      {
        platform: "ios", bundleIdentifier: "app.agentmonitor.ios", version: "0.6.1", build: "8",
        artifact: {path: "dist/AgentMonitor.xcarchive.zip", sha256: $iosArtifactSHA},
        screenshots: [
          {path: "docs/release-assets/ios/zh-Hans/final.jpg", sha256: $iosZhSHA, locale: "zh-Hans", device: "6.9-inch iPhone landscape", capturedAt: $capturedAt, source: "exact-candidate-build", attestations: attestations},
          {path: "docs/release-assets/ios/en-US/final.jpg", sha256: $iosEnSHA, locale: "en-US", device: "6.9-inch iPhone landscape", capturedAt: $capturedAt, source: "exact-candidate-build", attestations: attestations}
        ]
      }
    ]
  }
' >"$FIXTURE_ROOT/.release/store-screenshot-evidence.json"

IDENTITY_SHA="$(file_sha256 "$FIXTURE_ROOT/.release/identity.lock.json")"
SCREENSHOT_EVIDENCE_SHA="$(file_sha256 "$FIXTURE_ROOT/.release/store-screenshot-evidence.json")"
/usr/bin/jq \
  --arg identitySHA "$IDENTITY_SHA" \
  --arg screenshotEvidenceSHA "$SCREENSHOT_EVIDENCE_SHA" '
  .recordMode = "separate-records" |
  .identityLockSHA256 = $identitySHA |
  .screenshotEvidenceSHA256 = $screenshotEvidenceSHA |
  .records.macos.appResourceId = "1234567890" |
  .records.ios.appResourceId = "1234567891" |
  .records.macos.bundleIdentifier = "app.agentmonitor.mac" |
  .records.ios.bundleIdentifier = "app.agentmonitor.ios" |
  .records.ios.widgetBundleIdentifier = "app.agentmonitor.ios.liveactivity" |
  .records.macos.sku = "AGENT-MONITOR-MAC" |
  .records.ios.sku = "AGENT-MONITOR-IOS" |
  (.records.macos.version.copyright, .records.ios.version.copyright) = "2026 Fixture Rights Holder" |
  (.records.macos.commerce, .records.ios.commerce) |= (
    .ageRating.questionnaireStatus = "complete" |
    .ageRating.declaredRating = "4+" |
    .madeForKids = false |
    .contentRights.status = "uses-third-party-content-rights-cleared" |
    .eula.type = "apple-standard" |
    .eula.customText = null |
    .eula.territories = [] |
    .digitalServicesAct.traderStatus = "non-trader" |
    .digitalServicesAct.verificationStatus = "not-required" |
    .pricing.model = "free" |
    .pricing.pricePointReference = null |
    .pricing.taxCategory = "APP_STORE_SOFTWARE" |
    .pricing.availableTerritories = ["CHN", "USA"] |
    .exportCompliance.usesNonExemptEncryption = false |
    .exportCompliance.status = "exempt" |
    .exportCompliance.documentationReference = null
  ) |
  (.records.macos.review.contact, .records.ios.review.contact, .records.ios.testFlight.betaReviewContact) |= (
    .firstName = "Fixture" |
    .lastName = "Reviewer" |
    .email = "review@fixture.agentisland.app" |
    .phone = "+12025550123"
  ) |
  .records.ios.testFlight.feedbackEmail = "feedback@fixture.agentisland.app" |
  (.records.macos.localizations[0], .records.ios.localizations[0]) |= (
    .subtitle = "Agent 本地运行看板" |
    .promotionalText = "查看本地 Agent 运行状态与用量摘要。" |
    .description = "隐私优先的本地 Agent 运行看板。" |
    .keywords = "智能体监测,令牌统计"
  ) |
  (.records.macos.localizations[1], .records.ios.localizations[1]) |= (
    .subtitle = "AI Agent Monitor for Mac" |
    .promotionalText = "See local agent status and usage summaries." |
    .description = "A privacy-first local agent activity dashboard." |
    .keywords = "agents,monitoring"
  ) |
  .records.macos.screenshotSets = [
    {locale: "zh-Hans", device: "Mac 1280 by 800 display", orderedPaths: ["docs/release-assets/macos/zh-Hans/final.jpg"]},
    {locale: "en-US", device: "Mac 1280 by 800 display", orderedPaths: ["docs/release-assets/macos/en-US/final.jpg"]}
  ] |
  .records.ios.screenshotSets = [
    {locale: "zh-Hans", device: "6.9-inch iPhone landscape", orderedPaths: ["docs/release-assets/ios/zh-Hans/final.jpg"]},
    {locale: "en-US", device: "6.9-inch iPhone landscape", orderedPaths: ["docs/release-assets/ios/en-US/final.jpg"]}
  ]
' "$FIXTURE_ROOT/Config/example.json" >"$FIXTURE_ROOT/.release/app-store-submission.json"
/bin/chmod 0444 "$FIXTURE_ROOT/.release/app-store-submission.json"

# Prove the manifest validator consumes a genuinely green result from the
# existing authoritative store asset validator.
(
  cd "$FIXTURE_ROOT"
  AGENT_ISLAND_STORE_SCREENSHOT_EVIDENCE=".release/store-screenshot-evidence.json" \
    node scripts/validate-store-submission.mjs --release >"$FIXTURE_ROOT/store-ready.json"
)
/usr/bin/jq -e '.storeSubmissionAssetsReady == true' "$FIXTURE_ROOT/store-ready.json" >/dev/null

run_fixture() {
  local manifest_path="$1"
  local output_path="$2"
  shift 2
  (
    cd "$FIXTURE_ROOT"
    AGENT_ISLAND_APP_STORE_SUBMISSION="$manifest_path" \
      node scripts/validate-app-store-submission.mjs "$@" >"$output_path"
  )
}

READY_RESULT="$FIXTURE_ROOT/ready-result.json"
run_fixture ".release/app-store-submission.json" "$READY_RESULT" --release
/usr/bin/jq -e '
  .mode == "release" and
  .schemaContract.implementationKeysBound == true and
  .manifest.finalizedLocation == true and
  .manifest.writeProtected == true and
  .identityLock.bound == true and
  .storeAssets.evidenceHashBound == true and
  .storeAssets.platforms.macos.ready == true and
  .storeAssets.platforms.ios.ready == true and
  .storeAssets.platforms.macos.metadataBound == true and
  .storeAssets.platforms.ios.metadataBound == true and
  .storeAssets.platforms.macos.screenshotReferencesBound == true and
  .storeAssets.platforms.ios.screenshotReferencesBound == true and
  .draftValid == true and
  .localPreflightReady == true and
  .appStoreSubmissionManifestReady == true and
  .macAppStoreSubmissionManifestReady == true and
  .iosAppStoreSubmissionManifestReady == true and
  .submissionReadyForRemoteAction == false and
  .appStoreConnectComparison.verifiedByThisValidator == false and
  .appStoreConnectComparison.requiredBeforeRemoteAction == true and
  .appStoreConnectComparison.expected.macos == {
    appResourceId: "1234567890",
    bundleIdentifier: "app.agentmonitor.mac",
    sku: "AGENT-MONITOR-MAC",
    primaryLocale: "zh-Hans",
    taxCategory: "APP_STORE_SOFTWARE",
    availableTerritories: ["CHN", "USA"]
  } and
  .derivedChecks.recordModeSemanticsValid == true and
  .derivedChecks.universalPurchaseCategoriesConsistent == null and
  .derivedChecks.universalPurchaseLocalizedAppFieldsConsistent == null and
  .derivedChecks.primaryLocalesCovered == true and
  .derivedChecks.macPrimaryCategoryMatchesProduct == true and
  .structuralErrors == [] and
  .releaseBlockers == []
' "$READY_RESULT" >/dev/null

# Draft inspection remains available for an editable manifest, but none of the
# release-oriented ready fields may turn green until every write bit is removed.
for writable_mode in 0644 0464 0446; do
  WRITABLE_MANIFEST="$FIXTURE_ROOT/.release/writable-$writable_mode.json"
  /bin/cp "$FIXTURE_ROOT/.release/app-store-submission.json" "$WRITABLE_MANIFEST"
  /bin/chmod "$writable_mode" "$WRITABLE_MANIFEST"
  WRITABLE_DRAFT_RESULT="$FIXTURE_ROOT/writable-$writable_mode-draft.json"
  run_fixture ".release/writable-$writable_mode.json" "$WRITABLE_DRAFT_RESULT"
  /usr/bin/jq -e '
    .mode == "draft" and
    .draftValid == true and
    .manifest.writeProtected == false and
    .localPreflightReady == false and
    .appStoreSubmissionManifestReady == false and
    .macAppStoreSubmissionManifestReady == false and
    .iosAppStoreSubmissionManifestReady == false and
    (.releaseBlockers | any(contains("must not have owner, group, or other write permissions")))
  ' "$WRITABLE_DRAFT_RESULT" >/dev/null
  if run_fixture ".release/writable-$writable_mode.json" \
      "$FIXTURE_ROOT/writable-$writable_mode-release.json" --release; then
    echo "Writable finalized manifest unexpectedly passed: $writable_mode" >&2
    exit 1
  fi
done

write_case() {
  local name="$1"
  local filter="$2"
  /usr/bin/jq "$filter" "$FIXTURE_ROOT/.release/app-store-submission.json" \
    >"$FIXTURE_ROOT/.release/case-$name.json"
  /bin/chmod 0444 "$FIXTURE_ROOT/.release/case-$name.json"
}

expect_structural_failure() {
  local name="$1"
  local filter="$2"
  local expected="$3"
  local result="$FIXTURE_ROOT/result-$name.json"
  write_case "$name" "$filter"
  if run_fixture ".release/case-$name.json" "$result"; then
    echo "Structural mutation unexpectedly passed: $name" >&2
    exit 1
  fi
  /usr/bin/jq -e --arg expected "$expected" '
    .draftValid == false and
    .localPreflightReady == false and
    .macAppStoreSubmissionManifestReady == false and
    .iosAppStoreSubmissionManifestReady == false and
    (.structuralErrors | any(contains($expected))) and
    (.platforms.macos.structuralErrors | any(contains($expected))) and
    (.platforms.ios.structuralErrors | any(contains($expected)))
  ' "$result" >/dev/null
}

expect_platform_structural_failure() {
  local name="$1"
  local filter="$2"
  local expected="$3"
  local platform="$4"
  local result="$FIXTURE_ROOT/result-$name.json"
  write_case "$name" "$filter"
  if run_fixture ".release/case-$name.json" "$result"; then
    echo "Platform structural mutation unexpectedly passed: $name" >&2
    exit 1
  fi
  /usr/bin/jq -e --arg expected "$expected" --arg platform "$platform" '
    .draftValid == false and
    .localPreflightReady == false and
    .appStoreSubmissionManifestReady == false and
    (.structuralErrors | any(contains($expected))) and
    (.platforms[$platform].draftValid == false) and
    (.platforms[$platform].submissionManifestReady == false) and
    (.platforms[$platform].structuralErrors | any(contains($expected)))
  ' "$result" >/dev/null
}

expect_release_failure() {
  local name="$1"
  local filter="$2"
  local expected="$3"
  local result="$FIXTURE_ROOT/result-$name.json"
  write_case "$name" "$filter"
  run_fixture ".release/case-$name.json" "$result"
  /usr/bin/jq -e --arg expected "$expected" '
    .draftValid == true and
    .localPreflightReady == false and
    (.releaseBlockers | any(contains($expected)))
  ' "$result" >/dev/null
  if run_fixture ".release/case-$name.json" "$FIXTURE_ROOT/release-$name.json" --release; then
    echo "Finalized mutation unexpectedly passed: $name" >&2
    exit 1
  fi
}

# Security and top-level integrity failures contaminate both platforms.
expect_structural_failure "top-unknown" '.unexpected = true' "unknown keys"
expect_structural_failure "top-missing" 'del(.identityLockSHA256)' "missing keys"
expect_structural_failure "plaintext-secret-mac" '.records.macos.review.notes = "password=hunter2"' "plaintext credential"
expect_structural_failure "plaintext-secret-ios" '.records.ios.review.notes = "api_key=sk-ABCDEFGHIJKLMNOPQRSTUVWX"' "plaintext credential"
expect_structural_failure "forbidden-secret-field" '.records.macos.review.apiSecret = "opaque-value"' "forbidden credential field"
expect_structural_failure "unsafe-mac-path" '.records.macos.screenshotSets[0].orderedPaths[0] = "../escape.png"' "must not contain empty, dot, or parent"
expect_structural_failure "unsafe-ios-path" '.records.ios.screenshotSets[0].orderedPaths[0] = "/private/tmp/escape.png"' "repository-relative POSIX path"
expect_structural_failure "bad-secret-reference" '.records.ios.review.login.strategy = "review-account" | .records.ios.review.login.credentialsSecretReference = "plaintext-password"' "credentialsSecretReference"

# Product, policy, and account values fail closed without being mislabeled as
# globally verified remote state.
expect_release_failure "reserved-email-test" '.records.ios.review.contact.email = "review@fixture.test"' "non-reserved domain"
expect_release_failure "reserved-email-example" '.records.macos.review.contact.email = "review@example.com"' "non-reserved domain"
expect_release_failure "reserved-url" '.records.macos.localizations[0].supportURL = "https://localhost/support/"' "reserved/local host"
expect_release_failure "link-local-url" '.records.ios.localizations[1].supportURL = "https://169.254.10.20/support/"' "reserved/local host"
expect_release_failure "query-url" '.records.ios.localizations[0].privacyPolicyURL = "https://fixture.agentisland.app/privacy/?candidate=1"' "query"
expect_release_failure "mac-category" '.records.macos.categories.primary = "productivity" | .records.macos.categories.secondary = "developer-tools"' "must remain developer-tools"
expect_platform_structural_failure "missing-made-for-kids" 'del(.records.ios.commerce.madeForKids)' "missing keys" "ios"
expect_release_failure "export-unresolved" '.records.ios.commerce.exportCompliance.status = "unresolved"' "must record exempt"
expect_platform_structural_failure "standard-eula-text" '.records.macos.commerce.eula.customText = "Unexpected custom terms"' "standard EULA" "macos"
expect_release_failure "bad-tax" '.records.ios.commerce.pricing.taxCategory = "unknown tax"' "tax-category code"
expect_release_failure "impossible-date" '.records.macos.version.releaseMode = "scheduled" | .records.macos.version.scheduledReleaseAt = "2028-02-30T00:00:00Z"' "valid UTC timestamp"
expect_release_failure "identity-hash" '.identityLockSHA256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "does not match"
expect_release_failure "identity-bundle" '.records.macos.bundleIdentifier = "app.agentmonitor.other"' "must match the current macos project value"

# A non-null identity lock must use the complete profile/entitlements records
# emitted by apply-release-identity.sh; arbitrary objects fail closed globally.
/bin/cp "$FIXTURE_ROOT/.release/identity.lock.json" "$FIXTURE_ROOT/.release/identity-lock-good.json"
/usr/bin/jq '
  .provisioningProfile = {fake: true} |
  .generatedEntitlements = {fake: true}
' "$FIXTURE_ROOT/.release/identity-lock-good.json" >"$FIXTURE_ROOT/.release/identity.lock.json"
INVALID_PROFILE_LOCK_SHA="$(file_sha256 "$FIXTURE_ROOT/.release/identity.lock.json")"
/usr/bin/jq --arg sha "$INVALID_PROFILE_LOCK_SHA" '.identityLockSHA256 = $sha' \
  "$FIXTURE_ROOT/.release/app-store-submission.json" \
  >"$FIXTURE_ROOT/.release/case-identity-profile-shape.json"
/bin/chmod 0444 "$FIXTURE_ROOT/.release/case-identity-profile-shape.json"
if run_fixture ".release/case-identity-profile-shape.json" "$FIXTURE_ROOT/identity-profile-shape.json"; then
  echo "Malformed profile-bound identity lock unexpectedly passed" >&2
  exit 1
fi
/usr/bin/jq -e '
  .draftValid == false and
  (.platforms.macos.structuralErrors | any(contains("identity lock.provisioningProfile is missing keys"))) and
  (.platforms.ios.structuralErrors | any(contains("identity lock.provisioningProfile is missing keys")))
' "$FIXTURE_ROOT/identity-profile-shape.json" >/dev/null
/bin/mv "$FIXTURE_ROOT/.release/identity-lock-good.json" "$FIXTURE_ROOT/.release/identity.lock.json"

# Universal Purchase shares record-level commerce/category decisions and the
# localized app name/subtitle/public URLs.
expect_structural_failure "universal-localization" '
  .recordMode = "universal-purchase" |
  .records.ios.appResourceId = .records.macos.appResourceId |
  .records.ios.bundleIdentifier = .records.macos.bundleIdentifier |
  .records.ios.widgetBundleIdentifier = (.records.macos.bundleIdentifier + ".liveactivity") |
  .records.ios.sku = .records.macos.sku |
  .records.ios.localizations[0].subtitle = "Different subtitle"
' "matching zh-Hans subtitle"
/usr/bin/jq -e '
  .derivedChecks.universalPurchaseCategoriesConsistent == true and
  .derivedChecks.universalPurchaseLocalizedAppFieldsConsistent == false
' "$FIXTURE_ROOT/result-universal-localization.json" >/dev/null

# Duplicate members are rejected before JSON.parse can apply last-wins.
/usr/bin/printf '{"schemaVersion":1,"schemaVersion":1}\n' >"$FIXTURE_ROOT/.release/duplicate.json"
if run_fixture ".release/duplicate.json" "$FIXTURE_ROOT/duplicate-result.json"; then
  echo "Duplicate JSON key unexpectedly passed" >&2
  exit 1
fi
/usr/bin/jq -e '
  (.structuralErrors | any(contains("duplicate key"))) and
  (.platforms.macos.structuralErrors | any(contains("duplicate key"))) and
  (.platforms.ios.structuralErrors | any(contains("duplicate key")))
' "$FIXTURE_ROOT/duplicate-result.json" >/dev/null

# Finalized manifests may only be loaded from a real .release path.
/bin/cp "$FIXTURE_ROOT/.release/app-store-submission.json" "$FIXTURE_ROOT/Config/final-looking.json"
run_fixture "Config/final-looking.json" "$FIXTURE_ROOT/config-location.json"
/usr/bin/jq -e '
  .draftValid == true and
  .manifest.finalizedLocation == false and
  .localPreflightReady == false and
  (.releaseBlockers | any(contains("gitignored .release/")))
' "$FIXTURE_ROOT/config-location.json" >/dev/null

# Symlinks and lexical path ambiguity are global structural failures.
/bin/ln -s app-store-submission.json "$FIXTURE_ROOT/.release/manifest-link.json"
if run_fixture ".release/manifest-link.json" "$FIXTURE_ROOT/manifest-link-result.json"; then
  echo "Symlinked manifest unexpectedly passed" >&2
  exit 1
fi
/usr/bin/jq -e '
  (.platforms.macos.structuralErrors | any(contains("symbolic-link"))) and
  (.platforms.ios.structuralErrors | any(contains("symbolic-link")))
' "$FIXTURE_ROOT/manifest-link-result.json" >/dev/null

for unsafe in "$FIXTURE_ROOT/.release/app-store-submission.json" "./.release/app-store-submission.json" "../escape.json"; do
  if (
    cd "$FIXTURE_ROOT"
    AGENT_ISLAND_APP_STORE_SUBMISSION="$unsafe" \
      node scripts/validate-app-store-submission.mjs >"$FIXTURE_ROOT/unsafe-path.json"
  ); then
    echo "Unsafe configured manifest path unexpectedly passed: $unsafe" >&2
    exit 1
  fi
  /usr/bin/jq -e '
    (.platforms.macos.structuralErrors | length > 0) and
    (.platforms.ios.structuralErrors | length > 0)
  ' "$FIXTURE_ROOT/unsafe-path.json" >/dev/null
done

# The authoritative store validator is part of the green decision. Keep the
# evidence hash synchronized, then break a screenshot attestation: metadata is
# still well formed, but the Mac manifest-ready gate must close.
/bin/cp "$FIXTURE_ROOT/.release/store-screenshot-evidence.json" "$FIXTURE_ROOT/.release/store-evidence-good.json"
/usr/bin/jq '.candidates[0].screenshots[0].attestations.exactCandidateBuild = false' \
  "$FIXTURE_ROOT/.release/store-evidence-good.json" \
  >"$FIXTURE_ROOT/.release/store-screenshot-evidence.json"
BROKEN_EVIDENCE_SHA="$(file_sha256 "$FIXTURE_ROOT/.release/store-screenshot-evidence.json")"
/usr/bin/jq --arg sha "$BROKEN_EVIDENCE_SHA" '.screenshotEvidenceSHA256 = $sha' \
  "$FIXTURE_ROOT/.release/app-store-submission.json" \
  >"$FIXTURE_ROOT/.release/case-store-gate.json"
/bin/chmod 0444 "$FIXTURE_ROOT/.release/case-store-gate.json"
run_fixture ".release/case-store-gate.json" "$FIXTURE_ROOT/store-gate-result.json"
/usr/bin/jq -e '
  .storeAssets.platforms.macos.ready == false and
  .macAppStoreSubmissionManifestReady == false and
  .localPreflightReady == false and
  (.platforms.macos.releaseBlockers | any(contains("authoritative store asset validator")))
' "$FIXTURE_ROOT/store-gate-result.json" >/dev/null
/bin/mv "$FIXTURE_ROOT/.release/store-evidence-good.json" "$FIXTURE_ROOT/.release/store-screenshot-evidence.json"

# The schema and implementation key sets are executable invariants.
/bin/cp "$FIXTURE_ROOT/docs/release/APP_STORE_SUBMISSION.schema.json" "$FIXTURE_ROOT/docs/release/schema-good.json"
/usr/bin/jq '."$defs".commerce.required |= map(select(. != "madeForKids"))' \
  "$FIXTURE_ROOT/docs/release/schema-good.json" \
  >"$FIXTURE_ROOT/docs/release/APP_STORE_SUBMISSION.schema.json"
if run_fixture ".release/app-store-submission.json" "$FIXTURE_ROOT/schema-divergence.json"; then
  echo "Schema/implementation divergence unexpectedly passed" >&2
  exit 1
fi
/usr/bin/jq -e '
  .schemaContract.implementationKeysBound == false and
  (.structuralErrors | any(contains("schema commerce keys diverge")))
' "$FIXTURE_ROOT/schema-divergence.json" >/dev/null
/bin/mv "$FIXTURE_ROOT/docs/release/schema-good.json" "$FIXTURE_ROOT/docs/release/APP_STORE_SUBMISSION.schema.json"

set +e
node "$VALIDATOR" --unknown >/dev/null 2>&1
UNKNOWN_STATUS=$?
set -e
[[ "$UNKNOWN_STATUS" -eq 2 ]] || {
  echo "Unknown CLI option did not exit 2" >&2
  exit 1
}

echo "App Store submission manifest validation tests passed"
