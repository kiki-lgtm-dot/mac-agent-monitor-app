# Public privacy and support page evidence

`scripts/capture-public-pages-evidence.mjs` records a small local assertion snapshot that the release-configured privacy and support pages were publicly reachable and passed a minimum static HTML renderability screen at a specific time. It does not save response bodies, cookies, request headers, credentials, or DNS results.

This snapshot is a fail-closed guardrail against release mix-ups, not an independent remote attestation. Mode `0444` only discourages accidental local edits: the repository owner can replace the file. Likewise, its SHA-256 values detect byte drift only when a trusted release process separately pins or rechecks them; they are not digital signatures.

This evidence is a release input, not a deployment tool. The command performs HTTPS `GET` requests only. It never changes the website, App Store Connect, CloudKit, or Apple signing state.

## Capture

The default command reads the product name and both URLs from `ApplePlatforms/iOS/Config/Project.xcconfig`, binds the result to `.release/identity.lock.json`, and publishes `.release/public-pages-evidence.json`:

```sh
node scripts/capture-public-pages-evidence.mjs
```

The default output is deliberately no-overwrite. Use an explicitly reviewed new repository-local name for another capture:

```sh
node scripts/capture-public-pages-evidence.mjs \
  --output .release/public-pages-evidence-20260904T120000Z.json
```

To bind a capture to a sealed submission manifest instead of the identity lock:

```sh
node scripts/capture-public-pages-evidence.mjs \
  --submission-manifest .release/app-store-submission.json \
  --output .release/public-pages-evidence-submission.json
```

Bindings are deliberately restricted to the canonical `.release/identity.lock.json` and `.release/app-store-submission.json` paths. The identity lock must not be accessible by group or other users. Its exact envelope and identity schemas, production identifiers, fixed CloudKit contract, current project settings, and the SHA-256 of all three `appliedFiles` are validated. A submission manifest must be read-only and strict JSON; the tool validates its exact object contracts, final product/record mode, macOS/iOS identifiers and versions, localization URLs, commerce/review/TestFlight structures, identity-lock SHA, and sealed screenshot-evidence SHA. Draft placeholders are rejected.

All binding sources and dependencies must be regular, canonical, repository-local files without symlink traversal. The tool revalidates the binding and dependent inode/SHA snapshot after both page requests and before publishing evidence. Binding to the submission manifest is preferable once that manifest has passed its own release validator, because it ties the page observation to the concrete App Store submission decisions as well as the identity lock.

The repository's fixed production origin is `https://kiki-lgtm-dot.github.io`. Moving the configured pages to another public origin requires an explicit, origin-only allowlist entry:

```sh
node scripts/capture-public-pages-evidence.mjs \
  --allow-origin https://www.example.org \
  --output .release/public-pages-evidence-new-origin.json
```

An explicit allowlist does not permit IP-literal, loopback, `.local`, `.localhost`, `.internal`, test, or other non-public hostnames. Production HTTPS requests resolve and pin public addresses before connecting, reject private/reserved IPv4 and IPv6 (including embedded-private NAT64 and 6to4 forms), and recheck the connected socket's remote address after TLS connection. Redirects must remain on the configured URL's exact origin.

The content check is **static HTML renderability screening**, not a browser rendering assertion. It excludes comments, non-rendered HTML containers, `hidden`, `aria-hidden="true"`, and recognized `display:none` / `visibility:hidden` inline styles from the visible HTML structure. It does not execute CSS layout or evaluate selector rules from embedded or external stylesheets. A class rule such as `.release-anchor { display: none }` can therefore change actual browser visibility without being resolved by this tool. A `true` validation field means only that the anchor passed this static visible-HTML-structure screen. Before submission, release staff must open both final URLs in a real browser and manually confirm the product name, bilingual purpose text, deletion route, and support route are actually visible and usable.

For each page the capture requires:

- a credential-free HTTPS URL without a query or fragment, on the fixed or explicitly allowed origin; privacy and support URLs must differ;
- no more than five same-origin redirects and a total request deadline of 10 seconds;
- a final `2xx` response with UTF-8/ASCII `text/html` and identity content encoding;
- at most 1 MiB of response bytes;
- the exact configured product name in the visible HTML structure;
- both Chinese and English `lang` markup in the visible HTML structure;
- bilingual privacy-purpose text plus an exact `delete-data` / `delete-data-en` target in the privacy page's visible HTML structure; and
- bilingual support-purpose text plus a real `mailto:` or HTTPS support/contact link in the support page's visible HTML structure.

Comments, `script`/`style` contents, `<template>` content, and statically recognized hidden subtrees do not satisfy product, purpose, contact, or deletion checks. An email-looking string or an anchor-like substring is not sufficient. Selector-based CSS remains outside this screen and is covered by the required browser review.

The result is staged in the destination directory, synced, changed to mode `0444`, and published with an atomic no-overwrite hard link. A failure leaves no evidence body or partial public file.

## Evidence fields

