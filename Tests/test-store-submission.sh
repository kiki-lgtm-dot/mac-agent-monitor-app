#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
VALIDATOR="$PROJECT_DIR/scripts/validate-store-submission.mjs"
RESULT="$(mktemp /private/tmp/agentisland-store-validation.XXXXXX)"
FIXTURE_ROOT="$(mktemp -d /private/tmp/agentisland-store-fixture.XXXXXX)"
trap '/bin/rm -f "$RESULT"; /bin/rm -rf "$FIXTURE_ROOT"' EXIT HUP INT TERM
unset AGENT_ISLAND_STORE_SCREENSHOT_EVIDENCE

node "$VALIDATOR" >"$RESULT"
/usr/bin/jq -e '
  .schemaVersion == 1 and
  .mode == "draft" and
  .draftValid == true and
  .releaseReady == false and
  .storeSubmissionAssetsReady == .releaseReady and
  .macStoreSubmissionAssetsReady == false and
  .iosStoreSubmissionAssetsReady == false and
  (.macStoreSubmissionBlockers | type == "array") and
  (.iosStoreSubmissionBlockers | type == "array") and
  (.macStoreSubmissionStructuralErrors | type == "array") and
  (.iosStoreSubmissionStructuralErrors | type == "array") and
  (.macStoreSubmissionBlockers | any(startswith("docs/release/APP_STORE_METADATA.md:"))) and
  (.macStoreSubmissionBlockers | all(startswith("docs/release/IOS_APP_STORE_AND_TESTFLIGHT_METADATA.md:") | not)) and
  (.iosStoreSubmissionBlockers | any(startswith("docs/release/IOS_APP_STORE_AND_TESTFLIGHT_METADATA.md:"))) and
  (.iosStoreSubmissionBlockers | all(startswith("docs/release/APP_STORE_METADATA.md:") | not)) and
  (.macStoreSubmissionBlockers | any(startswith("macos/zh-Hans:"))) and
  (.macStoreSubmissionBlockers | all(startswith("ios/") | not)) and
  (.iosStoreSubmissionBlockers | any(startswith("ios/zh-Hans:"))) and
  (.iosStoreSubmissionBlockers | all(startswith("macos/") | not)) and
  (.macStoreSubmissionBlockers | any(contains("PRIVACY_POLICY_ZH.md"))) and
  (.iosStoreSubmissionBlockers | any(contains("PRIVACY_POLICY_ZH.md"))) and
  (.macStoreSubmissionBlockers | any(contains("public Support URL"))) and
  (.iosStoreSubmissionBlockers | any(contains("public Support URL"))) and
  .icons.ready == true and
  .icons.macOS.valid == true and
  .icons.iOS.ready == true and
  .screenshotEvidence.path == ".release/store-screenshot-evidence.json" and
  .screenshotEvidence.platforms.macos.ready == false and
  .screenshotEvidence.platforms.ios.ready == false and
  (.metadata | length == 4) and
  (.submissionDocuments | length == 7) and
  (.submissionDocuments | all(
    (.unresolvedPlaceholders | type == "array") and
    (.releaseDraftSentinels | type == "array")
  )) and
  (.appPrivacy.draftValid | type == "boolean") and
  (.appPrivacy.sourcePrivacyReady | type == "boolean") and
  (.appPrivacy.releaseEvidenceReady | type == "boolean") and
  (.appPrivacy.releaseReady | type == "boolean") and
  .appPrivacy.releaseEvidenceReady == false and
  .appPrivacy.releaseReady == false and
  (.supportContact.path | endswith("docs/site/support/index.html")) and
  (.supportContact.emailLinks == []) and
  (.supportContact.telephoneLinks == []) and
  (.supportContact.addressBlocks == 0) and
  (.supportContact.configured == false) and
  (.validatorSelfTests.placeholderParser == true) and
  (.validatorSelfTests.releaseDraftSentinelParser == true) and
  (.validatorSelfTests.storeMarkupParser == true) and
  (.metadata | all(
    .measurements.name.value == "MAC版灵动岛--Agent运行监测" and
    .measurements.name.measured >= 2 and .measurements.name.measured <= 30 and
    .measurements.subtitle.measured <= 30 and
    .measurements.promotionalText.measured <= 170 and
    .measurements.description.measured <= 4000 and
    .measurements.keywords.measured <= 100
  )) and
  (.referenceScreenshots | length >= 1) and
  (.referenceScreenshots | all(.storeEligibleAsMacScreenshot == false)) and
  (.releaseBlockers | all(contains("known conflicted release name") | not)) and
  (.releaseBlockers | any(contains("unresolved placeholder"))) and
  (.releaseBlockers | any(contains("release document still contains"))) and
  (.releaseBlockers | any(contains("App Privacy evidence.path does not exist"))) and
  (.releaseBlockers | any(contains("public Support URL has no actual"))) and
  (.releaseBlockers | any(contains("Store screenshot evidence.path does not exist"))) and
  (.releaseBlockers | any(contains("expected 1-10 final screenshots")))
