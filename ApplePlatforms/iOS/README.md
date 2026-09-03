# MAC版灵动岛--Agent运行监测 iPhone companion source

This directory contains a directly openable Xcode project for an iPhone
companion and WidgetKit Live Activity:

```text
AgentIsland.xcodeproj
```

The project has separate `AgentIslandMobile`,
`AgentIslandLiveActivityExtension`, and `AgentIslandMobileTests` targets. The
app depends on and embeds the extension, while the hosted unit-test target
exercises the app module without being included in archives. The shipping
targets share only the privacy-minimized data model and localized resources.

## Architecture

```text
Mac collector
  -> privacy-minimized AgentIslandSnapshot JSON
  -> one record in the user's private CloudKit database
  -> CloudKitSnapshotProvider
  -> SyncedSnapshotStore in the iPhone sandbox
  -> SwiftUI dashboard
  -> ActivityKit state (no conversation titles)
  -> Lock Screen / Dynamic Island

Explicit example mode
  -> bundled non-sensitive PreviewSnapshotProvider (memory only)
  -> the same SwiftUI dashboard and visibly labelled ActivityKit presentation
```

The mobile schema contains counts, state, active duration, token usage, tool
names, and a field for privacy-safe conversation summaries. The current Mac
producer leaves `safeSummary` empty. The schema has no fields for prompts,
responses, API keys, process IDs, Mac file paths, or workspace paths. Full
conversation titles are optional, are stripped by `redactedForSync()` unless
the source user opts in, and are hidden whenever the iPhone app leaves the
foreground and on every fresh launch.

The Mac producer implements this contract. Private sync is off by default and
starts only after the user reviews the off-device field disclosure and
expressly opts in. Prompts, task summaries, response bodies, project/file
paths, model names, API keys, notes, and translation content are excluded.
Conversation titles are off by default, require a separate confirmation, and
are accepted only from an explicit title source after length, path, control
character, and secret-pattern checks. Turning sync off stops uploads and
deletes the fixed cloud `latest` record. Normal refresh-driven uploads are
throttled to at least 60 seconds; the user can choose **Sync now** to force a
fresh local read and upload.

`CloudKitSnapshotProvider` fetches from the signed-in user's private CloudKit
database whenever the app launches, returns to the foreground, or is manually
refreshed. A successfully decoded and validated snapshot is atomically saved by
`SyncedSnapshotStore` under an account-specific directory whose name is an
irreversible SHA-256 digest of the CloudKit user record identifier. A missing
record clears only that account's cache; signing out or changing accounts never
falls back to another account's snapshot. If a record fetch fails temporarily
after the same account is re-verified, the provider returns that account's last
valid snapshot and marks the UI as offline. It never attempts to mount, browse,
or read Mac files.

The Mac producer already removes unrelated applications before upload.
`AgentIslandSnapshot.relevantAgents` therefore preserves every tool the
producer deliberately included, including an installed or running tool that
currently has no conversation or measured token usage. The iPhone does not
silently drop those entries or mislabel them as working; `activeAgents` remains
the separate state-based subset.

The Widget Extension neither links CloudKit nor receives its entitlement. The
host app reduces a validated snapshot to title-free ActivityKit state before
updating the Live Activity. This build refreshes ActivityKit only while the host
app launches, returns to the foreground, or the user manually refreshes it. It
does not promise background real-time updates; those would require an
authenticated ActivityKit push-token/APNs service that is intentionally outside
this local-first release. On app relaunch, the dashboard restores its running
control state by inspecting existing system Live Activities. Activity content
becomes stale after two minutes without a host-app update; the Lock Screen and
Dynamic Island then use the localized stale label and orange treatment instead
of presenting old data as current.

## Review-safe example mode

The dashboard always exposes **Explore with example data / 使用示例数据体验** below
the sync status. After an explicit confirmation, the same dashboard can display
a small bundled dataset without requiring a Mac, an iCloud account, an AI tool,
or a paid API. This path is compiled into Release builds for App Review and is
not a hidden debug gesture or special reviewer credential.

The sample is deliberately unmistakable: the sync header says **EXAMPLE DATA**,
an orange explanation states that every agent, conversation, duration, and token
value is fictional, and sample names are generic and bilingual. A Live Activity
started from this mode carries an example flag; the Lock Screen, expanded and
compact Dynamic Island presentations use sample text, color, or the test-tube
symbol rather than presenting the values as Mac-synced activity.

