# Shared iOS entitlement contract.
#
# Required jq arguments:
#   mode       source-app | signed-app | signed-widget | profile-app | profile-widget
#   identifier Fully qualified application identifier for signed/profile modes.
#   team       Apple Developer Team ID for signed/profile modes.
#   container  CloudKit container for App modes. For source-app, pass the
#              unresolved xcconfig value used in the source plist.
#
# The source plist and executable signatures are privilege claims, so those
# modes use a closed key allowlist. A provisioning profile is an authorization
# allowlist rather than a list of privileges actually claimed by an executable;
# profile modes therefore validate required authorizations and known boundary
# violations without rejecting unrelated Apple-managed profile entries.

def nonempty_string:
  type == "string" and length > 0;

def only_keys($allowed):
  type == "object" and ((keys - $allowed) | length == 0);

def missing_or_false($key):
  ((has($key) | not) or .[$key] == false);

def missing_or_true($key):
  ((has($key) | not) or .[$key] == true);

def signed_keychain_is_default($identifier):
  ((has("keychain-access-groups") | not)
    or .["keychain-access-groups"] == [$identifier]);

def profile_keychain_authorizes_default($identifier):
  if has("keychain-access-groups") then
    .["keychain-access-groups"] as $groups
    | ($identifier | split(".")[0]) as $prefix
    | (($groups | type) == "array")
      and (($groups | length) > 0)
      and all($groups[]; type == "string" and length > 0)
      and any($groups[];
        . == $identifier or . == ($prefix + ".*"))
  else
    true
  end;

def profile_authorizes_container($container):
  . as $containers
  | ($containers | type) == "array"
    and all($containers[]; type == "string")
    and (($containers | index($container)) != null);

def profile_authorizes_service($service):
  . as $services
  | if ($services | type) == "string" then
      $services == "*" or $services == $service
    elif ($services | type) == "array" then
      all($services[]; type == "string")
        and ((($services | index("*")) != null)
          or (($services | index($service)) != null))
    else
      false
    end;

def profile_authorizes_environment($environment):
  . as $environments
  | if ($environments | type) == "string" then
      $environments == $environment
    elif ($environments | type) == "array" then
      all($environments[]; type == "string")
        and (($environments | index($environment)) != null)
    else
      false
    end;

def source_app_contract($container):
  ($container | nonempty_string)
    and type == "object"
    and keys == [
      "com.apple.developer.icloud-container-identifiers",
      "com.apple.developer.icloud-services"
    ]
    and .["com.apple.developer.icloud-container-identifiers"] == [$container]
    and .["com.apple.developer.icloud-services"] == ["CloudKit"];

def signed_baseline_contract($identifier; $team):
  ($identifier | nonempty_string)
    and ($team | nonempty_string)
    and .["application-identifier"] == $identifier
    and .["com.apple.developer.team-identifier"] == $team
    and missing_or_false("get-task-allow")
    and missing_or_true("beta-reports-active")
    and signed_keychain_is_default($identifier);

def signed_app_contract($identifier; $team; $container):
  ($container | nonempty_string)
    and only_keys([
      "application-identifier",
      "beta-reports-active",
      "com.apple.developer.icloud-container-environment",
      "com.apple.developer.icloud-container-identifiers",
      "com.apple.developer.icloud-services",
      "com.apple.developer.team-identifier",
      "get-task-allow",
      "keychain-access-groups"
    ])
    and signed_baseline_contract($identifier; $team)
    and .["com.apple.developer.icloud-container-identifiers"] == [$container]
    and .["com.apple.developer.icloud-services"] == ["CloudKit"]
    and .["com.apple.developer.icloud-container-environment"] == "Production";

def signed_widget_contract($identifier; $team):
  only_keys([
    "application-identifier",
    "beta-reports-active",
    "com.apple.developer.team-identifier",
    "get-task-allow",
    "keychain-access-groups"
  ])
    and signed_baseline_contract($identifier; $team);

def profile_baseline_contract($identifier; $team):
  type == "object"
    and ($identifier | nonempty_string)
    and ($team | nonempty_string)
    and .["application-identifier"] == $identifier
    and .["com.apple.developer.team-identifier"] == $team
    and .["get-task-allow"] == false
    and .["beta-reports-active"] == true
    and profile_keychain_authorizes_default($identifier);

def profile_app_contract($identifier; $team; $container):
  ($container | nonempty_string)
    and profile_baseline_contract($identifier; $team)
    and (.["com.apple.developer.icloud-container-identifiers"]
      | profile_authorizes_container($container))
    and (.["com.apple.developer.icloud-services"]
      | profile_authorizes_service("CloudKit"))
    and (.["com.apple.developer.icloud-container-environment"]
      | profile_authorizes_environment("Production"));

def profile_widget_contract($identifier; $team):
  profile_baseline_contract($identifier; $team)
    and ([keys[] | select(
      startswith("com.apple.developer.icloud")
        or startswith("com.apple.developer.ubiquity")
    )] | length == 0);

if $mode == "source-app" then
  source_app_contract($container)
elif $mode == "signed-app" then
  signed_app_contract($identifier; $team; $container)
elif $mode == "signed-widget" then
  signed_widget_contract($identifier; $team)
elif $mode == "profile-app" then
  profile_app_contract($identifier; $team; $container)
elif $mode == "profile-widget" then
  profile_widget_contract($identifier; $team)
else
  false
end
