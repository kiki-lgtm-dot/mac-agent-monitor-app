#!/usr/bin/env node

import {
  AscSnapshotError,
  captureAppSnapshot,
  createAscClient,
  formatPublicError,
  verifySnapshotFile,
  writeImmutableSnapshot,
} from "./app-store-connect-api.mjs";

const SNAPSHOT_KIND = "app-store-connect-app-snapshot";

function invalidArguments(message) {
  return new AscSnapshotError("INVALID_ARGUMENTS", message);
}

function usage() {
  process.stdout.write(`Usage:
  capture-asc-app-snapshot.mjs --bundle-id ID --artifact ABSOLUTE_PATH \\
    --identity-lock ABSOLUTE_PATH --output ABSOLUTE_PATH

  capture-asc-app-snapshot.mjs --verify ABSOLUTE_SNAPSHOT_PATH \\
    --bundle-id ID --artifact ABSOLUTE_PATH --identity-lock ABSOLUTE_PATH \\
    [--max-age-seconds 900]

Capture mode performs only authenticated GET requests to Apple's fixed
https://api.appstoreconnect.apple.com host. It reads credentials from:
  AGENT_ISLAND_ASC_API_KEY_ID
  AGENT_ISLAND_ASC_API_ISSUER_ID
and the private key from:
  ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8

Verify mode is offline. It checks the snapshot schema, self-digest, 0444 mode,
freshness, and the current artifact and complete repository
.release/identity.lock.json binding.
`);
}

function parseArguments(argv) {
  const options = {};
  const valueOptions = new Map([
    ["--bundle-id", "bundleId"],
    ["--artifact", "artifactPath"],
    ["--identity-lock", "identityLockPath"],
    ["--output", "outputPath"],
    ["--verify", "verifyPath"],
    ["--max-age-seconds", "maxAgeSeconds"],
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--help" || argument === "-h") {
      if (argv.length !== 1) throw invalidArguments("--help cannot be combined with other arguments");
      options.help = true;
      continue;
    }
    const property = valueOptions.get(argument);
    if (!property) throw invalidArguments("an unknown option was provided");
    if (Object.hasOwn(options, property)) throw invalidArguments(`option may be provided only once: ${argument}`);
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) throw invalidArguments(`missing value for ${argument}`);
    options[property] = value;
    index += 1;
  }
  return options;
}

function requireOptions(options, names) {
  for (const name of names) {
    if (typeof options[name] !== "string" || options[name].length === 0) {
      throw invalidArguments(`missing required option for ${name}`);
    }
  }
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.help) {
    usage();
    return;
  }

  requireOptions(options, ["bundleId", "artifactPath", "identityLockPath"]);
  if (options.verifyPath) {
    if (options.outputPath) throw invalidArguments("--output cannot be used with --verify");
    const maxAgeSeconds = options.maxAgeSeconds === undefined
      ? undefined
      : Number(options.maxAgeSeconds);
    const result = verifySnapshotFile(options.verifyPath, {
      kind: SNAPSHOT_KIND,
      bundleId: options.bundleId,
      artifactPath: options.artifactPath,
      identityLockPath: options.identityLockPath,
      maxAgeSeconds,
    });
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return;
  }

  if (options.maxAgeSeconds !== undefined) {
    throw invalidArguments("--max-age-seconds is valid only with --verify");
  }
  requireOptions(options, ["outputPath"]);
  const client = createAscClient();
  const snapshot = await captureAppSnapshot({
    client,
    bundleId: options.bundleId,
    artifactPath: options.artifactPath,
    identityLockPath: options.identityLockPath,
  });
  const published = writeImmutableSnapshot(options.outputPath, snapshot);
  const verification = verifySnapshotFile(options.outputPath, {
    kind: SNAPSHOT_KIND,
    bundleId: options.bundleId,
    artifactPath: options.artifactPath,
    identityLockPath: options.identityLockPath,
  });
  process.stdout.write(`${JSON.stringify({ created: true, ...published, verification }, null, 2)}\n`);
}

main().catch((error) => {
  process.stderr.write(`${formatPublicError(error, "App Store Connect app snapshot failed")}\n`);
  process.exitCode = 2;
});