`PreviewSnapshotProvider` returns the bundle's sample directly in memory. It
does not call `CloudKitSnapshotProvider`, write a CloudKit record, or place the
sample in `SyncedSnapshotStore`. The only persisted example-mode value is one
Boolean in `UserDefaults`. **Exit & reset example mode / 退出并重置示例模式** removes
that preference, clears the visible sample, ends any sample Live Activity, and
then refreshes through the unchanged production CloudKit provider. Full
conversation titles are absent from the sample and cannot be revealed.

## Open and sign in Xcode

Use Xcode 26 or newer with the iOS 26 SDK or newer. Xcode 26 itself requires
macOS Sequoia 15.6 or newer. The project deployment target remains iOS 17.0.

1. Open `AgentIsland.xcodeproj`.
2. Edit `Config/Project.xcconfig` and verify:
   - `AGENT_ISLAND_DISPLAY_NAME = MAC版灵动岛--Agent运行监测` is available for your target stores
     and jurisdictions, or replace it with the final cleared name.
   - `AGENT_ISLAND_WIDGET_DISPLAY_NAME = Agent运行监测` remains short enough for
     the Widget and Dynamic Island surfaces.
   - `com.example.agentisland` with an App ID registered to your account.
   - `iCloud.com.example.agentisland` with a CloudKit container registered to
     that App ID.
   - the empty `AGENT_ISLAND_DEVELOPMENT_TEAM` with your 10-character Team ID.
   - the configured GitHub Pages privacy-policy and support destinations remain
     public, accurate, and controlled by you. Keep the existing split-slash
     expression (`https:$(AGENT_ISLAND_URL_SLASH)...`) so xcconfig does not
     interpret a literal `//` as a comment.
   - `MARKETING_VERSION = 0.6.1` and `CURRENT_PROJECT_VERSION = 8` still match
     the macOS release candidate and release environment.
3. Register the Widget bundle ID as the app bundle ID plus `.liveactivity` and
   keep that exact child identifier; the release validator enforces it.
4. Select the `AgentIslandMobile` shared scheme and your iPhone or a simulator.
5. Xcode uses automatic signing for both targets. Confirm that the same team is
   selected under Signing & Capabilities before installing or archiving.
6. Install an `Apple Distribution: … (TEAMID)` certificate for that exact team
   in the login keychain. The release script deliberately rejects development
   certificates, legacy `iPhone Distribution` identities, and distribution
   identities belonging to another team. If the keychain contains more than
   one certificate for the team, set `AGENT_ISLAND_IOS_DISTRIBUTION_IDENTITY`
   to the complete certificate name to select one explicitly.
7. Review the included App Icon set at final device sizes and replace it if the
   production brand artwork changes.

The app target includes `Config/AgentIslandMobile.entitlements`; its CloudKit
container value comes from `Project.xcconfig`. The placeholder container does
not grant access by itself—you must register the exact identifier in the Apple
Developer portal and enable it for the production App ID.

The App target and Widget Extension have separate privacy manifests. The App's
`Config/PrivacyInfo.xcprivacy` declares linked Other Usage Data and conditional
Other User Content (the separately opted-in conversation-title field) for App
Functionality, no tracking, and no tracking domains. It also declares the
`NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1` for the app-owned
example-mode Boolean. App Store Connect privacy answers must match both data
categories while the optional title-sync feature remains in the submitted
build. The Widget's
`WidgetExtension/PrivacyInfo.xcprivacy` declares no collected data, no accessed
API categories, no tracking, and no tracking domains. The Widget does not link
CloudKit or receive an iCloud entitlement.

## Private CloudKit record contract

The receiver reads one record from the **private database** and default record
zone. All names are configurable in `Project.xcconfig`; the defaults are:

```text
Record type: AgentIslandSnapshot
Record name: latest
Payload field: payloadJSON
```

`payloadJSON` may be a CloudKit Bytes, String, or Asset field containing the
JSON encoded by `SnapshotCodec`. The receiver enforces a 2 MB limit, schema
version, timestamp, text/count limits, cached-input invariants, and rollback
protection before replacing the iPhone cache. A missing `latest` record is
shown as the unpaired empty state and clears only the current CloudKit
account's cache. The Mac producer validates the same privacy field whitelist
and caps its encoded upload at 512 KB.