' "$RESULT" >/dev/null

if node "$VALIDATOR" --release >/dev/null 2>&1; then
  echo "Store submission validator accepted known placeholders, draft sentinels, missing evidence, or missing screenshots" >&2
  exit 1
fi

# Build an isolated, release-ready fixture so each platform gate can be broken
# independently without depending on the repository's intentionally incomplete
# real submission material.
/bin/mkdir -p \
  "$FIXTURE_ROOT/scripts" \
  "$FIXTURE_ROOT/docs/release" \
  "$FIXTURE_ROOT/docs/site/support" \
  "$FIXTURE_ROOT/docs/release-assets/macos/zh-Hans" \
  "$FIXTURE_ROOT/docs/release-assets/macos/en-US" \
  "$FIXTURE_ROOT/docs/release-assets/ios/zh-Hans" \
  "$FIXTURE_ROOT/docs/release-assets/ios/en-US" \
  "$FIXTURE_ROOT/dist" \
  "$FIXTURE_ROOT/.release" \
  "$FIXTURE_ROOT/Resources" \
  "$FIXTURE_ROOT/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset"
/bin/cp "$VALIDATOR" "$FIXTURE_ROOT/scripts/validate-store-submission.mjs"
/bin/cp "$PROJECT_DIR/Resources/AgentIsland.icns" "$FIXTURE_ROOT/Resources/AgentIsland.icns"

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
      {
        platform: "macOS",
        path: "dist/AgentMonitor.pkg",
        sha256: sha256("dist/AgentMonitor.pkg"),
        bundleID: "app.agentmonitor.mac",
        version: "1.0.0",
        build: "1"
      },
      {
        platform: "iOS",
        path: "dist/AgentMonitor.ipa",
        sha256: sha256("dist/AgentMonitor.ipa"),
        bundleID: "app.agentmonitor.ios",
        version: "1.0.0",
        build: "1"
      }
    ]
  },
  structuralErrors: [],
  releaseBlockers: [],
}));
EOF

/bin/cat >"$FIXTURE_ROOT/docs/release/APP_STORE_METADATA.md" <<'EOF'
# macOS Store Metadata

## 简体中文（zh-Hans）
### 名称
灵动监控
### 副标题
本地任务状态
### 推广文本
清晰查看本地任务进度。
### 描述
用于监控本地任务。
### 关键词
任务监控,智能工具

## English (U.S.)
### Name
Ready Monitor
### Subtitle
Local task status
### Promotional text
See local task progress clearly.
### Description
Monitor local tasks from one focused view.
### Keywords
agents,monitoring
EOF

/bin/cat >"$FIXTURE_ROOT/docs/release/IOS_APP_STORE_AND_TESTFLIGHT_METADATA.md" <<'EOF'
# iOS Store Metadata

## 2. 简体中文（zh-Hans）
### 名称
灵动监控
### 副标题
移动任务状态
### 推广文本
随时查看任务进度。
### 描述
用于查看移动任务状态。
### 关键词
任务监控,智能工具

## 3. English (U.S.)
### Name
Ready Monitor
### Subtitle
Mobile task status
### Promotional text
See task progress wherever you are.
### Description
Monitor mobile task status from one focused view.
### Keywords
agents,monitoring
EOF

