# Aivulet Privacy Policy (Draft)

Effective date: [Effective Date: YYYY-MM-DD]
Developer: [Developer Legal Name]
Contact email: [Support Email]
Privacy policy URL: [Privacy Policy URL]

> Publication note: This draft reflects Aivulet 0.6.1 as currently implemented and is not legal advice. Replace every placeholder and review the policy against the shipping build, the final translation-service arrangement, and applicable laws before publication.

## 1. Scope

This policy applies to Aivulet for macOS and, when offered, its iPhone companion (together, the “App”). The Mac app provides a top-of-screen panel for viewing local AI-agent activity and token usage, along with website shortcuts, notes, and an optional user-initiated translation and learning tool. The iPhone app displays a reduced agent-status summary that the user chooses to sync.

The Mac CloudKit producer and account-isolated iPhone receiver code paths are implemented, and the producer has passed local CLI/regression checks. However, the real Developer ID CloudKit entitlement and provisioning profile, production container/schema, same-iCloud-account Mac-to-iPhone device flow, and submission-ready archive have not all been verified. Sync must not be represented as release-ready until those checks pass. Before publication, this policy must be checked again against the final signed build and App Privacy answers. Third-party AI services, websites, and other applications selected by the user are governed by their own privacy policies.

## 2. Core principles

- Agent and tool discovery, log parsing, token aggregation, and workspace storage take place on the user's Mac by default.
- Private iCloud sync is off by default. A reduced snapshot is uploaded only after the user reviews the off-device fields and expressly opts in.
- The App does not upload agent prompts, response bodies, project files, or workspace contents to the developer.
- The translation feature accesses the network only after the user enters text and expressly selects “Translate only” or “Analyze for learning.”
- The App contains no advertising, cross-app tracking, analytics SDK, or developer-operated telemetry service.

## 3. Data read and processed on the device

### 3.1 Agent, IDE, and log information

To provide monitoring features, the App performs read-only checks on the Mac for:

- whether common AI and IDE applications are installed or running and which supported extensions are installed;
- local Codex SQLite/JSONL logs and local Claude Code JSONL logs;
- custom JSONL sources that the user adds using the file picker, an absolute path, or a connection code; and
- available conversation titles, agent names, model names, project paths, statuses, timestamps, active durations, token counts, and source-attribution metadata.

This information is used on the device to produce live status, usage-history, tool, and conversation views. The App does not estimate missing token usage from runtime and does not upload these logs to the developer. Titles, paths, or log content created by other applications may contain information the user considers sensitive. The App provides a privacy mask for some visible fields.

### 3.2 Workspace content

Website shortcuts, notes, and translation results that the user saves to the study list are stored at:

`~/Library/Application Support/AgentIsland/workspace.json`

A website is handed to the default macOS browser only after the user selects “Open.” The App does not fetch website content in the background.

### 3.3 Local settings and credentials

- Interface language, translation endpoint, model name, custom-source paths, and aggregate translation token usage are stored in local preferences.
- Translation API keys are stored in macOS Keychain and configured to be accessible only on this device while unlocked.
- The web interface can see only whether a key is configured; it cannot read the key itself.
- API keys are not written to the workspace file, web localStorage, diagnostic snapshots, or app logs.

### 3.4 iPhone local cache

The iPhone fetches one fixed snapshot from the current user's private CloudKit database, validates its size, schema, timestamps, text, and token consistency, and atomically writes it to the iPhone sandbox. Cache directories are separated by an irreversible SHA-256 digest of the CloudKit user record identifier. After the same account is verified, a temporary CloudKit error may show that account's last valid cache with an offline label. Signing out of or changing iCloud accounts never falls back to another account's cache.

## 4. Translation and network transfer

Translation is optional. After the user expressly submits a request, the App sends the following to the OpenAI-compatible endpoint shown in and configured through the App:

- the text currently submitted by the user;
- source language, target language, and translation or learning mode;
- the selected model name;
- system instructions requesting a structured translation, definition, breakdown, keywords, and examples; and
- if configured, the API key needed to authenticate to that endpoint.

The current development build's default endpoint points to the DeepSeek API, but the user can replace it with another supported HTTPS endpoint or a local loopback service. The developer does not receive translation requests or responses. The App uses an ephemeral network session without cookies or URL caching, permits only same-origin redirects, and caps response size.

If the release build retains that default, users should note the following. DeepSeek's current published [Privacy Policy](https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html) says that the Personal Data it covers is directly collected, processed, and stored in the People's Republic of China and that User Input may be used to develop, improve, and train its services and technology. The same policy expressly says that it does not cover the specific processing rules for end users of downstream applications built with the open platform. DeepSeek's [Open Platform Terms of Service](https://cdn.deepseek.com/policies/en-US/deepseek-open-platform-terms-of-service.html) require the downstream-app operator to disclose its processing rules and obtain consent or another legal basis for delegating processing to DeepSeek. As of September 2, 2026, those public materials do not publish a fixed retention period for this downstream App's API requests or an API-specific no-training commitment. The App therefore makes neither promise.