Before TestFlight, create this record type in the development environment and
deploy the CloudKit schema to production. Both Mac and iPhone must be signed
into the same iCloud account because the record lives in that user's private
database.

> **Code path implemented; production validation pending:** the Mac application
> now produces and uploads the fixed private-CloudKit record, and its local
> CLI/regression checks pass. The iPhone receiver also isolates caches by the
> verified CloudKit account. This is not yet a release-ready sync claim: the
> Mac must still be signed with the real Developer ID CloudKit entitlement and
> provisioning profile, the exact container and schema must be deployed to
> Production, and the Mac-to-iPhone flow must pass same-iCloud-account tests on
> real devices before TestFlight or App Store marketing says sync is available.

## Source map

```text
Shared/AgentSnapshot.swift                 Codable sync schema and redaction
Shared/AgentIslandActivityAttributes.swift Privacy-safe ActivityKit state
App/SyncedSnapshotStore.swift              Validated iPhone-side inbox/cache
App/CloudKitSnapshotProvider.swift         Private CloudKit fetch + offline fallback
App/DashboardStore.swift                   View state and activity lifecycle
App/DashboardView.swift                    Adaptive mobile dashboard
App/LiveActivityCoordinator.swift          Start/update/end Live Activities
WidgetExtension/AgentIslandLiveActivity.swift
                                             Lock Screen + Dynamic Island UI
Tests/DashboardStoreTests.swift              Refresh and account-state privacy tests
Tests/AgentSnapshotTests.swift               Snapshot redaction/validation tests
Tests/SnapshotFixtures.swift                 Deterministic provider and snapshot fixtures
Resources/*/Localizable.strings            English and Simplified Chinese
Config/*.plist                             Target metadata/privacy templates
Config/Project.xcconfig                    Team, bundle IDs and version numbers
Config/AgentIslandMobile.entitlements      App-only CloudKit capability
Config/PrivacyInfo.xcprivacy               App-target privacy manifest
WidgetExtension/PrivacyInfo.xcprivacy      Widget-only privacy manifest
AgentIsland.xcodeproj                      App + Widget + hosted unit-test targets
scripts/validate-project.sh                Static validation and optional build
scripts/release-ios.sh                     Signed archive and optional local IPA export
scripts/submit-testflight.sh                Exact-IPA preflight and deliberate delivery
```

## Validate

The default check uses only command-line tools available on this Mac and does
not require an iOS SDK:

```bash
./scripts/validate-project.sh
```

It validates the project object graph, target memberships, embedded extension,
unit-test host/Scheme wiring, exact Info/privacy declarations, App Store/iPhone
icon slots, icon pixel sizes and alpha channels, localization parity, and Swift
syntax/style.
After full Xcode is installed, also run a simulator build:

```bash
./scripts/validate-project.sh --build
```

Run the XCTest suite on an available iPhone simulator before every TestFlight
archive:

```bash
AGENT_ISLAND_IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro' \
  ./scripts/validate-project.sh --test
```

The suite verifies that successful refreshes keep full conversation titles
hidden until a fresh local reveal action, that leaving the foreground hides an
explicitly revealed title without discarding the validated snapshot, that
iCloud sign-out/account changes remove the previous account's snapshot and title state, and that synchronized
snapshots reject invalid source devices, duplicate identifiers, future agent
timestamps, control characters in visible text, or a title supplied without the
corresponding title-sync consent flag. It also verifies that example mode does
not consume the production provider, persists only its Boolean switch, rejects
unlabelled provider data, and returns to the real provider after reset.

Before archiving, run the release-mode check as well. It intentionally fails
while the App/Widget identifiers, Team ID, or CloudKit container are still
placeholders; with full Xcode it also verifies both targets' resolved settings:

```bash
./scripts/validate-project.sh --release
```

## Create and inspect a release archive

After the production identifiers, URLs, team, CloudKit container/schema, and
signing identities are configured on a Mac with full Xcode 26 or newer, create
a signed App Store archive with:

```bash
./scripts/release-ios.sh
```

The script runs release validation and archives to a timestamped directory
under `dist/ios`. By default, it only uses signing certificates and profiles
already installed on the Mac. If you are signed in to the intended Apple team
in Xcode and deliberately want Xcode to create or update signing assets, use:

```bash
./scripts/release-ios.sh --allow-provisioning-updates
```