for document in \
  APP_REVIEW_NOTES.md \
  IOS_APP_REVIEW_NOTES.md \
  PRIVACY_POLICY_ZH.md \
  PRIVACY_POLICY_EN.md \
  APP_PRIVACY_SUBMISSION_WORKSHEET.md; do
  /usr/bin/printf '# Final submission material\n\nVerified release content.\n' \
    >"$FIXTURE_ROOT/docs/release/$document"
done

/bin/cat >"$FIXTURE_ROOT/docs/site/support/index.html" <<'EOF'
<!doctype html><html><body><a href="mailto:support@agentisland.app">Email support</a></body></html>
EOF

SCREENSHOT_SOURCE="$PROJECT_DIR/docs/media/mac-agent-monitor-overview-en.png"
for locale in zh-Hans en-US; do
  LOCALE_SOURCE="$PROJECT_DIR/docs/media/mac-agent-monitor-overview-en.png"
  [[ "$locale" == zh-Hans ]] && \
    LOCALE_SOURCE="$PROJECT_DIR/docs/media/mac-agent-monitor-overview-zh.png"
  # These resized files are isolated parser fixtures, not release screenshots;
  # the positive record below simulates the operator's attestation contract.
  /usr/bin/sips -s format jpeg -z 800 1280 "$LOCALE_SOURCE" \
    --out "$FIXTURE_ROOT/docs/release-assets/macos/$locale/final.jpg" >/dev/null
  /usr/bin/sips -s format jpeg -z 2736 1260 "$LOCALE_SOURCE" \
    --out "$FIXTURE_ROOT/docs/release-assets/ios/$locale/final.jpg" >/dev/null
done
/usr/bin/sips -s format png -z 120 120 "$SCREENSHOT_SOURCE" \
  --out "$FIXTURE_ROOT/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Icon120.png" \
  >/dev/null
/usr/bin/sips -s format png -z 180 180 "$SCREENSHOT_SOURCE" \
  --out "$FIXTURE_ROOT/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Icon180.png" \
  >/dev/null
/usr/bin/sips -s format png -z 1024 1024 "$SCREENSHOT_SOURCE" \
  --out "$FIXTURE_ROOT/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Icon1024.png" \
  >/dev/null
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

/usr/bin/printf 'macOS signed candidate fixture\n' >"$FIXTURE_ROOT/dist/AgentMonitor.pkg"
/usr/bin/printf 'iOS signed candidate fixture\n' >"$FIXTURE_ROOT/dist/AgentMonitor.ipa"

