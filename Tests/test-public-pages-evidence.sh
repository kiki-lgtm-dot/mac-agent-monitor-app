#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
SOURCE_SCRIPT="$PROJECT_ROOT/scripts/capture-public-pages-evidence.mjs"
SCHEMA="$PROJECT_ROOT/docs/release/PUBLIC_PAGES_EVIDENCE.schema.json"
TEST_ROOT="$(mktemp -d /private/tmp/agentisland-public-pages.XXXXXX)"
trap '[[ "$TEST_ROOT" == /private/tmp/agentisland-public-pages.* ]] && /bin/rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

fail() {
  print -u2 -r -- "Public-pages evidence test failed: $*"
  exit 1
}

contains() {
  local marker="$1" path="$2"
  /usr/bin/grep -Fq -- "$marker" "$path" \
    || fail "$path is missing: $marker"
}

[[ -x "$SOURCE_SCRIPT" ]] || fail "capture-public-pages-evidence.mjs is missing or not executable"
node --check "$SOURCE_SCRIPT"
node "$SOURCE_SCRIPT" --help >"$TEST_ROOT/help.txt"
contains 'static HTML renderability screening only' "$TEST_ROOT/help.txt"
contains 'manually confirm visibility in a browser' "$TEST_ROOT/help.txt"
/usr/bin/jq -e '
  ."$schema" == "https://json-schema.org/draft/2020-12/schema" and
  (.description | contains("static HTML renderability screening")) and
  (.description | contains("browser-visible presentation still requires manual review")) and
  .additionalProperties == false and
  .properties.schemaVersion.const == 1 and
  .properties.pages.minItems == 2 and
  .properties.pages.maxItems == 2 and
  ."$defs".page.properties.bodySizeBytes.maximum == 1048576 and
  ."$defs".binding.properties.type.enum == ["identity-lock", "submission-manifest"] and
  (."$defs".binding.allOf | tostring | contains(".release/identity.lock.json")) and
  (."$defs".binding.allOf | tostring | contains(".release/app-store-submission.json")) and
  ."$defs".validations.required == [
    "productName", "bilingualLanguages", "pagePurpose", "contactOrDeletionPath"
  ] and
  (."$defs".validations.description | contains("not proof of actual browser visibility")) and
  (."$defs".httpsURL.pattern | contains("?"))
' "$SCHEMA" >/dev/null || fail "public-pages evidence schema contract is incomplete"

for marker in \
    'FIXED_ALLOWED_ORIGIN = "https://kiki-lgtm-dot.github.io"' \
    'MAX_RESPONSE_BYTES = 1024 * 1024' \
    'destination.origin !== initial.origin' \
    'socket.remoteAddress' \
    '64:ff9b:1::' \
    '2002::' \
    'identity lock binding must not be accessible by group or other users' \
    'identity lock envelope schemaVersion must equal 1' \
    'submission manifest product name differs from current xcconfig' \
    'DEFAULT_SUBMISSION_MANIFEST_RELATIVE_PATH = ".release/app-store-submission.json"' \
    'refusing to overwrite an existing public-pages evidence file' \
    'await link(temporary, output.absolutePath)' \
    'unixMode(snapshot.stats) !== 0o444' \
    'export async function verifyPublicPagesEvidence' \
    'evidence URLs differ from current xcconfig' \
    'public-pages evidence binding SHA-256 is stale'; do
  contains "$marker" "$SOURCE_SCRIPT"
done

FIXTURE_ROOT="$TEST_ROOT/project"
FIXTURE_SCRIPT="$FIXTURE_ROOT/scripts/capture-public-pages-evidence.mjs"
FIXTURE_CONFIG="$FIXTURE_ROOT/ApplePlatforms/iOS/Config/Project.xcconfig"
FIXTURE_MAC_CONFIG="$FIXTURE_ROOT/ApplePlatforms/macOS/Config/Project.xcconfig"
TRANSPORT_LOG="$TEST_ROOT/transport.log"
/bin/mkdir -p "$FIXTURE_ROOT/scripts" "$FIXTURE_ROOT/ApplePlatforms/iOS/Config" \
  "$FIXTURE_ROOT/ApplePlatforms/macOS/Config" "$FIXTURE_ROOT/Resources" \
  "$FIXTURE_ROOT/.release"
/bin/cp "$SOURCE_SCRIPT" "$FIXTURE_SCRIPT"
/bin/chmod 0755 "$FIXTURE_SCRIPT"

/bin/cat >"$FIXTURE_CONFIG" <<'EOF'
AGENT_ISLAND_DISPLAY_NAME = MAC版灵动岛--Agent运行监测
AGENT_ISLAND_APP_BUNDLE_ID = com.agentisland.fixture
AGENT_ISLAND_WIDGET_BUNDLE_ID = $(AGENT_ISLAND_APP_BUNDLE_ID).liveactivity
AGENT_ISLAND_ICLOUD_CONTAINER_ID = iCloud.com.agentisland.fixture
AGENT_ISLAND_CLOUDKIT_RECORD_TYPE = AgentIslandSnapshot
AGENT_ISLAND_CLOUDKIT_RECORD_NAME = latest
AGENT_ISLAND_CLOUDKIT_PAYLOAD_FIELD = payloadJSON
AGENT_ISLAND_URL_SLASH = /
AGENT_ISLAND_PRIVACY_POLICY_URL = https:$(AGENT_ISLAND_URL_SLASH)$(AGENT_ISLAND_URL_SLASH)kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/
AGENT_ISLAND_SUPPORT_URL = https:$(AGENT_ISLAND_URL_SLASH)$(AGENT_ISLAND_URL_SLASH)kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/
AGENT_ISLAND_DEVELOPMENT_TEAM = ABCDE12345
MARKETING_VERSION = 0.6.1
CURRENT_PROJECT_VERSION = 8
EOF
/bin/cp "$FIXTURE_CONFIG" "$TEST_ROOT/valid.xcconfig"
/bin/cat >"$FIXTURE_MAC_CONFIG" <<'EOF'
AGENT_ISLAND_MAC_APP_BUNDLE_ID = com.agentisland.fixture
MARKETING_VERSION = 0.6.1
CURRENT_PROJECT_VERSION = 8
EOF
/bin/cat >"$FIXTURE_ROOT/Resources/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.agentisland.fixture</string></dict></plist>
EOF
INFO_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$FIXTURE_ROOT/Resources/Info.plist" | /usr/bin/awk '{print $1}')"
IOS_CONFIG_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$FIXTURE_CONFIG" | /usr/bin/awk '{print $1}')"
MAC_CONFIG_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$FIXTURE_MAC_CONFIG" | /usr/bin/awk '{print $1}')"
/usr/bin/jq -n -S \
  --arg infoSha "$INFO_SHA" --arg iosSha "$IOS_CONFIG_SHA" --arg macSha "$MAC_CONFIG_SHA" '{
    schemaVersion: 1,
    firstAppliedAt: "2026-09-04T00:00:00Z",
    identity: {
      schemaVersion: 2,
      appStoreRecordMode: "universal-purchase",
      macOSAppBundleIdentifier: "com.agentisland.fixture",
      iOSAppBundleIdentifier: "com.agentisland.fixture",
      iOSWidgetBundleIdentifier: "com.agentisland.fixture.liveactivity",
      teamIdentifier: "ABCDE12345",
      iCloudContainerIdentifier: "iCloud.com.agentisland.fixture",
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
      {path: "Resources/Info.plist", sha256: $infoSha},
      {path: "ApplePlatforms/iOS/Config/Project.xcconfig", sha256: $iosSha},
      {path: "ApplePlatforms/macOS/Config/Project.xcconfig", sha256: $macSha}
    ]
  }' >"$FIXTURE_ROOT/.release/identity.lock.json"