This option may change signing assets in the Apple account, but never uploads
an App build. The release script accepts only an Apple Distribution identity whose
certificate subject and code-signature `TeamIdentifier` match the configured
team. For both the App and Live Activity extension it then verifies that:

- the archived `CFBundleIdentifier` and configurable display name are the exact
  configured values;
- the signed `application-identifier` exactly equals the profile's explicit
  App ID prefix plus the full bundle ID (a suffix-only match is not accepted),
  while the profile authorizes that exact identifier;
- the signed entitlement, profile `TeamIdentifier`, and certificate team all
  agree with the configured release identity;
- the exact SHA-1 fingerprint of the signing leaf certificate is the selected
  Apple Distribution identity and occurs in each target profile's
  `DeveloperCertificates` authorization list;
- the profile is unexpired, is not device-scoped or all-device, and neither
  signature nor profile enables `get-task-allow`;
- the App signature is fail-closed to the reviewed production CloudKit and
  Apple signing-baseline keys; the profile may expose a broader authorization
  allowlist but must authorize the configured container, CloudKit and
  Production environment;
- the Widget signature is fail-closed to identity/signing-baseline keys, and
  its profile contains no iCloud or ubiquity authorization;
- the App and Widget each contain their own exact reviewed privacy manifest,
  and neither manifest changes during IPA export.

The resulting metadata records the verified identifiers, signing identity,
display names, CloudKit environment, both privacy-manifest SHA-256 values, and
both profile expiration dates. To also export an App Store Connect IPA and
SHA-256 locally, run:

```bash
./scripts/release-ios.sh --export
```

If local export also needs Xcode to update signing assets, combine the two
explicit options:

```bash
./scripts/release-ios.sh --export --allow-provisioning-updates
```

The `--export` path unpacks the resulting IPA and repeats the same exact bundle,
signature, profile-expiry, team, CloudKit, and Widget no-iCloud checks against
the exported payload before writing its checksum. A successful archive check
therefore cannot mask an export-time re-signing mismatch.

Neither archive command uploads a build: `ExportOptions.plist` fixes the
destination to local `export`, and the validation script rejects upload command
paths in `release-ios.sh`. This separation ensures that creating or inspecting
an artifact cannot accidentally deliver it.

## Validate and deliberately upload the exact IPA

After running `release-ios.sh --export`, perform the credential-free local
submission preflight against its timestamped release directory:

```bash
./scripts/submit-testflight.sh --check \
  ../../dist/ios/0.6.1-8-YYYYMMDDTHHMMSSZ
```

The preflight refuses an IPA that moved outside that release directory or no
longer matches the recorded SHA-256. It unpacks the IPA and rechecks the sole
App/Widget structure, identifiers, version/build, actual App and Widget display
names, the App's privacy-policy and support URLs, arm64 device slices,
distribution signature, exact signing-certificate fingerprint and Team ID,
production CloudKit entitlement, Widget no-CloudKit boundary, export-compliance
declaration, and both reviewed privacy manifests. The values are read from the
unpacked IPA and compared with both the release metadata and the current
`Config/Project.xcconfig` display-name/URL values (including resolution of the
split URL slash setting); metadata alone is not accepted as evidence of the
packaged identity. For both embedded provisioning
profiles, the preflight also requires a future expiration, App Store distribution
shape (no device list or all-device authorization), the actual signing leaf in
`DeveloperCertificates`, and the same shared entitlement contract used during
archive creation. Executable signatures use a strict key allowlist; profiles
are treated as authorization ceilings, including Apple-managed wildcard and
baseline entries, rather than incorrectly requiring byte-for-byte entitlement
equality. It prints an artifact-specific confirmation value but performs no
network request.

Apple requires an App Store Connect app record before accepting a build. Once
that record exists and the API-key owner has a role allowed to upload builds,
store the downloaded private key outside the repository at
`~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` with no group/other read
permission. Then ask Apple to validate the already-verified IPA:

```bash
AGENT_ISLAND_ASC_API_KEY_ID='XXXXXXXXXX' \
AGENT_ISLAND_ASC_API_ISSUER_ID='00000000-0000-0000-0000-000000000000' \
  ./scripts/submit-testflight.sh --validate \
  ../../dist/ios/0.6.1-8-YYYYMMDDTHHMMSSZ
```

`--upload` is intentionally a separate operation. It first repeats the full
local preflight and App Store Connect validation, then requires
`AGENT_ISLAND_CONFIRM_TESTFLIGHT_UPLOAD` to exactly match the bundle,
version/build, and full IPA SHA-256 printed by `--check`. Do not paste that
value until the archive, privacy answers, screenshots, and production
CloudKit schema for this same build have been reviewed.