file_sha256() {
  LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

MAC_ARTIFACT_SHA="$(file_sha256 "$FIXTURE_ROOT/dist/AgentMonitor.pkg")"
IOS_ARTIFACT_SHA="$(file_sha256 "$FIXTURE_ROOT/dist/AgentMonitor.ipa")"
MAC_ZH_SHA="$(file_sha256 "$FIXTURE_ROOT/docs/release-assets/macos/zh-Hans/final.jpg")"
MAC_EN_SHA="$(file_sha256 "$FIXTURE_ROOT/docs/release-assets/macos/en-US/final.jpg")"
IOS_ZH_SHA="$(file_sha256 "$FIXTURE_ROOT/docs/release-assets/ios/zh-Hans/final.jpg")"
IOS_EN_SHA="$(file_sha256 "$FIXTURE_ROOT/docs/release-assets/ios/en-US/final.jpg")"

FIXTURE_VALIDATOR="$FIXTURE_ROOT/scripts/validate-store-submission.mjs"
FIXTURE_RESULT="$FIXTURE_ROOT/result.json"

expect_fixture_release_failure() {
  if node "$FIXTURE_VALIDATOR" --release >"$FIXTURE_RESULT"; then
    echo "Store submission fixture unexpectedly passed release validation" >&2
    exit 1
  fi
}

# Correctly-sized files alone are not release proof. The validator must require
# one-to-one hashes and explicit attestations bound to the candidate artifact.
expect_fixture_release_failure
/usr/bin/jq -e '
  .macStoreSubmissionAssetsReady == false and
  .iosStoreSubmissionAssetsReady == false and
  .screenshotEvidence.platforms.macos.ready == false and
  .screenshotEvidence.platforms.ios.ready == false and
  (.releaseBlockers | any(contains("Store screenshot evidence.path does not exist")))
' "$FIXTURE_RESULT" >/dev/null

/usr/bin/jq -n \
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
        platform: "macos",
        bundleIdentifier: "app.agentmonitor.mac",
        version: "1.0.0",
        build: "1",
        artifact: {path: "dist/AgentMonitor.pkg", sha256: $macArtifactSHA},
        screenshots: [
          {
            path: "docs/release-assets/macos/zh-Hans/final.jpg",
            sha256: $macZhSHA,
            locale: "zh-Hans",
            device: "Mac 1440 by 900 display",
            capturedAt: "2026-09-03T12:00:00Z",
            source: "exact-candidate-build",
            attestations: attestations
          },
          {
            path: "docs/release-assets/macos/en-US/final.jpg",
            sha256: $macEnSHA,
            locale: "en-US",
            device: "Mac 1440 by 900 display",
            capturedAt: "2026-09-03T12:01:00Z",
            source: "exact-candidate-build",
            attestations: attestations
          }
        ]
      },
      {
        platform: "ios",
        bundleIdentifier: "app.agentmonitor.ios",
        version: "1.0.0",
        build: "1",
        artifact: {path: "dist/AgentMonitor.ipa", sha256: $iosArtifactSHA},
        screenshots: [
          {
            path: "docs/release-assets/ios/zh-Hans/final.jpg",
            sha256: $iosZhSHA,
            locale: "zh-Hans",
            device: "6.9-inch iPhone",
            capturedAt: "2026-09-03T12:02:00Z",
            source: "exact-candidate-build",
            attestations: attestations
          },
          {
            path: "docs/release-assets/ios/en-US/final.jpg",
            sha256: $iosEnSHA,
            locale: "en-US",
            device: "6.9-inch iPhone",
            capturedAt: "2026-09-03T12:03:00Z",
            source: "exact-candidate-build",
            attestations: attestations
          }
        ]
      }
    ]
  }
' >"$FIXTURE_ROOT/.release/store-screenshot-evidence.json"

node "$FIXTURE_VALIDATOR" --release >"$FIXTURE_RESULT"
/usr/bin/jq -e '
  .draftValid == true and
  .macStoreSubmissionAssetsReady == true and
  .iosStoreSubmissionAssetsReady == true and
  .storeSubmissionAssetsReady == true and
  .releaseReady == true and
  .macStoreSubmissionBlockers == [] and
  .iosStoreSubmissionBlockers == [] and
  .macStoreSubmissionStructuralErrors == [] and
  .iosStoreSubmissionStructuralErrors == [] and
  .screenshotEvidence.platforms.macos.ready == true and
  .screenshotEvidence.platforms.ios.ready == true and
  .screenshotEvidence.platforms.macos.candidate.candidateIdentityVerified == true and
  .screenshotEvidence.platforms.ios.candidate.candidateIdentityVerified == true
' "$FIXTURE_RESULT" >/dev/null

# Identical image bytes cannot stand in for two storefront languages, even if
# the paths and the self-attested locale strings differ.
/bin/cp "$FIXTURE_ROOT/docs/release-assets/macos/en-US/final.jpg" \
  "$FIXTURE_ROOT/held-mac-en.jpg"
/bin/cp "$FIXTURE_ROOT/.release/store-screenshot-evidence.json" \
  "$FIXTURE_ROOT/held-evidence.json"
/bin/cp "$FIXTURE_ROOT/docs/release-assets/macos/zh-Hans/final.jpg" \
  "$FIXTURE_ROOT/docs/release-assets/macos/en-US/final.jpg"
DUPLICATE_MAC_SHA="$(file_sha256 "$FIXTURE_ROOT/docs/release-assets/macos/en-US/final.jpg")"
/usr/bin/jq --arg sha "$DUPLICATE_MAC_SHA" \
  '.candidates[0].screenshots[1].sha256 = $sha' \
  "$FIXTURE_ROOT/held-evidence.json" \
  >"$FIXTURE_ROOT/.release/store-screenshot-evidence.json"
