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

  identity_output="$("${security_arguments[@]}" 2>/dev/null || true)"
  print -r -- "$identity_output" | agent_island_deduplicate_identity_output
}
