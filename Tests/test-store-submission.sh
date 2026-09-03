#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
VALIDATOR="$PROJECT_DIR/scripts/validate-store-submission.mjs"
RESULT="$(mktemp /private/tmp/agentisland-store-validation.XXXXXX)"
trap '/bin/rm -f "$RESULT"' EXIT HUP INT TERM

node "$VALIDATOR" >"$RESULT"
/usr/bin/jq -e '
  .schemaVersion == 1 and
  .mode == "draft" and
  .draftValid == true and
  .releaseReady == false and
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
  (.validatorSelfTests.placeholderParser == true) and
  (.validatorSelfTests.releaseDraftSentinelParser == true) and
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
  (.releaseBlockers | any(contains("expected 1-10 final screenshots")))
' "$RESULT" >/dev/null

if node "$VALIDATOR" --release >/dev/null 2>&1; then
  echo "Store submission validator accepted known placeholders, draft sentinels, missing evidence, or missing screenshots" >&2
  exit 1
fi

echo "Store submission draft validation passed; release-only blockers remain enforced"