expect_fixture_release_failure
/usr/bin/jq -e '
  .macStoreSubmissionAssetsReady == false and
  .iosStoreSubmissionAssetsReady == true and
  (.macStoreSubmissionBlockers | any(contains("must not reuse identical image bytes across locales")))
' "$FIXTURE_RESULT" >/dev/null
/bin/mv "$FIXTURE_ROOT/held-mac-en.jpg" \
  "$FIXTURE_ROOT/docs/release-assets/macos/en-US/final.jpg"
/bin/mv "$FIXTURE_ROOT/held-evidence.json" \
  "$FIXTURE_ROOT/.release/store-screenshot-evidence.json"

# An iOS screenshot failure must not make the otherwise complete Mac assets red.
/bin/mv "$FIXTURE_ROOT/docs/release-assets/ios/en-US/final.jpg" "$FIXTURE_ROOT/held-ios.jpg"
expect_fixture_release_failure
/usr/bin/jq -e '
  .macStoreSubmissionAssetsReady == true and
  .iosStoreSubmissionAssetsReady == false and
  .storeSubmissionAssetsReady == false and
  .releaseReady == false and
  .macStoreSubmissionBlockers == [] and
  (.iosStoreSubmissionBlockers | any(startswith("ios/en-US:")))
' "$FIXTURE_RESULT" >/dev/null
/bin/mv "$FIXTURE_ROOT/held-ios.jpg" "$FIXTURE_ROOT/docs/release-assets/ios/en-US/final.jpg"

# A screenshot changed after review must invalidate only its bound platform.
/bin/cp "$FIXTURE_ROOT/docs/release-assets/macos/zh-Hans/final.jpg" "$FIXTURE_ROOT/held-mac-zh.jpg"
/usr/bin/printf 'changed after screenshot review\n' \
  >>"$FIXTURE_ROOT/docs/release-assets/macos/zh-Hans/final.jpg"
expect_fixture_release_failure
/usr/bin/jq -e '
  .macStoreSubmissionAssetsReady == false and
  .iosStoreSubmissionAssetsReady == true and
  (.macStoreSubmissionBlockers | any(contains("screenshots[0].sha256 does not match the file"))) and
  .iosStoreSubmissionBlockers == []
' "$FIXTURE_RESULT" >/dev/null
/bin/mv "$FIXTURE_ROOT/held-mac-zh.jpg" \
  "$FIXTURE_ROOT/docs/release-assets/macos/zh-Hans/final.jpg"

# Filename extensions are not trusted as image-format proof.
/bin/cp "$FIXTURE_ROOT/docs/release-assets/macos/zh-Hans/final.jpg" \
  "$FIXTURE_ROOT/docs/release-assets/macos/zh-Hans/disguised.png"
expect_fixture_release_failure
/usr/bin/jq -e '
  .macStoreSubmissionAssetsReady == false and
  .iosStoreSubmissionAssetsReady == true and
  (.macStoreSubmissionBlockers | any(contains("actual jpeg format must match the filename extension")))
' "$FIXTURE_RESULT" >/dev/null
/bin/mv "$FIXTURE_ROOT/docs/release-assets/macos/zh-Hans/disguised.png" \
  "$FIXTURE_ROOT/held-disguised.png"

# A symlink remains invalid even when it resolves to a valid in-repository image.
/bin/ln -s final.jpg "$FIXTURE_ROOT/docs/release-assets/macos/zh-Hans/linked.jpg"
expect_fixture_release_failure
/usr/bin/jq -e '
  .macStoreSubmissionAssetsReady == false and
  .iosStoreSubmissionAssetsReady == true and
  (.macStoreSubmissionBlockers | any(contains("must not contain a symbolic-link component")))
' "$FIXTURE_RESULT" >/dev/null
/bin/mv "$FIXTURE_ROOT/docs/release-assets/macos/zh-Hans/linked.jpg" \
  "$FIXTURE_ROOT/held-linked.jpg"

# The evidence document itself cannot be a symlink.
/bin/mv "$FIXTURE_ROOT/.release/store-screenshot-evidence.json" \
  "$FIXTURE_ROOT/held-evidence.json"
