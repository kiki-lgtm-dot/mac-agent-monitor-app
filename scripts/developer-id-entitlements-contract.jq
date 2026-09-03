type == "object" and
(keys | sort) == [
  "com.apple.application-identifier",
  "com.apple.developer.icloud-container-environment",
  "com.apple.developer.icloud-container-identifiers",
  "com.apple.developer.icloud-services",
  "com.apple.developer.team-identifier"
] and
."com.apple.application-identifier" == $applicationIdentifier and
."com.apple.developer.team-identifier" == $team and
."com.apple.developer.icloud-container-identifiers" == [$container] and
."com.apple.developer.icloud-container-environment" == "Production" and
."com.apple.developer.icloud-services" == ["CloudKit"]
