#!/bin/zsh

# Shared identity discovery for release scripts. `security find-identity`
# repeats a certificate when the same identity is present in more than one
# searched keychain, and can even emit the same certificate/key cross-product
# several times. A repeated SHA-1 + identity name is one cryptographic
# identity; a different SHA-1 with the same name remains deliberately
# ambiguous.
agent_island_deduplicate_identity_output() {
  /usr/bin/awk '
    /^[[:space:]]*[0-9]+\)/ {
      identity = $0
      sub(/^[^"]*"/, "", identity)
      sub(/".*$/, "", identity)
      fingerprint = toupper($2)
      key = fingerprint SUBSEP identity
      if (!seen[key]++) print
    }
  '
}

agent_island_find_identities() {
  local identity_scope="${1:-codesigning}"
  local signing_keychain="${AGENT_ISLAND_SIGNING_KEYCHAIN:-}"
  local identity_output
  local identity_error_root identity_error_path security_status
  typeset -a security_arguments

  case "$identity_scope" in
    codesigning)
      security_arguments=(/usr/bin/security find-identity -v -p codesigning)
      ;;
    all)
      security_arguments=(/usr/bin/security find-identity -v)
      ;;
    *)
      print -u2 -- "Unsupported Apple identity scope: $identity_scope"
      return 64
      ;;
  esac

  if [[ -n "$signing_keychain" ]]; then
    [[ "$signing_keychain" == /* && -f "$signing_keychain" && ! -L "$signing_keychain" ]] || {
      print -u2 -- "AGENT_ISLAND_SIGNING_KEYCHAIN must name an absolute, regular keychain file"
      return 66
    }
    security_arguments+=("${signing_keychain:A}")
  fi

  identity_error_root="$(/usr/bin/mktemp -d /private/tmp/agentisland-identities.XXXXXX)" || {
    print -u2 -- "Apple signing identity discovery could not create private diagnostic storage"
    return 73
  }
  /bin/chmod 700 "$identity_error_root" || {
    /bin/rm -rf "$identity_error_root"
    print -u2 -- "Apple signing identity discovery could not protect private diagnostic storage"
    return 77
  }
  identity_error_path="$identity_error_root/security.stderr"

  if identity_output="$("${security_arguments[@]}" 2>"$identity_error_path")"; then
    security_status=0
  else
    security_status=$?
  fi
  if (( security_status != 0 )) || [[ -s "$identity_error_path" ]]; then
    [[ -s "$identity_error_path" ]] && /bin/cat "$identity_error_path" >&2
    /bin/rm -rf "$identity_error_root"
    print -u2 -- "Apple signing identity discovery failed; Security/keychain access did not complete cleanly. Retry from Terminal or another approved non-sandboxed environment."
    (( security_status != 0 )) && return "$security_status"
    return 69
  fi
  /bin/rm -rf "$identity_error_root"
  print -r -- "$identity_output" | agent_island_deduplicate_identity_output
}
