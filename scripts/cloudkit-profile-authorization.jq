# A provisioning profile is an Apple-signed authorization envelope, not the
# executable's final entitlement claim.  Require the exact App/Team boundary
# and the requested production CloudKit capability, while allowing Apple to
# express that capability with broader profile-only lists or wildcards.

def nonempty_string:
  type == "string" and length > 0;

def profile_application_identifier_is($identifier):
  ((has("com.apple.application-identifier") or
    has("application-identifier")))
    and ((has("com.apple.application-identifier") | not) or
      .["com.apple.application-identifier"] == $identifier)
    and ((has("application-identifier") | not) or
      .["application-identifier"] == $identifier);

def missing_or_false($key):
  (has($key) | not) or .[$key] == false;

def authorizes_container($container):
  type == "array"
    and all(.[]; nonempty_string)
    and index($container) != null;

def authorizes_service($service):
  if type == "string" then
    . == "*" or . == $service
  elif type == "array" then
    all(.[]; nonempty_string)
      and (index("*") != null or index($service) != null)
  else
    false
  end;

def authorizes_environment($environment):
  if type == "string" then
    . == $environment
  elif type == "array" then
    all(.[]; nonempty_string)
      and index($environment) != null
  else
    false
  end;

type == "object"
  and ($applicationIdentifier | nonempty_string)
  and ($team | nonempty_string)
  and ($container | nonempty_string)
  and profile_application_identifier_is($applicationIdentifier)
  and .["com.apple.developer.team-identifier"] == $team
  and missing_or_false("com.apple.security.get-task-allow")
  and missing_or_false("get-task-allow")
  and (.["com.apple.developer.icloud-container-identifiers"]
    | authorizes_container($container))
  and (.["com.apple.developer.icloud-services"]
    | authorizes_service("CloudKit"))
  and (.["com.apple.developer.icloud-container-environment"]
    | authorizes_environment("Production"))