/bin/chmod 0600 "$FIXTURE_ROOT/.release/identity.lock.json"
/usr/bin/jq -n --arg sha "$(printf '0%.0s' {1..64})" '{
  schemaVersion: 1,
  candidates: [
    {
      platform: "macos", bundleIdentifier: "com.agentisland.fixture", version: "0.6.1", build: "8",
      artifact: {path: "dist/AgentIsland.pkg", sha256: $sha},
      screenshots: [
        {path: "docs/release-assets/macos/zh-Hans/01-dashboard.png", sha256: $sha,
         locale: "zh-Hans", device: "macOS", capturedAt: "2026-09-04T00:00:00Z",
         source: "exact-candidate-build", attestations: {exactCandidateBuild: true, localizedForLocale: true,
           noSensitiveDataReviewed: true, notStretchedOrSynthetic: true}},
        {path: "docs/release-assets/macos/en-US/01-dashboard.png", sha256: $sha,
         locale: "en-US", device: "macOS", capturedAt: "2026-09-04T00:00:00Z",
         source: "exact-candidate-build", attestations: {exactCandidateBuild: true, localizedForLocale: true,
           noSensitiveDataReviewed: true, notStretchedOrSynthetic: true}}
      ]
    },
    {
      platform: "ios", bundleIdentifier: "com.agentisland.fixture", version: "0.6.1", build: "8",
      artifact: {path: "dist/AgentIsland.ipa", sha256: $sha},
      screenshots: [
        {path: "docs/release-assets/ios/zh-Hans/01-dashboard.png", sha256: $sha,
         locale: "zh-Hans", device: "iPhone 6.9-inch Display", capturedAt: "2026-09-04T00:00:00Z",
         source: "exact-candidate-build", attestations: {exactCandidateBuild: true, localizedForLocale: true,
           noSensitiveDataReviewed: true, notStretchedOrSynthetic: true}},
        {path: "docs/release-assets/ios/en-US/01-dashboard.png", sha256: $sha,
         locale: "en-US", device: "iPhone 6.9-inch Display", capturedAt: "2026-09-04T00:00:00Z",
         source: "exact-candidate-build", attestations: {exactCandidateBuild: true, localizedForLocale: true,
           noSensitiveDataReviewed: true, notStretchedOrSynthetic: true}}
      ]
    }
  ]
}' >"$FIXTURE_ROOT/.release/store-screenshot-evidence.json"
/bin/chmod 0444 "$FIXTURE_ROOT/.release/store-screenshot-evidence.json"
IDENTITY_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$FIXTURE_ROOT/.release/identity.lock.json" | /usr/bin/awk '{print $1}')"
SCREENSHOT_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$FIXTURE_ROOT/.release/store-screenshot-evidence.json" | /usr/bin/awk '{print $1}')"
/usr/bin/jq \
  --arg identitySha "$IDENTITY_SHA" --arg screenshotSha "$SCREENSHOT_SHA" '
    .identityLockSHA256 = $identitySha |
    .screenshotEvidenceSHA256 = $screenshotSha |
    .recordMode = "universal-purchase" |
    (.records.macos, .records.ios) |= (
      .appResourceId = "12345678" |
      .bundleIdentifier = "com.agentisland.fixture" |
      .sku = "AGENTISLAND-FIXTURE" |
      .version = {
        versionString: "0.6.1", buildNumber: "8", releaseKind: "initial", releaseMode: "manual",
        scheduledReleaseAt: null, copyright: "2026 AgentIsland Fixture"
      } |
      .categories = {primary: "developer-tools", secondary: "productivity"} |
      .commerce.ageRating = {questionnaireStatus: "complete", declaredRating: "4+"} |
      .commerce.contentRights = {
        status: "does-not-use-third-party-content", notes: "Reviewed release rights decision."
      } |
      .commerce.eula = {type: "apple-standard", customText: null, territories: []} |
      .commerce.digitalServicesAct = {traderStatus: "non-trader", verificationStatus: "not-required"} |
      .commerce.pricing = {
        model: "free", pricePointReference: null, taxCategory: "APPS", availableTerritories: ["USA"]
      } |
      .commerce.exportCompliance = {
        usesNonExemptEncryption: false, status: "exempt", documentationReference: null
      } |
      .review.contact = {firstName: "Release", lastName: "Reviewer", email: "review@example.org", phone: "+12025550123"} |
      .localizations |= map(.name = "MAC版灵动岛--Agent运行监测")
    ) |
    .records.ios.widgetBundleIdentifier = "com.agentisland.fixture.liveactivity" |
    .records.ios.testFlight.feedbackEmail = "testflight@example.org" |
    .records.ios.testFlight.betaReviewContact = {
      firstName: "Beta", lastName: "Reviewer", email: "beta@example.org", phone: "+12025550124"
    } |
    .records.ios.localizations = .records.macos.localizations
  ' "$PROJECT_ROOT/Config/AppStoreSubmission.example.json" \
  >"$FIXTURE_ROOT/.release/app-store-submission.json"
/bin/chmod 0444 "$FIXTURE_ROOT/.release/app-store-submission.json"
IDENTITY_BASELINE="$TEST_ROOT/identity-lock-valid.json"
SUBMISSION_BASELINE="$TEST_ROOT/app-store-submission-valid.json"
/bin/cp "$FIXTURE_ROOT/.release/identity.lock.json" "$IDENTITY_BASELINE"
/bin/cp "$FIXTURE_ROOT/.release/app-store-submission.json" "$SUBMISSION_BASELINE"