/bin/ln -s ../held-evidence.json "$FIXTURE_ROOT/.release/store-screenshot-evidence.json"
expect_fixture_release_failure
/usr/bin/jq -e '
  .macStoreSubmissionAssetsReady == false and
  .iosStoreSubmissionAssetsReady == false and
  (.releaseBlockers | any(contains("Store screenshot evidence.path must not contain a symbolic-link component")))
' "$FIXTURE_RESULT" >/dev/null
/bin/mv "$FIXTURE_ROOT/.release/store-screenshot-evidence.json" \
  "$FIXTURE_ROOT/held-evidence-link.json"
/bin/mv "$FIXTURE_ROOT/held-evidence.json" \
  "$FIXTURE_ROOT/.release/store-screenshot-evidence.json"

# A syntactically valid but different bundle/build tuple is not the reviewed
# release candidate, even when it points at the same artifact bytes.
/bin/cp "$FIXTURE_ROOT/.release/store-screenshot-evidence.json" \
  "$FIXTURE_ROOT/held-evidence.json"
/usr/bin/jq '.candidates[0].bundleIdentifier = "app.agentmonitor.other"' \
  "$FIXTURE_ROOT/held-evidence.json" \
  >"$FIXTURE_ROOT/.release/store-screenshot-evidence.json"
expect_fixture_release_failure
/usr/bin/jq -e '
  .macStoreSubmissionAssetsReady == false and
  .iosStoreSubmissionAssetsReady == true and
  .screenshotEvidence.platforms.macos.candidate.candidateIdentityVerified == false and
  (.macStoreSubmissionBlockers | any(contains("must exactly match one candidate archive")))
' "$FIXTURE_RESULT" >/dev/null
/bin/mv "$FIXTURE_ROOT/held-evidence.json" \
  "$FIXTURE_ROOT/.release/store-screenshot-evidence.json"

# Lexical path escape and unknown schema fields both fail closed.
/bin/cp "$FIXTURE_ROOT/.release/store-screenshot-evidence.json" \
  "$FIXTURE_ROOT/held-evidence.json"
/usr/bin/jq '.candidates[0].artifact.path = "../outside.pkg" | .candidates[0].unexpected = true' \
  "$FIXTURE_ROOT/held-evidence.json" \
  >"$FIXTURE_ROOT/.release/store-screenshot-evidence.json"
expect_fixture_release_failure
/usr/bin/jq -e '
  .macStoreSubmissionAssetsReady == false and
  .iosStoreSubmissionAssetsReady == true and
  (.macStoreSubmissionBlockers | any(contains("must contain exactly"))) and
  (.macStoreSubmissionBlockers | any(contains("must stay under dist/")))
' "$FIXTURE_RESULT" >/dev/null
/bin/mv "$FIXTURE_ROOT/held-evidence.json" \
  "$FIXTURE_ROOT/.release/store-screenshot-evidence.json"

# A Mac review-notes failure must remain Mac-only.
/bin/mv "$FIXTURE_ROOT/docs/release/APP_REVIEW_NOTES.md" "$FIXTURE_ROOT/held-mac-review-notes.md"
expect_fixture_release_failure
/usr/bin/jq -e '
  .macStoreSubmissionAssetsReady == false and
  .iosStoreSubmissionAssetsReady == true and
  .storeSubmissionAssetsReady == false and
  .releaseReady == false and
  (.macStoreSubmissionStructuralErrors | any(contains("APP_REVIEW_NOTES.md"))) and
  .iosStoreSubmissionStructuralErrors == []
' "$FIXTURE_RESULT" >/dev/null
/bin/mv "$FIXTURE_ROOT/held-mac-review-notes.md" "$FIXTURE_ROOT/docs/release/APP_REVIEW_NOTES.md"

# The packaged macOS icon is a Mac-only structural requirement.
/bin/mv "$FIXTURE_ROOT/Resources/AgentIsland.icns" "$FIXTURE_ROOT/held-AgentIsland.icns"
expect_fixture_release_failure
/usr/bin/jq -e '
  .macStoreSubmissionAssetsReady == false and
  .iosStoreSubmissionAssetsReady == true and
  (.macStoreSubmissionStructuralErrors | any(contains("invalid macOS AppIcon asset"))) and
  .iosStoreSubmissionStructuralErrors == []
