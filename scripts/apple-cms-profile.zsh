#!/bin/zsh

# Provisioning profiles are CMS signed data. `security cms -D` can still exit
# successfully when signer verification did not produce a trusted signature,
# so decoding alone is not an authenticity gate. It also imports certificates
# carried by the CMS object into its selected keychain. This helper therefore
# requires an explicitly controlled keychain, checks the generated signer
# status first, and never falls back to the user's default/login keychain.
# A trusted S/MIME signature alone is not an Apple provisioning-profile
# identity. After Security.framework succeeds, the helper uses OpenSSL only to
# extract the actual signer from the same immutable CMS snapshot and binds it
# to the reviewed Apple provisioning signer leaf certificates. OpenSSL is
# never a fallback trust decision. Apple signer rotation therefore fails
# closed until the new public certificate has been reviewed and allowlisted.

agent_island_cms_keychain_path() {
  emulate -L zsh

  local keychain_path="${AGENT_ISLAND_CMS_KEYCHAIN:-}"
  [[ -n "$keychain_path" ]] \
    || keychain_path="${RELEASE_KEYCHAIN_PATH:-}"
  [[ -n "$keychain_path" ]] \
    || keychain_path="${AGENT_ISLAND_SIGNING_KEYCHAIN:-}"

  if [[ -z "$keychain_path" ]]; then
    print -u2 -- "Apple CMS verification requires AGENT_ISLAND_CMS_KEYCHAIN (or RELEASE_KEYCHAIN_PATH / AGENT_ISLAND_SIGNING_KEYCHAIN from the isolated release wrapper); refusing to use the default/login keychain"
    return 66
  fi
  if [[ "$keychain_path" != /* || ! -f "$keychain_path" || \
      -L "$keychain_path" ]]; then
    print -u2 -- "Apple CMS verification keychain must be an absolute, regular, non-symlink file"
    return 66
  fi

  local canonical_path="${keychain_path:A}"
  if [[ "${canonical_path:t}" == "login.keychain" || \
      "${canonical_path:t}" == "login.keychain-db" ]]; then
    print -u2 -- "Apple CMS verification refuses the login keychain even when it is named explicitly; use an isolated release keychain"
    return 77
  fi
  local owner_uid="$(/usr/bin/stat -f '%u' "$canonical_path" 2>/dev/null)"
  local file_mode="$(/usr/bin/stat -f '%Lp' "$canonical_path" 2>/dev/null)"
  if [[ "$owner_uid" != "$(/usr/bin/id -u)" || "$file_mode" != "600" ]]; then
    print -u2 -- "Apple CMS verification keychain must be owned by the current user and use mode 600"
    return 77
  fi

  print -r -- "$canonical_path"
}

agent_island_decode_apple_signed_profile() {
  emulate -L zsh
  setopt PIPE_FAIL

  if (( $# < 2 || $# > 3 )); then
    print -u2 -- "agent_island_decode_apple_signed_profile requires PROFILE, decoded OUTPUT, and optional verified CMS OUTPUT"
    return 64
  fi

  local profile_path="$1"
  local output_path="$2"
  local verified_profile_output="${3:-}"
  if [[ ! -f "$profile_path" || -L "$profile_path" ]]; then
    print -u2 -- "Apple CMS profile must be a regular, non-symlink file"
    return 66
  fi
  if [[ "$output_path" != /* || ! -d "${output_path:h}" || \
      -L "${output_path:h}" || -e "$output_path" || -L "$output_path" ]]; then
    print -u2 -- "Apple CMS decoded output must be a new absolute path in a regular directory"
    return 66
  fi
  if [[ -n "$verified_profile_output" && \
      ( "$verified_profile_output" != /* || \
        "$verified_profile_output" == "$output_path" || \
        ! -d "${verified_profile_output:h}" || \
        -L "${verified_profile_output:h}" || \
        -e "$verified_profile_output" || -L "$verified_profile_output" ) ]]; then
    print -u2 -- "Apple CMS verified snapshot output must be a distinct new absolute path in a regular directory"
    return 66
  fi

  local keychain_path
  keychain_path="$(agent_island_cms_keychain_path)" || return $?

  local scratch_root
  scratch_root="$(/usr/bin/mktemp -d /private/tmp/agentisland-cms.XXXXXX)" || {
    print -u2 -- "Apple CMS verification could not create private scratch space"
    return 73
  }
  /bin/chmod 700 "$scratch_root" || {
    /bin/rm -rf "$scratch_root"
    print -u2 -- "Apple CMS verification could not protect private scratch space"
    return 77
  }

  local signer_headers="$scratch_root/signer-headers.txt"
  local signer_fields="$scratch_root/signer-fields.txt"
  local signer_errors="$scratch_root/signer-errors.txt"
  local cms_snapshot="$scratch_root/profile.cms"
  local decoded_profile="$scratch_root/profile.plist"
  local decode_stdout="$scratch_root/decode-stdout.txt"
  local decode_errors="$scratch_root/decode-errors.txt"
  local signer_declaration_count declared_signer_count signer_count
  local good_signer_count signer_identity_count signer_identity
  local expected_signer_subject expected_signer_issuer
  local expected_signer_fingerprint signer_certificate signer_metadata
  local signer_pem_valid
  local signer_subject signer_issuer signer_fingerprint
  local openssl_stdout openssl_errors openssl_status
  local verify_status decode_status

  # Verify and decode one immutable private snapshot. Reading the caller path
  # twice would allow it to be replaced after verification but before decode.
  if ! /bin/cp "$profile_path" "$cms_snapshot" || \
      ! /bin/chmod 600 "$cms_snapshot"; then
    /bin/rm -rf "$scratch_root"
    print -u2 -- "Apple CMS verification could not create a protected profile snapshot"
    return 74
  fi

  if LC_ALL=C LANG=C /usr/bin/security cms -D -h 0 -n \
      -k "$keychain_path" -i "$cms_snapshot" \
      >"$signer_headers" 2>"$signer_errors"; then
    verify_status=0
  else
    verify_status=$?
  fi
  if (( verify_status != 0 )) || [[ -s "$signer_errors" ]]; then
    /bin/rm -rf "$scratch_root"
    print -u2 -- "Apple CMS verification failed closed: Security/keychain IPC, sandbox access, or CMS validation did not complete cleanly against the controlled keychain. Set AGENT_ISLAND_CMS_KEYCHAIN and retry from Terminal or another approved non-sandboxed environment."
    return 69
  fi

  # cmsutil emits semicolon-delimited fields; signer ID and status normally
  # share one physical line. Split only for exact field matching and reject
  # missing, duplicate, or additional signer declarations/status tokens.
  /usr/bin/tr ';' '\n' <"$signer_headers" \
    | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    >"$signer_fields"
  declared_signer_count="$(/usr/bin/grep -Ec '^nsigners=1$' \
    "$signer_fields" || true)"
  signer_declaration_count="$(/usr/bin/grep -Ec '^nsigners=[0-9]+$' \
    "$signer_fields" || true)"
  signer_count="$(/usr/bin/grep -Ec \
    '^signer[0-9]+[.]status=[^[:space:];]+$' "$signer_fields" || true)"
  good_signer_count="$(/usr/bin/grep -Ec \
    '^signer0[.]status=GoodSignature$' "$signer_fields" || true)"
  signer_identity_count="$(/usr/bin/grep -Ec \
    '^signer[0-9]+[.]id="[^"]+"$' "$signer_fields" || true)"
  signer_identity="$(/usr/bin/sed -n \
    's/^signer0[.]id="\([^"]*\)"$/\1/p' "$signer_fields")"
  if [[ "$signer_declaration_count" != "1" || \
      "$declared_signer_count" != "1" || "$signer_count" != "1" || \
      "$good_signer_count" != "1" || "$signer_identity_count" != "1" ]]; then
    /bin/rm -rf "$scratch_root"
    print -u2 -- "Apple CMS verification failed closed: expected exactly one signer (signer0) with GoodSignature status"
    return 65
  fi

  case "$signer_identity" in
    'Apple iPhone OS Provisioning Profile Signing')
      expected_signer_subject='C=US,O=Apple Inc.,CN=Apple iPhone OS Provisioning Profile Signing'
      expected_signer_issuer='C=US,O=Apple Inc.,OU=Certification Authority,CN=Apple iPhone Certification Authority'
      expected_signer_fingerprint='C0ABBB34427F881028F3C1A7194C9C2B0202E66FCB7D2616ACC6FF776351B0E9'
      ;;
    'Mac OS X Provisioning Profile Signing')
      expected_signer_subject='C=US,O=Apple Inc.,CN=Mac OS X Provisioning Profile Signing'
      expected_signer_issuer='C=US,O=Apple Inc.,OU=G5,CN=Apple Worldwide Developer Relations Certification Authority'
      expected_signer_fingerprint='0884FC026365E14A91CEC77583B5B4AE041BE49BC990E74F4A15E2B42B50DC55'
      ;;
    *)
      /bin/rm -rf "$scratch_root"
      print -u2 -- "Apple CMS verification failed closed: signer is not an allowlisted Apple provisioning-profile authority"
      return 65
      ;;
  esac

  signer_certificate="$scratch_root/signer.pem"
  openssl_stdout="$scratch_root/openssl.stdout"
  openssl_errors="$scratch_root/openssl.stderr"
  : >"$signer_certificate"
  /bin/chmod 600 "$signer_certificate"
  # Security.framework above is the trust gate. `-noverify` here deliberately
  # disables OpenSSL's independent CA policy so it can only extract the actual
  # sole signer certificate for the pinned-leaf comparison below; its CMS
  # content-signature verification must still succeed.
  if LC_ALL=C LANG=C /usr/bin/openssl cms -verify -noverify -binary -inform DER \
      -in "$cms_snapshot" -signer "$signer_certificate" -out /dev/null \
      >"$openssl_stdout" 2>"$openssl_errors"; then
    openssl_status=0
  else
    openssl_status=$?
  fi
  if (( openssl_status != 0 )) || [[ ! -s "$signer_certificate" ]] || \
      [[ "$(<"$openssl_errors")" != 'Verification successful' ]]; then
    /bin/rm -rf "$scratch_root"
    print -u2 -- "Apple CMS verification failed closed: could not extract the verified CMS signer certificate"
    return 65
  fi
  if /usr/bin/awk '
      BEGIN { inside = 0; seen = 0; invalid = 0 }
      /^-----BEGIN CERTIFICATE-----$/ {
        if (inside || seen) invalid = 1
        inside = 1
        seen = 1
        next
      }
      /^-----END CERTIFICATE-----$/ {
        if (!inside) invalid = 1
        inside = 0
        next
      }
      inside && /^[A-Za-z0-9+\/=]+$/ { next }
      !inside && /^[[:space:]]*$/ { next }
      { invalid = 1 }
      END { exit !(seen && !inside && !invalid) }
    ' "$signer_certificate"; then
    signer_pem_valid=true
  else
    signer_pem_valid=false
  fi
  if [[ "$signer_pem_valid" != true ]]; then
    /bin/rm -rf "$scratch_root"
    print -u2 -- "Apple CMS verification failed closed: expected exactly one canonical signer certificate"
    return 65
  fi
  signer_metadata="$(LC_ALL=C LANG=C /usr/bin/openssl x509 \
    -in "$signer_certificate" -noout -subject -issuer -fingerprint -sha256 \
    -nameopt RFC2253 2>/dev/null)" || {
      /bin/rm -rf "$scratch_root"
      print -u2 -- "Apple CMS verification failed closed: signer certificate metadata is unreadable"
      return 65
    }
  signer_subject="$(print -r -- "$signer_metadata" | /usr/bin/sed -n \
    's/^subject= //p')"
  signer_issuer="$(print -r -- "$signer_metadata" | /usr/bin/sed -n \
    's/^issuer= //p')"
  # `openssl x509 -fingerprint -sha256` hashes the certificate's DER form.
  signer_fingerprint="$(print -r -- "$signer_metadata" | /usr/bin/sed -n \
    's/^SHA256 Fingerprint=//p' | /usr/bin/tr -d ':' | \
    /usr/bin/tr '[:lower:]' '[:upper:]')"
  if [[ "$signer_subject" != "$expected_signer_subject" || \
      "$signer_issuer" != "$expected_signer_issuer" || \
      "$signer_fingerprint" != "$expected_signer_fingerprint" ]]; then
    /bin/rm -rf "$scratch_root"
    print -u2 -- "Apple CMS verification failed closed: signer certificate is not the reviewed Apple provisioning-profile signer"
    return 65
  fi

  if LC_ALL=C LANG=C /usr/bin/security cms -D -k "$keychain_path" \
      -i "$cms_snapshot" -o "$decoded_profile" \
      >"$decode_stdout" 2>"$decode_errors"; then
    decode_status=0
  else
    decode_status=$?
  fi
  if (( decode_status != 0 )) || [[ -s "$decode_errors" || ! -s "$decoded_profile" ]]; then
    /bin/rm -rf "$scratch_root"
    print -u2 -- "Apple CMS decode failed closed after signer verification: Security/keychain IPC, sandbox access, or CMS decoding did not complete cleanly. Set AGENT_ISLAND_CMS_KEYCHAIN and retry from Terminal or another approved non-sandboxed environment."
    return 69
  fi

  /bin/mv "$decoded_profile" "$output_path" || {
    /bin/rm -rf "$scratch_root"
    print -u2 -- "Apple CMS decoded profile could not be committed to its private output path"
    return 73
  }
  /bin/chmod 600 "$output_path" || {
    /bin/rm -f "$output_path"
    /bin/rm -rf "$scratch_root"
    print -u2 -- "Apple CMS decoded output could not be protected"
    return 77
  }
  if [[ -n "$verified_profile_output" ]]; then
    /bin/mv "$cms_snapshot" "$verified_profile_output" || {
      /bin/rm -f "$output_path"
      /bin/rm -rf "$scratch_root"
      print -u2 -- "Apple CMS verified snapshot could not be committed to its private output path"
      return 73
    }
    /bin/chmod 600 "$verified_profile_output" || {
      /bin/rm -f "$output_path" "$verified_profile_output"
      /bin/rm -rf "$scratch_root"
      print -u2 -- "Apple CMS verified snapshot output could not be protected"
      return 77
    }
  fi
  /bin/rm -rf "$scratch_root"
}
