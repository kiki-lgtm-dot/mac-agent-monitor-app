#!/usr/bin/env node

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const publicDisplayName = 'MAC版灵动岛--Agent运行监测';

function setting(settings, key) {
  const value = settings?.[key];
  if (Array.isArray(value)) return value.join(' ').trim();
  return typeof value === 'string' ? value.trim() : '';
}

function productionBundleID(value) {
  const normalized = value.toLowerCase();
  return /^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(value)
    && !normalized.startsWith('local.')
    && !/(?:example|placeholder|yourname|yourdomain)/.test(normalized);
}

function productionContainerID(value) {
  const normalized = value.toLowerCase();
  return /^iCloud\.[A-Za-z0-9.-]+$/.test(value)
    && !/(?:example|placeholder|yourname|yourdomain)/.test(normalized);
}

function productionTeamID(value) {
  return /^[A-Z0-9]{10}$/.test(value) && !/placeholder/i.test(value);
}

function productionHTTPSURL(value) {
  try {
    const parsed = new URL(value);
    const host = parsed.hostname.toLowerCase();
    return parsed.protocol === 'https:'
      && parsed.username === ''
      && parsed.password === ''
      && host.includes('.')
      && host !== 'localhost'
      && !host.startsWith('127.')
      && !host.endsWith('.local')
      && !host.endsWith('.invalid')
      && !host.endsWith('.test')
      && !/(?:example|placeholder|yourdomain|yourname)/.test(host);
  } catch {
    return false;
  }
}

function numericVersion(value) {
  return /^\d+(?:\.\d+){1,2}$/.test(value);
}

function positiveBuild(value) {
  return /^[1-9]\d*$/.test(value);
}

function supportedPlatformsContain(settings, required) {
  const values = setting(settings, 'SUPPORTED_PLATFORMS').split(/\s+/).filter(Boolean);
  return required.every((platform) => values.includes(platform));
}

function expectedEnvironment(environment) {
  return [
    ['AGENT_ISLAND_IOS_BUNDLE_ID', 'appBundleID'],
    ['AGENT_ISLAND_IOS_WIDGET_BUNDLE_ID', 'widgetBundleID'],
    ['AGENT_ISLAND_DEVELOPMENT_TEAM', 'developmentTeam'],
    ['AGENT_ISLAND_ICLOUD_CONTAINER_ID', 'cloudKitContainerID'],
    ['AGENT_ISLAND_PRIVACY_POLICY_URL', 'privacyPolicyURL'],
    ['AGENT_ISLAND_SUPPORT_URL', 'supportURL'],
    ['AGENT_ISLAND_DISPLAY_NAME', 'displayName'],
    ['AGENT_ISLAND_VERSION', 'marketingVersion'],
    ['AGENT_ISLAND_BUILD_NUMBER', 'buildNumber'],
  ].flatMap(([environmentKey, actualKey]) => {
    const expected = environment[environmentKey]?.trim() ?? '';
    return expected ? [{ environmentKey, actualKey, expected }] : [];
  });
}

