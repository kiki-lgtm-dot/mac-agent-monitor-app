#!/usr/bin/env node

import {
  AscSnapshotError,
  createAscClient,
  formatPublicError,
  writeImmutableSnapshot,
} from "./app-store-connect-api.mjs";
import {
  captureSubmissionMetadataSnapshot,
  verifySubmissionMetadataSnapshotFile,
} from "./app-store-connect-submission-metadata.mjs";

function invalid(message) {
  return new AscSnapshotError("INVALID_ARGUMENTS", message);
}

function usage() {
  process.stdout.write(`Usage:
  capture-asc-submission-metadata.mjs --manifest ABSOLUTE_PATH \\
    --build-snapshot ABSOLUTE_PATH --bundle-id ID --platform iOS|macOS \\
    --version VERSION --build BUILD --artifact ABSOLUTE_PATH \\
    --identity-lock ABSOLUTE_PATH --output ABSOLUTE_PATH [--project-root ABSOLUTE_PATH]

  capture-asc-submission-metadata.mjs --verify ABSOLUTE_SNAPSHOT_PATH \\
    --manifest ABSOLUTE_PATH --build-snapshot ABSOLUTE_PATH --bundle-id ID \\
    --platform iOS|macOS --version VERSION --build BUILD \\
    --artifact ABSOLUTE_PATH --identity-lock ABSOLUTE_PATH \\
    [--max-age-seconds 900] [--project-root ABSOLUTE_PATH]

Capture performs authenticated GET requests only. It compares the selected
App Store Connect app, App Info, App Store version, selected Build, localized
metadata, redacted review-match flags, and (for iOS) TestFlight metadata with
the sealed .release/app-store-submission.json manifest. Demo account names and
passwords are never requested or written; their availability remains a manual
release check.

The coverage contract deliberately keeps remoteMetadataComparisonComplete
false while tax, DSA, rating, EULA, pricing, screenshots, and other manual
release evidence remain outside this read-only snapshot.
`);
}

function parseArguments(argv) {
  const options = {};
  const names = new Map([
    ["--manifest", "manifestPath"],
    ["--build-snapshot", "buildSnapshotPath"],
    ["--bundle-id", "bundleId"],
    ["--platform", "platform"],
    ["--version", "version"],
    ["--build", "build"],
    ["--artifact", "artifactPath"],
    ["--identity-lock", "identityLockPath"],
    ["--project-root", "projectRoot"],
    ["--output", "outputPath"],
    ["--verify", "verifyPath"],
    ["--max-age-seconds", "maxAgeSeconds"],
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--help" || argument === "-h") {
      if (argv.length !== 1) throw invalid("--help cannot be combined with other options");
      options.help = true;
      continue;
    }
    const property = names.get(argument);
    if (!property) throw invalid("an unknown option was provided");
    if (Object.hasOwn(options, property)) throw invalid(`option may be provided only once: ${argument}`);
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) throw invalid(`missing value for ${argument}`);
    options[property] = value;
    index += 1;
  }
  return options;
}

function requireOptions(options, properties) {
  for (const property of properties) {
    if (typeof options[property] !== "string" || options[property].length === 0) {
      throw invalid(`missing required option for ${property}`);
    }
  }
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.help) {
    usage();
    return;
  }
  requireOptions(options, [
    "manifestPath", "buildSnapshotPath", "bundleId", "platform", "version", "build",
    "artifactPath", "identityLockPath",
  ]);
  const common = {
    manifestPath: options.manifestPath,
    buildSnapshotPath: options.buildSnapshotPath,
    bundleId: options.bundleId,
    platform: options.platform,
    version: options.version,
    build: options.build,
    artifactPath: options.artifactPath,
    identityLockPath: options.identityLockPath,
    ...(options.projectRoot === undefined ? {} : { projectRoot: options.projectRoot }),
  };
  if (options.verifyPath) {
    if (options.outputPath) throw invalid("--output cannot be used with --verify");
    const maxAgeSeconds = options.maxAgeSeconds === undefined ? undefined : Number(options.maxAgeSeconds);
    const verification = verifySubmissionMetadataSnapshotFile(options.verifyPath, {
      ...common,
      ...(maxAgeSeconds === undefined ? {} : { maxAgeSeconds }),
    });
    process.stdout.write(`${JSON.stringify(verification, null, 2)}\n`);
    return;
  }
  if (options.maxAgeSeconds !== undefined) throw invalid("--max-age-seconds is valid only with --verify");
  requireOptions(options, ["outputPath"]);
  const snapshot = await captureSubmissionMetadataSnapshot({
    client: createAscClient(),
    ...common,
  });
  const published = writeImmutableSnapshot(options.outputPath, snapshot);
  const verification = verifySubmissionMetadataSnapshotFile(options.outputPath, common);
  process.stdout.write(`${JSON.stringify({ created: true, ...published, verification }, null, 2)}\n`);
}

main().catch((error) => {
  process.stderr.write(`${formatPublicError(error, "App Store Connect submission metadata snapshot failed")}\n`);
  process.exitCode = 2;
});