The selected endpoint may receive the IP address and request metadata needed for the connection, as well as the submitted text, and may retain or process that information under its own terms. Users should review the selected provider's privacy and retention terms and must not submit confidential, personal, or regulated information they are not authorized to disclose.

Translation results remain only in current app memory by default. The original and result are written to the local workspace file only when the user selects “Save to study.” Token usage returned by the service is retained as an aggregate on-device counter.

## 5. CloudKit sync, developer collection, sharing, and tracking

Optional private iCloud sync is off by default. When the user first enables it, the App explains that data will leave the Mac. Only after confirmation does the Mac write one fixed `latest` record to the private CloudKit database associated with the user's Apple ID. The reduced snapshot contains agent/tool categories and safe display names, state, active duration, token totals, timestamps, counts, and ephemeral ordinal identifiers. It excludes prompts, task summaries, response bodies, project/file paths, model names, API keys, notes, and translation content.

Full conversation titles are excluded by default. Only after a separate sensitive-field confirmation may an explicitly identified title source be included after length, path, and secret-pattern filtering. The iPhone still hides these titles on every launch, and Live Activities never contain titles.

The Widget Extension does not connect to CloudKit and has no iCloud entitlement. The iPhone host app supplies ActivityKit only with title-free counts, state, duration, token totals, and update time. The Live Activity receives new state only when the host app launches, returns to the foreground, or the user manually refreshes; it has no APNs background remote-update path. After two minutes without a host-app update, the system presentation marks the state stale. When the app relaunches, it can restore the control state of an existing system Live Activity.

CloudKit is provided by Apple. The record is stored in the user's private database and does not pass through a developer-operated sync server. This sync data is disclosed in App Privacy and the Privacy Manifest as **Other Usage Data**, **linked to the user**, used for **App Functionality**, and **not used for tracking**. Because the current release candidate retains optional title sync, both the macOS and iOS App privacy manifests already also declare **Other User Content**, linked to the user, for App Functionality, and not for tracking. The App Store Connect answers must use the same scope before submission. Apple's processing of iCloud and CloudKit is also governed by Apple's terms and privacy policy.

Apart from the user-selected CloudKit path above and the user-initiated translation request in Section 4, the current version:

- sends no data to a server operated by the developer;
- does not sell user data;
- does not use data for advertising, advertising measurement, or tracking across apps or websites;
- includes no third-party analytics, advertising, or crash-reporting SDK; and
- does not create user profiles or perform automated identification.

If another remote sync path, accounts, analytics, crash reporting, APNs-based remote Live Activity updates, or a developer-hosted translation service is added later, the developer will update this policy, in-app disclosure, and App Store privacy labels before release and obtain consent where required.

## 6. Retention and deletion

On-device data remains until the user deletes the relevant content or local files:

- website shortcuts, notes, and study entries can be deleted in the App;
- custom sources can be removed from the Data Sources view; disconnecting a source does not delete its original JSONL file;
- translation API keys can be cleared in translator settings;
- original Codex, Claude Code, and other tool logs are controlled by those tools and are never deleted or modified by the App;
- when the user turns off private sync on the Mac, the App immediately stops uploads and requests deletion of the `latest` record from the user's private CloudKit database. Cloud deletion requires iCloud/network availability, so the user should confirm the displayed status or retry if needed. When the iPhone next refreshes and finds that record missing, it clears only the current iCloud account's local cache; and
- removing the App may leave Application Support files, preferences, and Keychain items in macOS. Users can follow the removal instructions at [Support URL] or contact [Support Email].

Aivulet has no developer-operated account or data server. The developer therefore generally cannot view, export, or delete on-device data or data in a user's private CloudKit database on the user's behalf; users should use the in-app deletion controls and private-sync switch described above.

## 7. Security

The App processes supported external logs read-only; applies file type, count, and size limits to custom sources; writes the workspace atomically with local file permissions; stores API keys in macOS Keychain; restricts translation requests to HTTPS or local loopback HTTP; and limits redirects and response size. No software can guarantee absolute security, and users remain responsible for protecting their Mac account, disk, and API credentials.

## 8. Children

The App is a general-purpose development and productivity tool and is not directed specifically to children. The developer does not knowingly collect children's personal information. Age requirements for translation services are set by the service selected by the user.

## 9. Changes to this policy

This policy may change as features, laws, or distribution channels change. Material changes will be communicated through an in-app notice, product page, or another appropriate method, and the effective date above will be updated.

## 10. Contact

Questions about this policy or Aivulet's privacy practices can be directed to:

- Developer: [Developer Legal Name]
- Email: [Support Email]
- Support page: [Support URL]