The exact schema is [PUBLIC_PAGES_EVIDENCE.schema.json](./PUBLIC_PAGES_EVIDENCE.schema.json). The top-level shape is:

```json
{
  "schemaVersion": 1,
  "evidenceType": "public-pages",
  "productName": "MAC版灵动岛--Agent运行监测",
  "configuredURLs": {
    "privacy": "https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/",
    "support": "https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/"
  },
  "allowedOrigins": [
    "https://kiki-lgtm-dot.github.io"
  ],
  "binding": {
    "type": "identity-lock",
    "path": ".release/identity.lock.json",
    "sha256": "<64 lowercase hexadecimal characters>"
  },
  "pages": [
    {
      "kind": "privacy",
      "configuredURL": "<configured HTTPS URL>",
      "finalURL": "<validated same-origin final URL>",
      "status": 200,
      "contentType": "text/html; charset=utf-8",
      "bodySizeBytes": 12345,
      "bodySHA256": "<64 lowercase hexadecimal characters>",
      "redirectCount": 0,
      "checkedAt": "2026-09-04T12:00:00Z",
      "validations": {
        "productName": true,
        "bilingualLanguages": true,
        "pagePurpose": true,
        "contactOrDeletionPath": true
      }
    },
    {
      "kind": "support",
      "configuredURL": "<configured HTTPS URL>",
      "finalURL": "<validated same-origin final URL>",
      "status": 200,
      "contentType": "text/html; charset=utf-8",
      "bodySizeBytes": 12345,
      "bodySHA256": "<64 lowercase hexadecimal characters>",
      "redirectCount": 0,
      "checkedAt": "2026-09-04T12:00:01Z",
      "validations": {
        "productName": true,
        "bilingualLanguages": true,
        "pagePurpose": true,
        "contactOrDeletionPath": true
      }
    }
  ],
  "createdAt": "2026-09-04T12:00:01Z"
}
```

`bodySHA256` hashes the exact HTTP entity bytes received with `Accept-Encoding: identity`; it is not a hash of normalized text. The response body itself is never included. A matching hash says only that two local observations saw the same bytes; it does not prove who served them.

## Offline verification

Release readiness must not contact the website. Verify an existing record offline instead:

```sh
node scripts/capture-public-pages-evidence.mjs \
  --verify .release/public-pages-evidence.json
```

Verification performs no network operation. It checks:

- canonical repository-local evidence and binding paths with no symlinks;
- evidence mode exactly `0444` and current binding permissions;
- the exact closed JSON shape and every page field;
- current xcconfig product name and privacy/support URLs;
- the fixed/explicit origin allowlist and same-origin final URLs;
- the canonical binding path, strict binding schema and semantics, current binding SHA-256, and bound dependency hashes; and
- `createdAt` and both `checkedAt` values against the default 86,400-second maximum age, with only five minutes of future clock tolerance.

Because response bodies are intentionally omitted, offline verification rechecks the sealed static-screen claims and their bindings; it does not rerender the page or replace the manual browser confirmation described above.

For a custom origin, repeat the same reviewed allowlist during verification. A shorter or longer release-policy window, up to 31 days, can be selected explicitly:

```sh
node scripts/capture-public-pages-evidence.mjs \
  --verify .release/public-pages-evidence-new-origin.json \
  --allow-origin https://www.example.org \
  --max-age-seconds 43200
```

Successful verification prints JSON for an offline readiness consumer:

```json
{
  "valid": true,
  "evidencePath": "/absolute/repository/path/.release/public-pages-evidence.json",
  "evidenceSHA256": "<sha256>",
  "binding": {
    "type": "identity-lock",
    "path": "/absolute/repository/path/.release/identity.lock.json",
    "sha256": "<sha256>"
  },
  "productName": "MAC版灵动岛--Agent运行监测",
  "configuredURLs": {
    "privacy": "<configured URL>",
    "support": "<configured URL>"
  },
  "oldestCheckedAt": "<UTC timestamp>",
  "newestCheckedAt": "<UTC timestamp>",
  "maxAgeSeconds": 86400
}
```

The verifier's stdout contract is the exact top-level field set shown above: `valid`, `evidencePath`, `evidenceSHA256`, `binding`, `productName`, `configuredURLs`, `oldestCheckedAt`, `newestCheckedAt`, and `maxAgeSeconds`. `binding` contains exactly `type`, absolute `path`, and `sha256`; `configuredURLs` contains exactly `privacy` and `support`. A capture instead prints two human-readable stdout lines containing the absolute evidence path and evidence SHA-256.

`--help`, successful capture, and successful verification exit `0`. A rejected option, unsafe URL/path, network/capture failure, stale or malformed evidence, binding failure, or no-overwrite conflict exits `1`, writes a sanitized single-line error to stderr, and emits no verification JSON. Readiness integrations should consume stdout only after exit `0` and should still validate the documented closed field set.

Run the offline fixture suite with:

```sh
./Tests/test-public-pages-evidence.sh
```