export function evaluateIOSBuildSettings(entries, environment = {}) {
  const input = Array.isArray(entries) ? entries : [];
  const appEntries = input.filter((entry) => entry?.target === 'AgentIslandMobile');
  const widgetEntries = input.filter(
    (entry) => entry?.target === 'AgentIslandLiveActivityExtension',
  );
  const targetsResolved = appEntries.length === 1 && widgetEntries.length === 1;
  const app = targetsResolved ? appEntries[0].buildSettings ?? {} : {};
  const widget = targetsResolved ? widgetEntries[0].buildSettings ?? {} : {};

  const actual = {
    appTargetName: targetsResolved ? appEntries[0].target : null,
    widgetTargetName: targetsResolved ? widgetEntries[0].target : null,
    configuration: setting(app, 'CONFIGURATION'),
    appBundleID: setting(app, 'PRODUCT_BUNDLE_IDENTIFIER'),
    widgetBundleID: setting(widget, 'PRODUCT_BUNDLE_IDENTIFIER'),
    developmentTeam: setting(app, 'DEVELOPMENT_TEAM'),
    widgetDevelopmentTeam: setting(widget, 'DEVELOPMENT_TEAM'),
    cloudKitContainerID: setting(app, 'AGENT_ISLAND_ICLOUD_CONTAINER_ID'),
    privacyPolicyURL: setting(app, 'AGENT_ISLAND_PRIVACY_POLICY_URL'),
    supportURL: setting(app, 'AGENT_ISLAND_SUPPORT_URL'),
    displayName: setting(app, 'AGENT_ISLAND_DISPLAY_NAME'),
    widgetDisplayName: setting(widget, 'AGENT_ISLAND_WIDGET_DISPLAY_NAME'),
    marketingVersion: setting(app, 'MARKETING_VERSION'),
    buildNumber: setting(app, 'CURRENT_PROJECT_VERSION'),
    deploymentTarget: setting(app, 'IPHONEOS_DEPLOYMENT_TARGET'),
  };

  const contractErrors = [];
  if (!targetsResolved) {
    contractErrors.push(
      `expected exactly one AgentIslandMobile and one AgentIslandLiveActivityExtension target; received ${appEntries.length} and ${widgetEntries.length}`,
    );
  } else {
    const checks = [
      [setting(app, 'CONFIGURATION') === 'Release', 'App settings are not resolved for Release'],
      [setting(widget, 'CONFIGURATION') === 'Release', 'Widget settings are not resolved for Release'],
      [setting(app, 'WRAPPER_EXTENSION') === 'app', 'App WRAPPER_EXTENSION must be app'],
      [setting(widget, 'WRAPPER_EXTENSION') === 'appex', 'Widget WRAPPER_EXTENSION must be appex'],
      [setting(app, 'INFOPLIST_FILE') === 'Config/App-Info.plist', 'App must use Config/App-Info.plist'],
      [setting(widget, 'INFOPLIST_FILE') === 'Config/Widget-Info.plist', 'Widget must use Config/Widget-Info.plist'],
      [
        setting(app, 'CODE_SIGN_ENTITLEMENTS') === 'Config/AgentIslandMobile.entitlements',
        'App must use Config/AgentIslandMobile.entitlements',
      ],
      [setting(widget, 'CODE_SIGN_ENTITLEMENTS') === '', 'Widget must not have an entitlements file'],
      [setting(app, 'CODE_SIGN_STYLE') === 'Automatic', 'App signing style must be Automatic'],
      [setting(widget, 'CODE_SIGN_STYLE') === 'Automatic', 'Widget signing style must be Automatic'],
      [setting(app, 'SKIP_INSTALL') === 'NO', 'App must set SKIP_INSTALL=NO'],
      [setting(widget, 'SKIP_INSTALL') === 'YES', 'Widget must set SKIP_INSTALL=YES'],
      [
        setting(widget, 'APPLICATION_EXTENSION_API_ONLY') === 'YES',
        'Widget must set APPLICATION_EXTENSION_API_ONLY=YES',
      ],
      [
        supportedPlatformsContain(app, ['iphoneos', 'iphonesimulator']),
        'App must support iphoneos and iphonesimulator',
      ],
      [
        supportedPlatformsContain(widget, ['iphoneos', 'iphonesimulator']),
        'Widget must support iphoneos and iphonesimulator',
      ],
      [setting(app, 'TARGETED_DEVICE_FAMILY') === '1', 'App must remain iPhone-only'],
      [setting(widget, 'TARGETED_DEVICE_FAMILY') === '1', 'Widget must remain iPhone-only'],
      [
        actual.widgetBundleID === `${actual.appBundleID}.liveactivity`,
        'Widget bundle ID must equal the App bundle ID plus .liveactivity',
      ],
      [
        actual.developmentTeam === actual.widgetDevelopmentTeam,
        'App and Widget must resolve to the same Development Team',
      ],
      [
        setting(app, 'AGENT_ISLAND_APP_BUNDLE_ID') === actual.appBundleID,
        'App bundle ID must match AGENT_ISLAND_APP_BUNDLE_ID',
      ],
      [
        setting(widget, 'AGENT_ISLAND_WIDGET_BUNDLE_ID') === actual.widgetBundleID,
        'Widget bundle ID must match AGENT_ISLAND_WIDGET_BUNDLE_ID',
      ],
      [
        setting(widget, 'MARKETING_VERSION') === actual.marketingVersion
          && setting(widget, 'CURRENT_PROJECT_VERSION') === actual.buildNumber,
        'App and Widget version/build settings must match',
      ],
    ];
    for (const [valid, message] of checks) {
      if (!valid) contractErrors.push(message);
    }
  }

  const productionErrors = [];
  const productionChecks = [
    [productionBundleID(actual.appBundleID), 'App bundle ID is not production-ready'],
    [productionBundleID(actual.widgetBundleID), 'Widget bundle ID is not production-ready'],
    [productionTeamID(actual.developmentTeam), 'Development Team is not production-ready'],
    [productionContainerID(actual.cloudKitContainerID), 'CloudKit container is not production-ready'],
    [productionHTTPSURL(actual.privacyPolicyURL), 'Privacy Policy URL is not production-ready'],
    [productionHTTPSURL(actual.supportURL), 'Support URL is not production-ready'],
    [actual.displayName === publicDisplayName, 'App display name does not match the public name'],
    [
      Array.from(actual.widgetDisplayName).length >= 2
        && Array.from(actual.widgetDisplayName).length <= 30,
      'Widget display name must contain 2-30 characters',
    ],
    [numericVersion(actual.marketingVersion), 'Marketing version is not numeric'],
    [positiveBuild(actual.buildNumber), 'Build number is not a positive integer'],
    [
      Number.parseFloat(actual.deploymentTarget) >= 17,
      'iOS deployment target must be 17.0 or newer',
    ],
  ];
  for (const [valid, message] of productionChecks) {
    if (!valid) productionErrors.push(message);
  }

  const environmentMismatches = expectedEnvironment(environment).flatMap((expectation) => {
    const actualValue = actual[expectation.actualKey] ?? '';
    return actualValue === expectation.expected
      ? []
      : [{
          environmentKey: expectation.environmentKey,
          expected: expectation.expected,
          actual: actualValue,
        }];
  });

  const targetContractReady = targetsResolved && contractErrors.length === 0;
  const productionConfigurationReady = targetContractReady && productionErrors.length === 0;
  const environmentMatches = targetsResolved && environmentMismatches.length === 0;
  return {
    schemaVersion: 1,
    targetsResolved,
    targetContractReady,
    productionConfigurationReady,
    environmentMatches,
    ready: productionConfigurationReady && environmentMatches,
    actual,
    targetCounts: {
      app: appEntries.length,
      widget: widgetEntries.length,
    },
    contractErrors,
    productionErrors,
    environmentMismatches,
  };
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : '';
if (invokedPath === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 3) {
    console.error('Usage: validate-build-settings.mjs <xcodebuild-showBuildSettings.json>');
    process.exit(2);
  }
  try {
    const entries = JSON.parse(readFileSync(process.argv[2], 'utf8'));
    process.stdout.write(`${JSON.stringify(evaluateIOSBuildSettings(entries, process.env), null, 2)}\n`);
  } catch (error) {
    console.error(`iOS build-settings validation failed: ${error.message}`);
    process.exit(1);
  }
}
