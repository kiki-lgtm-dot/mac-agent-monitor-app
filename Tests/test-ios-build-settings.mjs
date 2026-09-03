#!/usr/bin/env node

import assert from 'node:assert/strict';
import { evaluateIOSBuildSettings } from '../ApplePlatforms/iOS/scripts/validate-build-settings.mjs';

function settings(overrides = {}) {
  const shared = {
    CONFIGURATION: 'Release',
    CODE_SIGN_STYLE: 'Automatic',
    SUPPORTED_PLATFORMS: 'iphoneos iphonesimulator',
    TARGETED_DEVICE_FAMILY: '1',
    DEVELOPMENT_TEAM: 'ABCDE12345',
    AGENT_ISLAND_APP_BUNDLE_ID: 'com.agentisland.mobile',
    AGENT_ISLAND_WIDGET_BUNDLE_ID: 'com.agentisland.mobile.liveactivity',
    AGENT_ISLAND_ICLOUD_CONTAINER_ID: 'iCloud.com.agentisland.mobile',
    AGENT_ISLAND_PRIVACY_POLICY_URL: 'https://agentisland.app/privacy',
    AGENT_ISLAND_SUPPORT_URL: 'https://agentisland.app/support',
    AGENT_ISLAND_DISPLAY_NAME: 'MAC版灵动岛--Agent运行监测',
    AGENT_ISLAND_WIDGET_DISPLAY_NAME: 'Agent运行监测',
    MARKETING_VERSION: '0.6.1',
    CURRENT_PROJECT_VERSION: '8',
    IPHONEOS_DEPLOYMENT_TARGET: '17.0',
    ...overrides,
  };
  return [
    {
      target: 'AgentIslandMobile',
      buildSettings: {
        ...shared,
        WRAPPER_EXTENSION: 'app',
        INFOPLIST_FILE: 'Config/App-Info.plist',
        CODE_SIGN_ENTITLEMENTS: 'Config/AgentIslandMobile.entitlements',
        SKIP_INSTALL: 'NO',
        PRODUCT_BUNDLE_IDENTIFIER: shared.AGENT_ISLAND_APP_BUNDLE_ID,
      },
    },
    {
      target: 'AgentIslandLiveActivityExtension',
      buildSettings: {
        ...shared,
        WRAPPER_EXTENSION: 'appex',
        INFOPLIST_FILE: 'Config/Widget-Info.plist',
        CODE_SIGN_ENTITLEMENTS: '',
        SKIP_INSTALL: 'YES',
        APPLICATION_EXTENSION_API_ONLY: 'YES',
        PRODUCT_BUNDLE_IDENTIFIER: shared.AGENT_ISLAND_WIDGET_BUNDLE_ID,
      },
    },
  ];
}

const valid = evaluateIOSBuildSettings(settings());
assert.equal(valid.targetsResolved, true);
assert.equal(valid.targetContractReady, true);
assert.equal(valid.productionConfigurationReady, true);
assert.equal(valid.environmentMatches, true);
assert.equal(valid.ready, true);

const matchingEnvironment = evaluateIOSBuildSettings(settings(), {
  AGENT_ISLAND_IOS_BUNDLE_ID: 'com.agentisland.mobile',
  AGENT_ISLAND_IOS_WIDGET_BUNDLE_ID: 'com.agentisland.mobile.liveactivity',
  AGENT_ISLAND_DEVELOPMENT_TEAM: 'ABCDE12345',
  AGENT_ISLAND_ICLOUD_CONTAINER_ID: 'iCloud.com.agentisland.mobile',
  AGENT_ISLAND_PRIVACY_POLICY_URL: 'https://agentisland.app/privacy',
  AGENT_ISLAND_SUPPORT_URL: 'https://agentisland.app/support',
  AGENT_ISLAND_DISPLAY_NAME: 'MAC版灵动岛--Agent运行监测',
  AGENT_ISLAND_VERSION: '0.6.1',
  AGENT_ISLAND_BUILD_NUMBER: '8',
});
assert.equal(matchingEnvironment.environmentMatches, true);
assert.equal(matchingEnvironment.ready, true);

const mismatchedEnvironment = evaluateIOSBuildSettings(settings(), {
  AGENT_ISLAND_IOS_BUNDLE_ID: 'com.other.mobile',
  AGENT_ISLAND_BUILD_NUMBER: '10',
});
assert.equal(mismatchedEnvironment.environmentMatches, false);
assert.equal(mismatchedEnvironment.ready, false);
assert.deepEqual(mismatchedEnvironment.environmentMismatches, [
  {
    environmentKey: 'AGENT_ISLAND_IOS_BUNDLE_ID',
    expected: 'com.other.mobile',
    actual: 'com.agentisland.mobile',
  },
  {
    environmentKey: 'AGENT_ISLAND_BUILD_NUMBER',
    expected: '10',
    actual: '8',
  },
]);

const wrongWidgetID = settings({
  AGENT_ISLAND_WIDGET_BUNDLE_ID: 'com.agentisland.mobile.widget',
});
const wrongWidget = evaluateIOSBuildSettings(wrongWidgetID);
assert.equal(wrongWidget.targetContractReady, false);
assert.equal(wrongWidget.ready, false);

const wrongWidgetTeam = settings();
wrongWidgetTeam[1].buildSettings.DEVELOPMENT_TEAM = 'ZYXWV98765';
const mismatchedTeams = evaluateIOSBuildSettings(wrongWidgetTeam);
assert.equal(mismatchedTeams.targetContractReady, false);
assert.equal(mismatchedTeams.ready, false);

const duplicateApp = evaluateIOSBuildSettings([...settings(), settings()[0]]);
assert.equal(duplicateApp.targetsResolved, false);
assert.equal(duplicateApp.ready, false);

const placeholder = evaluateIOSBuildSettings(settings({
  DEVELOPMENT_TEAM: '',
  AGENT_ISLAND_APP_BUNDLE_ID: 'com.example.agentisland',
  AGENT_ISLAND_WIDGET_BUNDLE_ID: 'com.example.agentisland.liveactivity',
  AGENT_ISLAND_ICLOUD_CONTAINER_ID: 'iCloud.com.example.agentisland',
  AGENT_ISLAND_PRIVACY_POLICY_URL: 'https://example.invalid/privacy',
  AGENT_ISLAND_SUPPORT_URL: 'https://example.invalid/support',
}));
assert.equal(placeholder.targetContractReady, true);
assert.equal(placeholder.productionConfigurationReady, false);
assert.equal(placeholder.ready, false);

console.log('iOS resolved build-settings tests passed');
