def app_contract:
  .NSPrivacyTracking == false
  and .NSPrivacyTrackingDomains == []
  and (.NSPrivacyAccessedAPITypes | length == 1)
  and any(
    .NSPrivacyAccessedAPITypes[];
    .NSPrivacyAccessedAPIType == "NSPrivacyAccessedAPICategoryUserDefaults"
    and .NSPrivacyAccessedAPITypeReasons == ["CA92.1"]
  )
  and (.NSPrivacyCollectedDataTypes | length == 2)
  and ([.NSPrivacyCollectedDataTypes[].NSPrivacyCollectedDataType] | sort)
    == [
      "NSPrivacyCollectedDataTypeOtherUsageData",
      "NSPrivacyCollectedDataTypeOtherUserContent"
    ]
  and all(
    .NSPrivacyCollectedDataTypes[];
    .NSPrivacyCollectedDataTypeLinked == true
    and .NSPrivacyCollectedDataTypeTracking == false
    and .NSPrivacyCollectedDataTypePurposes
      == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
  );

def widget_contract:
  .NSPrivacyTracking == false
  and .NSPrivacyTrackingDomains == []
  and .NSPrivacyCollectedDataTypes == []
  and .NSPrivacyAccessedAPITypes == [];

if $target == "app" then
  app_contract
elif $target == "widget" then
  widget_contract
else
  error("unknown privacy-manifest target: \($target)")
end
