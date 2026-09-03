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
the source user opts in, and are hidden every time the iPhone app starts.

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

Use Xcode 26 or newer. The project deployment target is iOS 17.0.

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
   - both `example.invalid` privacy-policy and support destinations with public
     HTTPS pages controlled by you. Keep the existing split-slash expression
     (`https:$(AGENT_ISLAND_URL_SLASH)...`) so xcconfig does not interpret a
     literal `//` as a comment.
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
hidden until a fresh local reveal action, that iCloud sign-out/account changes
remove the previous account's snapshot and title state, and that synchronized
snapshots reject invalid source devices, duplicate identifiers, future agent
timestamps, control characters in visible text, or a title supplied without the
corresponding title-sync consent flag. It also verifies that example mode does
not consume the production provider, persists only its Boolean switch, rejects
unlabelled provider data, and returns to the real provider after reset.

Before archiving, run the release-mode static check as well. It intentionally
fails while the privacy-policy or support URL still points at `example.invalid`:

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
under `dist/ios`. It accepts only an Apple Distribution identity whose
certificate subject and code-signature `TeamIdentifier` match the configured
team. For both the App and Live Activity extension it then verifies that:

- the archived `CFBundleIdentifier` and configurable display name are the exact
  configured values;
- the signed `application-identifier` exactly equals the provisioning
  profile value and exactly equals that profile's sole App ID prefix plus the
  full bundle ID (a suffix-only match is not accepted);
- the signed entitlement, profile entitlement, profile `TeamIdentifier`, and
  certificate team all agree;
- the profile is unexpired, is not device-scoped or all-device, and neither
  signature nor profile enables `get-task-allow`;
- the App signature and profile each contain exactly the configured CloudKit
  container, only the `CloudKit` iCloud service, and the `Production`
  container environment;
- the Widget signature and profile contain no iCloud or ubiquity entitlement;
- the App and Widget each contain their own exact reviewed privacy manifest,
  and neither manifest changes during IPA export.

The resulting metadata records the verified identifiers, signing identity,
display names, CloudKit environment, both privacy-manifest SHA-256 values, and
both profile expiration dates. To also export an App Store Connect IPA and
SHA-256 locally, run:

```bash
./scripts/release-ios.sh --export
```

The `--export` path unpacks the resulting IPA and repeats the same exact bundle,
signature, profile-expiry, team, CloudKit, and Widget no-iCloud checks against
the exported payload before writing its checksum. A successful archive check
therefore cannot mask an export-time re-signing mismatch.

Neither command uploads a build: `ExportOptions.plist` fixes the destination to
local `export`, and the validation script rejects upload command paths. Inspect
the archive and metadata first, then use Xcode Organizer/App Store Connect as
the separate, deliberate upload step.

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
  provisioning profiles; inspect the archive before any deliberate upload.
- Verify icons and add screenshots, replace privacy-policy/support URL
  placeholders, and complete App Store metadata.
- Exercise pairing, offline cache, account changes, stale data, localization,
  Dynamic Type, VoiceOver, Live Activity expiry, and real-device Dynamic Island.
- Keep `PrivacyInfo.xcprivacy` and the App Store privacy answers aligned with the
  shipping sync behavior. The included manifest declares linked Other Usage Data
  plus conditional Other User Content for App Functionality because tool state,
  duration, token totals, and separately opted-in conversation titles can be
  stored in the user's private CloudKit database. It also declares UserDefaults
  reason `CA92.1` for the app-owned example-mode Boolean, with no tracking or
  analytics.