RUNNER="$TEST_ROOT/fixture-runner.mjs"
/bin/cat >"$RUNNER" <<'EOF'
import { appendFileSync, readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";

const [scriptPath, caseName, outputPath, transportLog] = process.argv.slice(2);
const { capturePublicPagesEvidence } = await import(pathToFileURL(scriptPath));
const product = "MAC版灵动岛--Agent运行监测";
const bodySecret = "RAW_RESPONSE_BODY_SECRET_7a2e";
const privacyBody = `<!doctype html><html lang="zh-CN"><body><h1>${product} 隐私政策</h1><section lang="en"><h2>Privacy</h2><a id="delete-data">Delete data</a><p>${bodySecret}</p></section></body></html>`;
const supportBody = `<!doctype html><html lang="zh-CN"><body><h1>${product} 支持</h1><section lang="en"><h2>Support</h2><a href="mailto:support@example.org">Email support</a><p>${bodySecret}</p></section></body></html>`;
const missingAnchorBody = `<!doctype html><html lang="zh-CN"><body><h1>${product} 隐私政策</h1><section lang="en"><h2>Privacy</h2><p>LOG_LEAK_SECRET_1c9f</p></section></body></html>`;
const misleadingBody = `<!doctype html><html lang="zh-CN"><body><h1>Unrelated page</h1><section lang="en">Nothing useful</section><!-- ${product} 隐私 Privacy <a id="delete-data">Delete</a> --><script>document.write('${product} 隐私 Privacy support@example.org')</script><style>#delete-data { content: 'Support 支持'; }</style></body></html>`;
const fakeDeletionBody = `<!doctype html><html lang="zh-CN"><body><h1>${product} 隐私政策</h1><section lang="en"><h2>Privacy</h2></section><!-- <a id="delete-data">Delete</a> --><script>"<a href='#delete-data'>Delete</a>"</script><style>#delete-data{display:block}</style></body></html>`;
const fakeContactBody = `<!doctype html><html lang="zh-CN"><body><h1>${product} 支持</h1><section lang="en"><h2>Support</h2></section><!-- <a href="mailto:support@example.org">mail</a> --><script>"mailto:support@example.org"</script><style>.support{background:url(mailto:support@example.org)}</style></body></html>`;
const hiddenProductBody = `<!doctype html><html lang="zh-CN"><body><h1 hidden>${product}</h1><p>隐私</p><section lang="en"><h2>Privacy</h2><a id="delete-data">Delete data</a></section></body></html>`;
const ariaHiddenPurposeBody = `<!doctype html><html lang="zh-CN"><body><h1>${product}</h1><p>隐私</p><section lang="en"><span aria-hidden="true">Privacy</span><a id="delete-data">Delete data</a></section></body></html>`;
const displayNoneDeletionBody = `<!doctype html><html lang="zh-CN"><body><h1>${product} 隐私</h1><section lang="en"><h2>Privacy</h2><div style="display : none !important"><a id="delete-data">Delete data</a></div></section></body></html>`;
const visibilityHiddenDeletionBody = `<!doctype html><html lang="zh-CN"><body><h1>${product} 隐私</h1><section lang="en"><h2>Privacy</h2><a id="delete-data" style="VISIBILITY: hidden">Delete data</a></section></body></html>`;
const templateContactBody = `<!doctype html><html lang="zh-CN"><body><h1>${product} 支持</h1><section lang="en"><h2>Support</h2><template><a href="mailto:support@example.org">Email support</a></template></section></body></html>`;
const response = (status, body = "", headers = {}) => ({
  status,
  body: Buffer.from(body, "utf8"),
  headers,
});

const transport = async url => {
  appendFileSync(transportLog, "request\n");
  if (caseName === "timeout") return new Promise(() => {});
  if (caseName === "transport-error") throw new Error("TRANSPORT_ERROR_SECRET_55d1");
  if (caseName === "cross-origin") {
    return response(302, "CROSS_ORIGIN_BODY_SECRET", { location: "https://openai.com/redirected/" });
  }
  if (caseName === "redirect-loop") {
    return response(301, "REDIRECT_BODY_SECRET", { location: url.href });
  }
  if (caseName === "status-404") {
    return response(404, "NOT_FOUND_BODY_SECRET", { "content-type": "text/html; charset=utf-8" });
  }
  if (caseName === "oversized") {
    return response(200, "x".repeat(1024 * 1024 + 1), { "content-type": "text/html; charset=utf-8" });
  }
  if (caseName === "wrong-content-type") {
    return response(200, privacyBody, { "content-type": "application/json" });
  }
  if (caseName === "missing-anchor") {
    return response(200, missingAnchorBody, { "content-type": "text/html; charset=utf-8" });
  }
  if (caseName === "misleading-html") {
    return response(200, misleadingBody, { "content-type": "text/html; charset=utf-8" });
  }
  if (caseName === "fake-deletion" && url.pathname.includes("privacy")) {
    return response(200, fakeDeletionBody, { "content-type": "text/html; charset=utf-8" });
  }
  if (caseName === "fake-contact" && url.pathname.includes("support")) {
    return response(200, fakeContactBody, { "content-type": "text/html; charset=utf-8" });
  }
  if (caseName === "hidden-product" && url.pathname.includes("privacy")) {
    return response(200, hiddenProductBody, { "content-type": "text/html; charset=utf-8" });
  }
  if (caseName === "aria-hidden-purpose" && url.pathname.includes("privacy")) {
    return response(200, ariaHiddenPurposeBody, { "content-type": "text/html; charset=utf-8" });
  }
  if (caseName === "display-none-deletion" && url.pathname.includes("privacy")) {
    return response(200, displayNoneDeletionBody, { "content-type": "text/html; charset=utf-8" });
  }
  if (caseName === "visibility-hidden-deletion" && url.pathname.includes("privacy")) {
    return response(200, visibilityHiddenDeletionBody, { "content-type": "text/html; charset=utf-8" });
  }
  if (caseName === "template-contact" && url.pathname.includes("support")) {
    return response(200, templateContactBody, { "content-type": "text/html; charset=utf-8" });
  }
  if (caseName === "success" && url.pathname.endsWith("/privacy/")) {
    return response(302, "IGNORED_REDIRECT_BODY_SECRET", {
      location: "./current/",
    });
  }
  return response(200, url.pathname.includes("privacy") ? privacyBody : supportBody, {
    "content-type": "text/html; charset=utf-8",
  });
};

try {
  const extraOrigins = process.env.AGENT_ISLAND_TEST_ALLOWED_ORIGIN
    ? [process.env.AGENT_ISLAND_TEST_ALLOWED_ORIGIN]
    : [];
  const bindingType = process.env.AGENT_ISLAND_TEST_BINDING_TYPE ?? "identity-lock";
  const bindingPath = process.env.AGENT_ISLAND_TEST_BINDING_PATH ?? (bindingType === "submission-manifest"
    ? ".release/app-store-submission.json"
    : ".release/identity.lock.json");
  const result = await capturePublicPagesEvidence({
    outputPath,
    allowedOrigins: extraOrigins,
    bindingType,
    bindingPath,
    transport,
    timeoutMs: caseName === "timeout" ? 25 : 1000,
  });
  const expectedBodySHAs = {
    privacy: createHash("sha256").update(Buffer.from(privacyBody, "utf8")).digest("hex"),
    support: createHash("sha256").update(Buffer.from(supportBody, "utf8")).digest("hex"),
  };
  if (!result.evidence.pages.every(page => page.bodySHA256 === expectedBodySHAs[page.kind])) {
    throw new Error("body digest did not cover the exact response bytes");
  }
  const diskEvidence = JSON.parse(readFileSync(result.evidencePath, "utf8"));
  if (diskEvidence.pages.some(page => Object.hasOwn(page, "body"))) {
    throw new Error("response body leaked into evidence");
  }
  process.stdout.write(`${JSON.stringify({ evidencePath: result.evidencePath, evidenceSHA256: result.evidenceSHA256 })}\n`);
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : "fixture failed"}\n`);
  process.exitCode = 1;
}
EOF

IP_RUNNER="$TEST_ROOT/ip-policy.mjs"
/bin/cat >"$IP_RUNNER" <<'EOF'
import { pathToFileURL } from "node:url";

const { ipAddressIsPublic } = await import(pathToFileURL(process.argv[2]));
const cases = new Map([
  ["8.8.8.8", true],
  ["10.0.0.1", false],
  ["2001:4860:4860::8888", true],
  ["fec0::1", false],
  ["64:ff9b:1::808:808", false],
  ["64:ff9b::a00:1", false],
  ["64:ff9b::808:808", true],
  ["2002:c0a8:101::1", false],
  ["2002:0808:0808::1", true],
]);
for (const [address, expected] of cases) {
  if (ipAddressIsPublic(address) !== expected) {
    throw new Error(`unexpected address policy result for ${address}`);
  }
}
EOF
node "$IP_RUNNER" "$FIXTURE_SCRIPT"

SOCKET_RUNNER="$TEST_ROOT/socket-address-policy.mjs"
/bin/cat >"$SOCKET_RUNNER" <<'EOF'
import { EventEmitter } from "node:events";
import { promises as dns } from "node:dns";
import https from "node:https";
import { pathToFileURL } from "node:url";

dns.lookup = async () => [{ address: "8.8.8.8", family: 4 }];
https.request = () => {
  const request = new EventEmitter();
  request.destroy = error => request.emit("error", error);
  request.end = () => {
    const socket = new EventEmitter();
    socket.connecting = true;
    socket.remoteAddress = "10.0.0.9";
    request.emit("socket", socket);
    socket.emit("secureConnect");
  };
  return request;
};
const { productionTransport } = await import(`${pathToFileURL(process.argv[2]).href}?socket-policy=1`);
let rejected = false;
try {
  await productionTransport(new URL("https://kiki-lgtm-dot.github.io/privacy/"), {
    signal: new AbortController().signal,
    maxBytes: 1024 * 1024,
  });
} catch (error) {
  rejected = error instanceof Error && error.message.includes("non-public address");
}
if (!rejected) throw new Error("post-connect private remoteAddress was accepted");
EOF
node "$SOCKET_RUNNER" "$FIXTURE_SCRIPT"

run_capture() {
  local case_name="$1" output_path="$2" log_path="$3"
  : >"$TRANSPORT_LOG"
  if ! node "$RUNNER" "$FIXTURE_SCRIPT" "$case_name" "$output_path" \
      "$TRANSPORT_LOG" >"$log_path" 2>&1; then
    /bin/cat "$log_path" >&2
    fail "$case_name capture failed"
  fi
}

expect_capture_failure() {
  local case_name="$1" marker="$2" output_path="$3"
  local log_path="$TEST_ROOT/${case_name}.log"
  : >"$TRANSPORT_LOG"
  if node "$RUNNER" "$FIXTURE_SCRIPT" "$case_name" "$output_path" \
      "$TRANSPORT_LOG" >"$log_path" 2>&1; then
    fail "$case_name capture unexpectedly succeeded"
  fi
  contains "$marker" "$log_path"
  [[ ! -e "$output_path" && ! -L "$output_path" ]] \
    || fail "$case_name left a public evidence output"
}

SUCCESS_EVIDENCE="$FIXTURE_ROOT/.release/public-pages-success.json"
SUCCESS_LOG="$TEST_ROOT/success.log"
run_capture success "$SUCCESS_EVIDENCE" "$SUCCESS_LOG"
[[ -f "$SUCCESS_EVIDENCE" && ! -L "$SUCCESS_EVIDENCE" ]] \
  || fail "successful capture did not publish evidence"
[[ "$(/usr/bin/stat -f '%Lp' "$SUCCESS_EVIDENCE")" == "444" ]] \
  || fail "published evidence is not mode 0444"
/usr/bin/jq -e '
  .schemaVersion == 1 and .evidenceType == "public-pages" and
  .productName == "MAC版灵动岛--Agent运行监测" and
  .configuredURLs.privacy == "https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/" and
  .configuredURLs.support == "https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/" and
  .allowedOrigins == ["https://kiki-lgtm-dot.github.io"] and
  .binding.type == "identity-lock" and
  (.binding.sha256 | test("^[0-9a-f]{64}$")) and
  (.pages | map(.kind)) == ["privacy", "support"] and
  .pages[0].redirectCount == 1 and
  .pages[0].finalURL == "https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/current/" and
  .pages[1].redirectCount == 0 and
  all(.pages[];
    .status == 200 and .contentType == "text/html; charset=utf-8" and
    (.bodySHA256 | test("^[0-9a-f]{64}$")) and .bodySizeBytes > 0 and
    .validations == {
      productName: true,
      bilingualLanguages: true,
      pagePurpose: true,
      contactOrDeletionPath: true
    })
' "$SUCCESS_EVIDENCE" >/dev/null || fail "generated evidence fields are invalid"
LOCK_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$FIXTURE_ROOT/.release/identity.lock.json" | /usr/bin/awk '{print $1}')"
[[ "$(/usr/bin/jq -r '.binding.sha256' "$SUCCESS_EVIDENCE")" == "$LOCK_SHA256" ]] \
  || fail "evidence does not contain the exact binding SHA-256"
EVIDENCE_SHA256="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$SUCCESS_EVIDENCE" | /usr/bin/awk '{print $1}')"
[[ "$(/usr/bin/jq -r '.evidenceSHA256' "$SUCCESS_LOG")" == "$EVIDENCE_SHA256" ]] \
  || fail "capture result does not contain the exact evidence SHA-256"
if /usr/bin/grep -Fq 'RAW_RESPONSE_BODY_SECRET_7a2e' "$SUCCESS_EVIDENCE" "$SUCCESS_LOG"; then
  fail "response body leaked into evidence or capture logs"
fi

VERIFY_LOG="$TEST_ROOT/verify.json"
TRANSPORT_CALLS_BEFORE_VERIFY="$(/usr/bin/wc -l <"$TRANSPORT_LOG" | /usr/bin/tr -d ' ')"
node "$FIXTURE_SCRIPT" --verify "$SUCCESS_EVIDENCE" >"$VERIFY_LOG"
TRANSPORT_CALLS_AFTER_VERIFY="$(/usr/bin/wc -l <"$TRANSPORT_LOG" | /usr/bin/tr -d ' ')"
[[ "$TRANSPORT_CALLS_BEFORE_VERIFY" == "$TRANSPORT_CALLS_AFTER_VERIFY" ]] \
  || fail "offline verification contacted the injected transport"
/usr/bin/jq -e --arg path "$SUCCESS_EVIDENCE" '
  .valid == true and .evidencePath == $path and
  (.evidenceSHA256 | test("^[0-9a-f]{64}$")) and
  .binding.type == "identity-lock" and
  (.binding.path | endswith("/.release/identity.lock.json")) and
  .maxAgeSeconds == 86400
' "$VERIFY_LOG" >/dev/null || fail "offline verification result is incomplete"

# Prove the exported verifier does not merely bypass the fixture transport: its
# real DNS and HTTPS boundaries are replaced with throwing spies in-process.
OFFLINE_RUNNER="$TEST_ROOT/offline-boundary.mjs"
/bin/cat >"$OFFLINE_RUNNER" <<'EOF'
import https from "node:https";
import { promises as dns } from "node:dns";
import { pathToFileURL } from "node:url";

let networkCalls = 0;
https.request = () => {
  networkCalls += 1;
  throw new Error("offline verifier reached HTTPS");
};
dns.lookup = async () => {
  networkCalls += 1;
  throw new Error("offline verifier reached DNS");
};
const [scriptPath, projectRoot, evidencePath] = process.argv.slice(2);
const { verifyPublicPagesEvidence } = await import(`${pathToFileURL(scriptPath).href}?offline-boundary=1`);
const result = await verifyPublicPagesEvidence({
  projectRoot,
  evidencePath,
  transport: () => {
    networkCalls += 1;
    throw new Error("offline verifier reached injected transport");
  },
});
if (!result.valid || networkCalls !== 0) throw new Error("offline verifier crossed a network boundary");
EOF
node "$OFFLINE_RUNNER" "$FIXTURE_SCRIPT" "$FIXTURE_ROOT" "$SUCCESS_EVIDENCE"

SUCCESS_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$SUCCESS_EVIDENCE" | /usr/bin/awk '{print $1}')"
if node "$RUNNER" "$FIXTURE_SCRIPT" success "$SUCCESS_EVIDENCE" \
    "$TRANSPORT_LOG" >"$TEST_ROOT/no-overwrite.log" 2>&1; then
  fail "capture overwrote an existing evidence file"
fi
contains 'refusing to overwrite an existing public-pages evidence file' \
  "$TEST_ROOT/no-overwrite.log"
[[ "$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$SUCCESS_EVIDENCE" | /usr/bin/awk '{print $1}')" == "$SUCCESS_SHA" ]] \
  || fail "no-overwrite failure changed existing evidence"
[[ -z "$(/usr/bin/find "$FIXTURE_ROOT/.release" -maxdepth 1 -name '*.capture-*' -print)" ]] \
  || fail "capture left a temporary publication file"

expect_capture_failure status-404 'did not return a 2xx status' \
  "$FIXTURE_ROOT/.release/status-404.json"
expect_capture_failure oversized 'exceeds the 1 MiB limit' \
  "$FIXTURE_ROOT/.release/oversized.json"
expect_capture_failure cross-origin 'attempted a cross-origin redirect' \
  "$FIXTURE_ROOT/.release/cross-origin.json"
expect_capture_failure redirect-loop 'exceeded the redirect limit' \
  "$FIXTURE_ROOT/.release/redirect-loop.json"
expect_capture_failure timeout 'page request timed out' \
  "$FIXTURE_ROOT/.release/timeout.json"
expect_capture_failure wrong-content-type 'content-type is not HTML' \
  "$FIXTURE_ROOT/.release/content-type.json"
expect_capture_failure missing-anchor 'missing an exact delete-data entry in the visible HTML structure' \
  "$FIXTURE_ROOT/.release/missing-anchor.json"
if /usr/bin/grep -Fq 'LOG_LEAK_SECRET_1c9f' "$TEST_ROOT/missing-anchor.log"; then
  fail "invalid response body leaked into the failure log"
fi
expect_capture_failure transport-error 'page HTTPS request failed' \
  "$FIXTURE_ROOT/.release/transport-error.json"
if /usr/bin/grep -Fq 'TRANSPORT_ERROR_SECRET_55d1' "$TEST_ROOT/transport-error.log"; then
  fail "transport exception details leaked into the failure log"
fi
expect_capture_failure misleading-html 'missing the configured product name in the visible HTML structure' \
  "$FIXTURE_ROOT/.release/misleading-html.json"
expect_capture_failure fake-deletion 'missing an exact delete-data entry in the visible HTML structure' \
  "$FIXTURE_ROOT/.release/fake-deletion.json"
expect_capture_failure fake-contact 'missing a real mailto or HTTPS support contact link in the visible HTML structure' \
  "$FIXTURE_ROOT/.release/fake-contact.json"
expect_capture_failure hidden-product 'missing the configured product name in the visible HTML structure' \
  "$FIXTURE_ROOT/.release/hidden-product.json"
expect_capture_failure aria-hidden-purpose 'missing bilingual privacy purpose text in the visible HTML structure' \
  "$FIXTURE_ROOT/.release/aria-hidden-purpose.json"
expect_capture_failure display-none-deletion 'missing an exact delete-data entry in the visible HTML structure' \
  "$FIXTURE_ROOT/.release/display-none-deletion.json"
expect_capture_failure visibility-hidden-deletion 'missing an exact delete-data entry in the visible HTML structure' \
  "$FIXTURE_ROOT/.release/visibility-hidden-deletion.json"
expect_capture_failure template-contact 'missing a real mailto or HTTPS support contact link in the visible HTML structure' \
  "$FIXTURE_ROOT/.release/template-contact.json"

expect_config_rejected() {
  local label="$1" replacement="$2" marker="$3" secret="${4:-}"
  local output="$FIXTURE_ROOT/.release/config-$label.json"
  /usr/bin/sed "s|^AGENT_ISLAND_PRIVACY_POLICY_URL = .*|AGENT_ISLAND_PRIVACY_POLICY_URL = $replacement|" \
    "$TEST_ROOT/valid.xcconfig" >"$FIXTURE_CONFIG"
  : >"$TRANSPORT_LOG"
  if node "$RUNNER" "$FIXTURE_SCRIPT" success "$output" "$TRANSPORT_LOG" \
      >"$TEST_ROOT/config-$label.log" 2>&1; then
    fail "$label configured URL unexpectedly succeeded"
  fi
  contains "$marker" "$TEST_ROOT/config-$label.log"
  [[ ! -s "$TRANSPORT_LOG" ]] || fail "$label configured URL contacted the transport"
  [[ ! -e "$output" && ! -L "$output" ]] || fail "$label URL left evidence"
  if [[ -n "$secret" ]] && /usr/bin/grep -Fq "$secret" "$TEST_ROOT/config-$label.log"; then
    fail "$label URL credentials leaked into logs"
  fi
  /bin/cp "$TEST_ROOT/valid.xcconfig" "$FIXTURE_CONFIG"
}

expect_config_rejected http \
  'http://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/' \
  'must be credential-free HTTPS without a query or fragment'
expect_config_rejected fragment \
  'https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/#secret-fragment' \
  'must be credential-free HTTPS without a query or fragment'
expect_config_rejected query \
  'https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/?tracking=secret' \
  'must be credential-free HTTPS without a query or fragment'
expect_config_rejected credentials \
  'https://capture-user:CREDENTIAL_SECRET_f309@kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/' \
  'must be credential-free HTTPS without a query or fragment' 'CREDENTIAL_SECRET_f309'
expect_config_rejected origin \
  'https://openai.com/privacy/' \
  'origin is not allowlisted'
expect_config_rejected same-url \
  'https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/' \
  'privacy and support URLs must be different'

/usr/bin/sed 's#^AGENT_ISLAND_PRIVACY_POLICY_URL = .*#AGENT_ISLAND_PRIVACY_POLICY_URL = https://127.0.0.1/privacy/#' \
  "$TEST_ROOT/valid.xcconfig" >"$FIXTURE_CONFIG"
: >"$TRANSPORT_LOG"
if AGENT_ISLAND_TEST_ALLOWED_ORIGIN='https://127.0.0.1' \
    node "$RUNNER" "$FIXTURE_SCRIPT" success \
      "$FIXTURE_ROOT/.release/loopback.json" "$TRANSPORT_LOG" \
      >"$TEST_ROOT/loopback.log" 2>&1; then
  fail "an explicit allowlist opened production loopback"
fi
contains 'must use a public DNS hostname' "$TEST_ROOT/loopback.log"
[[ ! -s "$TRANSPORT_LOG" ]] || fail "loopback URL contacted the transport"
/bin/cp "$TEST_ROOT/valid.xcconfig" "$FIXTURE_CONFIG"

# A custom public origin works only when explicitly supplied at both capture
# and verification. The transport remains injected; this test never contacts it.
/usr/bin/sed \
  -e 's#kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/#openai.com/agentisland/privacy/#' \
  -e 's#kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/#openai.com/agentisland/support/#' \
  "$TEST_ROOT/valid.xcconfig" >"$FIXTURE_CONFIG"
CUSTOM_CONFIG_SHA="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$FIXTURE_CONFIG" | /usr/bin/awk '{print $1}')"
/usr/bin/jq --arg sha "$CUSTOM_CONFIG_SHA" \
  '(.appliedFiles[] | select(.path == "ApplePlatforms/iOS/Config/Project.xcconfig").sha256) = $sha' \
  "$IDENTITY_BASELINE" >"$TEST_ROOT/custom-origin-identity.lock.json"
/bin/cp "$TEST_ROOT/custom-origin-identity.lock.json" "$FIXTURE_ROOT/.release/identity.lock.json"
/bin/chmod 0600 "$FIXTURE_ROOT/.release/identity.lock.json"
CUSTOM_EVIDENCE="$FIXTURE_ROOT/.release/custom-origin.json"
AGENT_ISLAND_TEST_ALLOWED_ORIGIN='https://openai.com' \
  run_capture success "$CUSTOM_EVIDENCE" "$TEST_ROOT/custom-origin.log"
if node "$FIXTURE_SCRIPT" --verify "$CUSTOM_EVIDENCE" \
    >"$TEST_ROOT/custom-verify-missing-origin.log" 2>&1; then
  fail "custom-origin evidence verified without the explicit allowlist"
fi
node "$FIXTURE_SCRIPT" --verify "$CUSTOM_EVIDENCE" \
  --allow-origin 'https://openai.com' >"$TEST_ROOT/custom-verify.json"
/usr/bin/jq -e '.valid == true' "$TEST_ROOT/custom-verify.json" >/dev/null \
  || fail "explicitly allowlisted custom-origin evidence did not verify"
/bin/cp "$TEST_ROOT/valid.xcconfig" "$FIXTURE_CONFIG"
/bin/cp "$IDENTITY_BASELINE" "$FIXTURE_ROOT/.release/identity.lock.json"
/bin/chmod 0600 "$FIXTURE_ROOT/.release/identity.lock.json"

SUBMISSION_EVIDENCE="$FIXTURE_ROOT/.release/submission-bound.json"
AGENT_ISLAND_TEST_BINDING_TYPE='submission-manifest' \
  run_capture success "$SUBMISSION_EVIDENCE" "$TEST_ROOT/submission.log"
/usr/bin/jq -e '.binding.type == "submission-manifest" and .binding.path == ".release/app-store-submission.json"' \
  "$SUBMISSION_EVIDENCE" >/dev/null || fail "submission-manifest binding was not recorded"
node "$FIXTURE_SCRIPT" --verify "$SUBMISSION_EVIDENCE" \
  >"$TEST_ROOT/submission-verify.json"

expect_identity_binding_failure() {
  local label="$1" filter="$2" marker="$3"
  local output="$FIXTURE_ROOT/.release/identity-$label-evidence.json"
  /usr/bin/jq "$filter" "$IDENTITY_BASELINE" >"$TEST_ROOT/identity-$label.json"
  /bin/cp "$TEST_ROOT/identity-$label.json" "$FIXTURE_ROOT/.release/identity.lock.json"
  /bin/chmod 0600 "$FIXTURE_ROOT/.release/identity.lock.json"
  : >"$TRANSPORT_LOG"
  if node "$RUNNER" "$FIXTURE_SCRIPT" success "$output" "$TRANSPORT_LOG" \
      >"$TEST_ROOT/identity-$label.log" 2>&1; then
    fail "identity binding $label unexpectedly succeeded"
  fi
  contains "$marker" "$TEST_ROOT/identity-$label.log"
  [[ ! -s "$TRANSPORT_LOG" ]] || fail "identity binding $label contacted the transport"
  [[ ! -e "$output" ]] || fail "identity binding $label left evidence"
  /bin/cp "$IDENTITY_BASELINE" "$FIXTURE_ROOT/.release/identity.lock.json"
  /bin/chmod 0600 "$FIXTURE_ROOT/.release/identity.lock.json"
}

expect_identity_binding_failure schema-type '.schemaVersion = "1"' \
  'identity lock envelope schemaVersion must equal 1'
expect_identity_binding_failure identity-type '.identity = "not-an-identity"' \
  'identity lock identity must be an object'
expect_identity_binding_failure wrong-label '.identitty = .identity | del(.identity)' \
  'identity lock has an unsupported schema'
expect_identity_binding_failure stale-applied \
  '(.appliedFiles[] | select(.path == "Resources/Info.plist").sha256) = ("0" * 64)' \
  'identity lock applied-file SHA-256 is stale'

/bin/cp "$IDENTITY_BASELINE" "$FIXTURE_ROOT/.release/identity-copy.json"
/bin/chmod 0600 "$FIXTURE_ROOT/.release/identity-copy.json"
if AGENT_ISLAND_TEST_BINDING_PATH='.release/identity-copy.json' \
    node "$RUNNER" "$FIXTURE_SCRIPT" success \
      "$FIXTURE_ROOT/.release/identity-wrong-path-evidence.json" "$TRANSPORT_LOG" \
      >"$TEST_ROOT/identity-wrong-path.log" 2>&1; then
  fail "identity binding accepted a noncanonical fixed path"
fi
contains 'identity-lock binding must use .release/identity.lock.json' "$TEST_ROOT/identity-wrong-path.log"

expect_submission_binding_failure() {
  local label="$1" filter="$2" marker="$3"
  local output="$FIXTURE_ROOT/.release/submission-$label-evidence.json"
  /usr/bin/jq "$filter" "$SUBMISSION_BASELINE" >"$TEST_ROOT/submission-$label.json"
  /bin/chmod 0644 "$FIXTURE_ROOT/.release/app-store-submission.json"
  /bin/cp "$TEST_ROOT/submission-$label.json" "$FIXTURE_ROOT/.release/app-store-submission.json"
  /bin/chmod 0444 "$FIXTURE_ROOT/.release/app-store-submission.json"
  : >"$TRANSPORT_LOG"
  if AGENT_ISLAND_TEST_BINDING_TYPE='submission-manifest' \
      node "$RUNNER" "$FIXTURE_SCRIPT" success "$output" "$TRANSPORT_LOG" \
      >"$TEST_ROOT/submission-$label.log" 2>&1; then
    fail "submission binding $label unexpectedly succeeded"
  fi
  contains "$marker" "$TEST_ROOT/submission-$label.log"
  [[ ! -s "$TRANSPORT_LOG" ]] || fail "submission binding $label contacted the transport"
  [[ ! -e "$output" ]] || fail "submission binding $label left evidence"
  /bin/chmod 0644 "$FIXTURE_ROOT/.release/app-store-submission.json"
  /bin/cp "$SUBMISSION_BASELINE" "$FIXTURE_ROOT/.release/app-store-submission.json"
  /bin/chmod 0444 "$FIXTURE_ROOT/.release/app-store-submission.json"
}

expect_submission_binding_failure schema-type '.schemaVersion = "1"' \
  'submission manifest schemaVersion must equal 1'
expect_submission_binding_failure wrong-label '.recordz = .records | del(.records)' \
  'submission manifest has an unsupported schema'
expect_submission_binding_failure product '.productName = "Wrong product"' \
  'submission manifest product name differs from current xcconfig'
expect_submission_binding_failure record-mode '.recordMode = "separate-records"' \
  'submission manifest separate-records appResourceId values must differ'
expect_submission_binding_failure version '.records.ios.version.versionString = "9.9.9"' \
  'differs from the current project version'
expect_submission_binding_failure url \
  '.records.ios.localizations[0].privacyPolicyURL = "https://kiki-lgtm-dot.github.io/wrong/privacy/"' \
  'public-page URLs differ from current xcconfig'

/bin/cp "$SUBMISSION_BASELINE" "$FIXTURE_ROOT/.release/app-store-submission-copy.json"
/bin/chmod 0444 "$FIXTURE_ROOT/.release/app-store-submission-copy.json"
if AGENT_ISLAND_TEST_BINDING_TYPE='submission-manifest' \
    AGENT_ISLAND_TEST_BINDING_PATH='.release/app-store-submission-copy.json' \
    node "$RUNNER" "$FIXTURE_SCRIPT" success \
      "$FIXTURE_ROOT/.release/submission-wrong-path-evidence.json" "$TRANSPORT_LOG" \
      >"$TEST_ROOT/submission-wrong-path.log" 2>&1; then
  fail "submission binding accepted a noncanonical fixed path"
fi
contains 'submission-manifest binding must use .release/app-store-submission.json' \
  "$TEST_ROOT/submission-wrong-path.log"

# Duplicate keys must be rejected rather than resolved with JSON.parse's
# last-member-wins behavior.
/bin/chmod 0644 "$FIXTURE_ROOT/.release/app-store-submission.json"
print -rn -- '{"schemaVersion":1,"schemaVersion":1}' \
  >"$FIXTURE_ROOT/.release/app-store-submission.json"
/bin/chmod 0444 "$FIXTURE_ROOT/.release/app-store-submission.json"
if AGENT_ISLAND_TEST_BINDING_TYPE='submission-manifest' \
    node "$RUNNER" "$FIXTURE_SCRIPT" success \
      "$FIXTURE_ROOT/.release/submission-duplicate-evidence.json" "$TRANSPORT_LOG" \
      >"$TEST_ROOT/submission-duplicate.log" 2>&1; then
  fail "submission binding accepted duplicate JSON members"
fi
contains 'duplicate member' "$TEST_ROOT/submission-duplicate.log"
/bin/chmod 0644 "$FIXTURE_ROOT/.release/app-store-submission.json"
/bin/cp "$SUBMISSION_BASELINE" "$FIXTURE_ROOT/.release/app-store-submission.json"
/bin/chmod 0444 "$FIXTURE_ROOT/.release/app-store-submission.json"

# Offline verification must reject permissions, stale time, schema drift,
# current-config drift, and a changed binding without making a network request.
/bin/chmod 0644 "$SUCCESS_EVIDENCE"
if node "$FIXTURE_SCRIPT" --verify "$SUCCESS_EVIDENCE" \
    >"$TEST_ROOT/verify-mode.log" 2>&1; then
  fail "verification accepted writable evidence"
fi
contains 'must have mode 0444' "$TEST_ROOT/verify-mode.log"
/bin/chmod 0444 "$SUCCESS_EVIDENCE"

STALE_EVIDENCE="$FIXTURE_ROOT/.release/stale.json"
/usr/bin/jq '(.pages[].checkedAt, .createdAt) = "2020-01-01T00:00:00Z"' \
  "$SUCCESS_EVIDENCE" >"$STALE_EVIDENCE"
/bin/chmod 0444 "$STALE_EVIDENCE"
if node "$FIXTURE_SCRIPT" --verify "$STALE_EVIDENCE" \
    >"$TEST_ROOT/verify-stale.log" 2>&1; then
  fail "verification accepted stale evidence"
fi
contains 'is stale' "$TEST_ROOT/verify-stale.log"

SCHEMA_DRIFT_EVIDENCE="$FIXTURE_ROOT/.release/schema-drift.json"
/usr/bin/jq '.unexpected = true' "$SUCCESS_EVIDENCE" >"$SCHEMA_DRIFT_EVIDENCE"
/bin/chmod 0444 "$SCHEMA_DRIFT_EVIDENCE"
if node "$FIXTURE_SCRIPT" --verify "$SCHEMA_DRIFT_EVIDENCE" \
    >"$TEST_ROOT/verify-schema.log" 2>&1; then
  fail "verification accepted schema drift"
fi
contains 'unsupported schema' "$TEST_ROOT/verify-schema.log"

BINDING_TYPE_EVIDENCE="$FIXTURE_ROOT/.release/binding-type.json"
/usr/bin/jq '.binding.type = "identity_lock"' "$SUCCESS_EVIDENCE" >"$BINDING_TYPE_EVIDENCE"
/bin/chmod 0444 "$BINDING_TYPE_EVIDENCE"
if node "$FIXTURE_SCRIPT" --verify "$BINDING_TYPE_EVIDENCE" \
    >"$TEST_ROOT/verify-binding-type.log" 2>&1; then
  fail "verification accepted an unsupported binding type label"
fi
contains 'evidence binding is invalid' "$TEST_ROOT/verify-binding-type.log"

BINDING_PATH_EVIDENCE="$FIXTURE_ROOT/.release/binding-path.json"
/usr/bin/jq '.binding.path = ".release/identity-copy.json"' "$SUCCESS_EVIDENCE" >"$BINDING_PATH_EVIDENCE"
/bin/chmod 0444 "$BINDING_PATH_EVIDENCE"
if node "$FIXTURE_SCRIPT" --verify "$BINDING_PATH_EVIDENCE" \
    >"$TEST_ROOT/verify-binding-path.log" 2>&1; then
  fail "verification accepted a noncanonical binding path"
fi
contains 'must use .release/identity.lock.json' "$TEST_ROOT/verify-binding-path.log"

VALIDATION_LABEL_EVIDENCE="$FIXTURE_ROOT/.release/validation-label.json"
/usr/bin/jq '.pages[0].validations.anchor = .pages[0].validations.contactOrDeletionPath |
  del(.pages[0].validations.contactOrDeletionPath)' \
  "$SUCCESS_EVIDENCE" >"$VALIDATION_LABEL_EVIDENCE"
/bin/chmod 0444 "$VALIDATION_LABEL_EVIDENCE"
if node "$FIXTURE_SCRIPT" --verify "$VALIDATION_LABEL_EVIDENCE" \
    >"$TEST_ROOT/verify-validation-label.log" 2>&1; then
  fail "verification accepted a renamed page assertion"
fi
contains 'validations has an unsupported schema' "$TEST_ROOT/verify-validation-label.log"

DUPLICATE_EVIDENCE="$FIXTURE_ROOT/.release/duplicate-evidence.json"
print -rn -- '{"schemaVersion":1,"schemaVersion":1}' >"$DUPLICATE_EVIDENCE"
/bin/chmod 0444 "$DUPLICATE_EVIDENCE"
if node "$FIXTURE_SCRIPT" --verify "$DUPLICATE_EVIDENCE" \
    >"$TEST_ROOT/verify-duplicate.log" 2>&1; then
  fail "verification accepted duplicate evidence members"
fi
contains 'duplicate member' "$TEST_ROOT/verify-duplicate.log"

/usr/bin/sed 's#mac-agent-monitor-app/privacy/#mac-agent-monitor-app/privacy-v2/#' \
  "$TEST_ROOT/valid.xcconfig" >"$FIXTURE_CONFIG"
if node "$FIXTURE_SCRIPT" --verify "$SUCCESS_EVIDENCE" \
    >"$TEST_ROOT/verify-config.log" 2>&1; then
  fail "verification accepted evidence for a previous xcconfig URL"
fi
contains 'differ from current xcconfig' "$TEST_ROOT/verify-config.log"
/bin/cp "$TEST_ROOT/valid.xcconfig" "$FIXTURE_CONFIG"

LOCK_BASELINE="$TEST_ROOT/identity-lock-baseline.json"
/bin/cp "$FIXTURE_ROOT/.release/identity.lock.json" "$LOCK_BASELINE"
/usr/bin/jq '.firstAppliedAt = "2026-09-03T23:59:59Z"' "$LOCK_BASELINE" \
  >"$FIXTURE_ROOT/.release/identity.lock.json.changed"
/bin/mv "$FIXTURE_ROOT/.release/identity.lock.json.changed" \
  "$FIXTURE_ROOT/.release/identity.lock.json"
/bin/chmod 0600 "$FIXTURE_ROOT/.release/identity.lock.json"
if node "$FIXTURE_SCRIPT" --verify "$SUCCESS_EVIDENCE" \
    >"$TEST_ROOT/verify-binding.log" 2>&1; then
  fail "verification accepted a changed binding"
fi
contains 'binding SHA-256 is stale' "$TEST_ROOT/verify-binding.log"
/bin/mv "$LOCK_BASELINE" "$FIXTURE_ROOT/.release/identity.lock.json"
/bin/chmod 0600 "$FIXTURE_ROOT/.release/identity.lock.json"

print -r -- "Public privacy/support page capture and offline verification tests passed"