' "$FIXTURE_RESULT" >/dev/null
/bin/mv "$FIXTURE_ROOT/held-AgentIsland.icns" "$FIXTURE_ROOT/Resources/AgentIsland.icns"

# AppIcon validity belongs to iOS only.
/bin/mv \
  "$FIXTURE_ROOT/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Icon120.png" \
  "$FIXTURE_ROOT/held-icon.png"
expect_fixture_release_failure
/usr/bin/jq -e '
  .macStoreSubmissionAssetsReady == true and
  .iosStoreSubmissionAssetsReady == false and
  .storeSubmissionAssetsReady == false and
  .releaseReady == false and
  .macStoreSubmissionStructuralErrors == [] and
  (.iosStoreSubmissionStructuralErrors | any(contains("invalid iOS AppIcon asset")))
' "$FIXTURE_RESULT" >/dev/null
/bin/mv \
  "$FIXTURE_ROOT/held-icon.png" \
  "$FIXTURE_ROOT/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Icon120.png"

ICON_MANIFEST="$FIXTURE_ROOT/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json"

# Malformed Contents.json must return structured failure instead of crashing.
/bin/cp "$ICON_MANIFEST" "$FIXTURE_ROOT/held-icon-manifest.json"
/usr/bin/printf '{ invalid json\n' >"$ICON_MANIFEST"
expect_fixture_release_failure
/usr/bin/jq -e '
  .macStoreSubmissionAssetsReady == true and
  .iosStoreSubmissionAssetsReady == false and
  (.iosStoreSubmissionStructuralErrors | any(contains("manifest is not valid JSON")))
' "$FIXTURE_RESULT" >/dev/null
/bin/mv "$FIXTURE_ROOT/held-icon-manifest.json" "$ICON_MANIFEST"

# Required storefront slots cannot be omitted from an otherwise valid manifest.
/bin/cp "$ICON_MANIFEST" "$FIXTURE_ROOT/held-icon-manifest.json"
/usr/bin/jq '.images = [.images[] | select(.scale != "2x")]' \
  "$FIXTURE_ROOT/held-icon-manifest.json" >"$ICON_MANIFEST"
expect_fixture_release_failure
/usr/bin/jq -e '
  .macStoreSubmissionAssetsReady == true and
  .iosStoreSubmissionAssetsReady == false and
  (.iosStoreSubmissionStructuralErrors | any(contains("required slot: iphone|60x60|2x")))
' "$FIXTURE_RESULT" >/dev/null
/bin/mv "$FIXTURE_ROOT/held-icon-manifest.json" "$ICON_MANIFEST"

# Reusing one PNG for multiple AppIcon slots is rejected.
/bin/cp "$ICON_MANIFEST" "$FIXTURE_ROOT/held-icon-manifest.json"
/usr/bin/jq '.images[1].filename = .images[0].filename' \
  "$FIXTURE_ROOT/held-icon-manifest.json" >"$ICON_MANIFEST"
expect_fixture_release_failure
/usr/bin/jq -e '
  .macStoreSubmissionAssetsReady == true and
  .iosStoreSubmissionAssetsReady == false and
  (.iosStoreSubmissionStructuralErrors | any(contains("unique PNG file")))
' "$FIXTURE_RESULT" >/dev/null
/bin/mv "$FIXTURE_ROOT/held-icon-manifest.json" "$ICON_MANIFEST"

# Shared public support material gates both platforms.
/bin/mv "$FIXTURE_ROOT/docs/site/support/index.html" "$FIXTURE_ROOT/held-support.html"
expect_fixture_release_failure
/usr/bin/jq -e '
  .macStoreSubmissionAssetsReady == false and
  .iosStoreSubmissionAssetsReady == false and
  .storeSubmissionAssetsReady == false and
  .releaseReady == false and
  (.macStoreSubmissionStructuralErrors | any(contains("missing public support page"))) and
  (.iosStoreSubmissionStructuralErrors | any(contains("missing public support page")))
' "$FIXTURE_RESULT" >/dev/null

echo "Store submission draft validation and per-platform release fixture tests passed"