TestFlight delivery itself is not blocked by App Store screenshots. Before a
final iOS App Store submission, require `iosStoreSubmissionAssetsReady: true`
in `scripts/release-readiness.sh --json`; that platform gate includes the iOS
Chinese/English metadata, iPhone screenshots, App Icon, and shared privacy and
support materials, but does not depend on macOS-only metadata or screenshots.
The aggregate `storeSubmissionAssetsReady` becomes true only when both platform
gates are ready.

Do not combine that asset flag with TestFlight readiness by eye. Generate an
absolute readiness report and run the dedicated composition gate:

```bash
../../scripts/release-readiness.sh --json > /absolute/path/readiness.json
../../scripts/assert-release-preflight.sh ios-app-store-review \
  /absolute/path/readiness.json
```

The command passes only when `readyForIOSAppStoreReviewSelection` is true: the
same processed, installed, functionally verified TestFlight candidate has
candidate-bound privacy evidence, a non-empty App Store Connect Build ID, a
valid App Store record mode, and complete iOS-only store assets. It never
selects the build or claims that Add for Review or Submit for Review happened.

```bash
AGENT_ISLAND_ASC_API_KEY_ID='XXXXXXXXXX' \
AGENT_ISLAND_ASC_API_ISSUER_ID='00000000-0000-0000-0000-000000000000' \
AGENT_ISLAND_CONFIRM_TESTFLIGHT_UPLOAD='<exact value printed by --check>' \
  ./scripts/submit-testflight.sh --upload \
  ../../dist/ios/0.6.1-8-YYYYMMDDTHHMMSSZ
```

The private key is never a command-line argument, is never read into output,
and is never copied into `dist`. Remote modes take an atomic per-release
collaboration lock, copy the already-hashed IPA into a private read-only staging
directory, verify the copy's SHA-256, and give that copy to Apple's tool. A
response is accepted only when it is exactly one JSON object with a non-empty
success message and `product-errors`/`errors` are absent, null, or empty arrays.
Validation, upload, and delivery records are sealed mode `0444` as same-directory
temporary inodes before atomic no-overwrite publication beside the metadata. A
successful upload only starts App Store Connect processing: the delivery record
explicitly leaves processing verification, tester distribution, and App Review
submission false. Inspect all processing warnings in App Store Connect and
verify the processed bundle/version/build before enabling internal or external
TestFlight. Xcode Organizer or Apple's Transporter app remains a supported
manual fallback.

After App Store Connect reports the exact bundle/version/build as `VALID` (or
`Complete`), distribute that processed build to testers and install it from
TestFlight on a real device. Then create a local, read-only no-overwrite evidence record:

```bash
AGENT_ISLAND_CONFIRM_TESTFLIGHT_VERIFICATION='<exact bundle:version:build:IPA-SHA256>' \
  ./scripts/confirm-testflight-evidence.sh \
  --processing-state VALID \
  --app-store-connect-build-id '<Build ID shown by App Store Connect>' \
  --processing-verified-at 'YYYY-MM-DDTHH:MM:SSZ' \
  --warnings-reviewed \
  --warnings-reviewed-at 'YYYY-MM-DDTHH:MM:SSZ' \
  --distributed-to-testers \
  --installed-from-testflight \
  --tested-at 'YYYY-MM-DDTHH:MM:SSZ' \
  ../../dist/ios/<release>/testflight-delivery-<timestamp>.json
```

The confirmation script is offline and changes neither Apple state nor the
original delivery record. It re-hashes the IPA, release metadata, delivery,
validation, and upload records, independently rechecks both stored Apple
responses for the same strict success semantics, then writes a new no-overwrite
`testflight-verification-*.json`. The explicit warning attestation records that
the operator inspected every processing warning after processing verification
and before the TestFlight installation test; it is not inferred from a success
response. Point
`AGENT_ISLAND_IOS_TESTFLIGHT_VERIFICATION_EVIDENCE` at that file before running
release readiness.

Do not represent the four installed-build checks as reusable shell booleans.
After repeating the CloudKit Production-schema, same-iCloud-account
Mac-to-iPhone sync, Live Activity, and review-path checks on that exact
TestFlight installation, save one distinct redacted report or screenshot for
each check inside the same release directory. Then record the device and exact
results in a read-only, no-overwrite candidate-bound document:

