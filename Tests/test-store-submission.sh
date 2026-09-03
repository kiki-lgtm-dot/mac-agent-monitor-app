#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
VALIDATOR="$PROJECT_DIR/scripts/validate-store-submission.mjs"
RESULT="$(mktemp /private/tmp/agentisland-store-validation.XXXXXX)"
FIXTURE_ROOT="$(mktemp -d /private/tmp/agentisland-store-fixture.XXXXXX)"
trap '/bin/rm -f "$RESULT"; /bin/rm -rf "$FIXTURE_ROOT"' EXIT HUP INT TERM

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
  "$FIXTURE_ROOT/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset"
/bin/cp "$VALIDATOR" "$FIXTURE_ROOT/scripts/validate-store-submission.mjs"

/bin/cat >"$FIXTURE_ROOT/scripts/validate-app-privacy.mjs" <<'EOF'
#!/usr/bin/env node
process.stdout.write(JSON.stringify({
  draftValid: true,
  sourcePrivacyReady: true,
  releaseEvidenceReady: true,
  releaseReady: true,
  releaseEvidencePath: ".release/app-privacy-evidence.json",
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
  /usr/bin/sips -s format jpeg -z 800 1280 "$SCREENSHOT_SOURCE" \
    --out "$FIXTURE_ROOT/docs/release-assets/macos/$locale/final.jpg" >/dev/null
  /usr/bin/sips -s format jpeg -z 2736 1260 "$SCREENSHOT_SOURCE" \
    --out "$FIXTURE_ROOT/docs/release-assets/ios/$locale/final.jpg" >/dev/null
done
/usr/bin/sips -s format png -z 20 20 "$SCREENSHOT_SOURCE" \
  --out "$FIXTURE_ROOT/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Icon20.png" \
  >/dev/null
/bin/cat >"$FIXTURE_ROOT/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json" <<'EOF'
{
  "images": [
    { "filename": "Icon20.png", "idiom": "iphone", "scale": "1x", "size": "20x20" }
  ],
  "info": { "author": "xcode", "version": 1 }
}
EOF

FIXTURE_VALIDATOR="$FIXTURE_ROOT/scripts/validate-store-submission.mjs"
FIXTURE_RESULT="$FIXTURE_ROOT/result.json"
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
  .iosStoreSubmissionStructuralErrors == []
' "$FIXTURE_RESULT" >/dev/null

expect_fixture_release_failure() {
  if node "$FIXTURE_VALIDATOR" --release >"$FIXTURE_RESULT"; then
    echo "Store submission fixture unexpectedly passed release validation" >&2
    exit 1
  fi
}

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

# AppIcon validity belongs to iOS only.
/bin/mv \
  "$FIXTURE_ROOT/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Icon20.png" \
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
  "$FIXTURE_ROOT/ApplePlatforms/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Icon20.png"

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