```bash
AGENT_ISLAND_CONFIRM_IOS_FUNCTIONAL_QA='<exact bundle:version:build:IPA-SHA256>' \
  ./scripts/confirm-functional-qa-evidence.sh \
  --device-model 'iPhone 16 Pro' \
  --ios-version '18.6.2' \
  --tested-at 'YYYY-MM-DDTHH:MM:SSZ' \
  --cloudkit-production-schema-result passed \
  --cloudkit-evidence '/absolute/release/path/cloudkit-production-report.png' \
  --same-account-sync-result passed \
  --sync-evidence '/absolute/release/path/same-account-sync-report.png' \
  --live-activity-result passed \
  --live-activity-evidence '/absolute/release/path/live-activity-report.png' \
  --review-path-result passed \
  --review-path-evidence '/absolute/release/path/review-path-report.png' \
  '/absolute/release/path/testflight-verification-<timestamp>.json'

./scripts/validate-functional-qa-evidence.sh --json \
  --expected-testflight-verification \
    '/absolute/release/path/testflight-verification-<timestamp>.json' \
  --expected-ipa-sha256 '<exact 64-character IPA SHA-256>' \
  '/absolute/release/path/ios-functional-verification-<timestamp>.json'
```

The generator accepts only the literal result `passed`; missing, `false`, and
placeholder values fail closed. The four attachments must be different,
non-empty, non-symlink files no larger than 25 MiB. They must also have four
different device/inode identities and four different content hashes, and none
may duplicate the content hash of the IPA or a core release/evidence record.
Their canonical paths, sizes, and hashes are recorded. The JSON is atomically published without
overwrite and made mode `0444`. Validation re-hashes the complete local
TestFlight chain and attachments, independently rechecks validation/upload
success semantics, repeats credential-free IPA preflight, and ensures the
functional test happened after the recorded TestFlight install.
It does not re-query App Store Connect, so retain the original Apple responses
and use the resulting record only as operator QA evidence. Release readiness
must consume this whole record (via
`AGENT_ISLAND_IOS_FUNCTIONAL_QA_EVIDENCE`), not a copied IPA hash or four naked
booleans. A ZIP or hand-authored metadata chain cannot stand in for a signed
device IPA. This evidence does not replace App Privacy evidence:
the iOS archive entry in `AGENT_ISLAND_APP_PRIVACY_EVIDENCE` must independently
match this same platform, bundle ID, version, build number, and IPA SHA-256.

Apple's current upload guidance is kept here for the release operator:
[Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
and [Create an app record](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/).

## What remains before TestFlight

- Clear `MAC版灵动岛--Agent运行监测` (or a replacement) for the App Store and relevant trademark
  jurisdictions, then keep `AGENT_ISLAND_DISPLAY_NAME` aligned with that name.
- Replace the placeholder bundle ID and select the paid Apple Developer team.
- Register production bundle IDs and an iCloud container.
- Sign the existing Mac producer with the real Developer ID CloudKit
  entitlement/provisioning profile; verify the archived entitlement, upload,
  opt-in, title opt-in, throttling, retry, and cloud-record deletion paths.
- Deploy the exact `AgentIslandSnapshot/latest/payloadJSON` schema to the
  production CloudKit container and complete a same-iCloud-account Mac-to-iPhone
  real-device test, including sign-out/account switching and missing-record
  cache clearing.
- Run `scripts/release-ios.sh` with the real Apple Distribution identity and
  provisioning profiles; inspect the archive, use
  `scripts/submit-testflight.sh --check`, and review the exact confirmation
  before any deliberate upload.
- Verify icons, add final bilingual screenshots, recheck the published
  privacy/support URLs, and complete App Store metadata.
- Exercise pairing, offline cache, account changes, stale data, localization,
  Dynamic Type, VoiceOver, Live Activity expiry, and real-device Dynamic Island.
- Keep `PrivacyInfo.xcprivacy` and the App Store privacy answers aligned with the
  shipping sync behavior. The included manifest declares linked Other Usage Data
  plus conditional Other User Content for App Functionality because tool state,
  duration, token totals, and separately opted-in conversation titles can be
  stored in the user's private CloudKit database. It also declares UserDefaults
  reason `CA92.1` for the app-owned example-mode Boolean, with no tracking or
  analytics.
