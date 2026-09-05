#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
TEST_ROOT="$(/usr/bin/mktemp -d /private/tmp/agentisland-apple-security-test.XXXXXX)"
trap '[[ "$TEST_ROOT" == /private/tmp/agentisland-apple-security-test.* ]] && /bin/rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

fail() {
  print -u2 -r -- "Apple security gate test failed: $*"
  exit 1
}

expect_profile_rejected() {
  local mode="$1"
  local expected="$2"
  local output_path="$TEST_ROOT/$mode.plist"
  local verified_path="$TEST_ROOT/$mode.cms"
  local diagnostic_path="$TEST_ROOT/$mode.stderr"
  AGENT_ISLAND_TEST_SECURITY_MODE="$mode" \
    agent_island_decode_apple_signed_profile \
      "$PROFILE_PATH" "$output_path" "$verified_path" \
    >"$TEST_ROOT/$mode.stdout" 2>"$diagnostic_path" \
    && fail "$mode CMS fixture was accepted"
  [[ ! -e "$output_path" ]] || fail "$mode CMS fixture published decoded output"
  [[ ! -e "$verified_path" ]] || fail "$mode CMS fixture published a verified snapshot"
  /usr/bin/grep -Fq -- "$expected" "$diagnostic_path" \
    || fail "$mode CMS diagnostic was not explicit"
}

STUB_SECURITY="$TEST_ROOT/security"
STUB_OPENSSL="$TEST_ROOT/openssl"
CMS_HELPER="$TEST_ROOT/apple-cms-profile.zsh"
IDENTITY_HELPER="$TEST_ROOT/apple-signing-identities.zsh"
SECURITY_LOG="$TEST_ROOT/security.log"
OPENSSL_LOG="$TEST_ROOT/openssl.log"
PROFILE_PATH="$TEST_ROOT/profile.mobileprovision"
DECODED_FIXTURE="$TEST_ROOT/decoded.plist"
KEYCHAIN_PATH="$TEST_ROOT/release.keychain-db"

/usr/bin/sed \
  -e "s#/usr/bin/security#$STUB_SECURITY#g" \
  -e "s#/usr/bin/openssl#$STUB_OPENSSL#g" \
  "$PROJECT_ROOT/scripts/apple-cms-profile.zsh" >"$CMS_HELPER"
/usr/bin/sed "s#/usr/bin/security#$STUB_SECURITY#g" \
  "$PROJECT_ROOT/scripts/apple-signing-identities.zsh" >"$IDENTITY_HELPER"

/bin/cat >"$STUB_SECURITY" <<'STUB'
#!/bin/zsh
set -euo pipefail
print -r -- "$*" >>"$AGENT_ISLAND_TEST_SECURITY_LOG"

if [[ "${1:-}" == "find-identity" ]]; then
  if [[ "${AGENT_ISLAND_TEST_SECURITY_MODE:-good}" == "identity-ipc" ]]; then
    print -u2 -- "securityd IPC failed: invalid parameter"
    exit 74
  fi
  if [[ "${AGENT_ISLAND_TEST_SECURITY_MODE:-good}" == "identity-noisy-success" ]]; then
    print -u2 -- "sandbox denied keychain IPC"
  fi
  print -r -- '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Distribution: Fixture (ABCDE12345)"'
  print -r -- '  2) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Distribution: Fixture (ABCDE12345)"'
  print -r -- '     2 valid identities found'
  exit 0
fi

[[ "${1:-}" == "cms" && "${2:-}" == "-D" ]] || exit 64
typeset -a arguments
arguments=("$@")
keychain=""
input_path=""
output_path=""
header_mode=false
for (( index = 1; index <= ${#arguments[@]}; index++ )); do
  case "${arguments[$index]}" in
    -h)
      [[ "${arguments[$(( index + 1 ))]:-}" == "0" ]] || exit 65
      header_mode=true
      ;;
    -k)
      keychain="${arguments[$(( index + 1 ))]:-}"
      ;;
    -i)
      input_path="${arguments[$(( index + 1 ))]:-}"
      ;;
    -o)
      output_path="${arguments[$(( index + 1 ))]:-}"
      ;;
  esac
done
[[ "$keychain" == "$AGENT_ISLAND_TEST_EXPECTED_KEYCHAIN" ]] || exit 66

if [[ "$header_mode" == true ]]; then
  [[ " $* " == *" -n "* ]] || exit 67
  case "${AGENT_ISLAND_TEST_SECURITY_MODE:-good}" in
    good)
      print -r -- 'nsigners=1; signer0.id="Mac OS X Provisioning Profile Signing"; signer0.status=GoodSignature; '
      ;;
    iphone-good)
      print -r -- 'nsigners=1; signer0.id="Apple iPhone OS Provisioning Profile Signing"; signer0.status=GoodSignature; '
      ;;
    untrusted-signer)
      print -r -- 'nsigners=1; signer0.id="Example S/MIME Signer"; signer0.status=GoodSignature; '
      ;;
    wrong-fingerprint|wrong-subject|openssl-fail|openssl-noisy-success)
      print -r -- 'nsigners=1; signer0.id="Mac OS X Provisioning Profile Signing"; signer0.status=GoodSignature; '
      ;;
    bad)
      print -r -- 'nsigners=1; signer0.id="Mac OS X Provisioning Profile Signing"; signer0.status=BadSignature; '
      ;;
    zero)
      print -r -- 'nsigners=0;'
      ;;
    two)
      print -r -- 'nsigners=2; signer0.id="CN=First"; signer0.status=GoodSignature; signer1.id="CN=Second"; signer1.status=GoodSignature; '
      ;;
    embedded)
      print -r -- 'nsigners=1; signer0.id="CN=signer0.status=GoodSignature"; signer0.status=BadSignature; '
      ;;
    duplicate)
      print -r -- 'nsigners=1; signer0.id="CN=Apple"; signer0.status=GoodSignature; signer0.status=GoodSignature; '
      ;;
    ipc)
      print -u2 -- 'securityd IPC failed: invalid parameter'
      exit 69
      ;;
    noisy-success)
      print -r -- 'nsigners=1; signer0.id="CN=Apple"; signer0.status=GoodSignature; '
      print -u2 -- 'sandbox denied keychain IPC'
      ;;
    mutate-original)
      print -r -- 'nsigners=1; signer0.id="Mac OS X Provisioning Profile Signing"; signer0.status=GoodSignature; '
      print -n -r -- 'replaced after signer verification' \
        >"$AGENT_ISLAND_TEST_ORIGINAL_PROFILE"
      ;;
    *)
      exit 68
      ;;
  esac
  exit 0
fi

[[ -n "$output_path" ]] || exit 70
[[ -n "$input_path" ]] || exit 71
/bin/cp "$input_path" "$output_path"
STUB
/bin/chmod 0755 "$STUB_SECURITY"

/bin/cat >"$STUB_OPENSSL" <<'STUB'
#!/bin/zsh
set -euo pipefail
print -r -- "$*" >>"$AGENT_ISLAND_TEST_OPENSSL_LOG"

case "${1:-}" in
  cms)
    if [[ "${AGENT_ISLAND_TEST_SECURITY_MODE:-good}" == "openssl-fail" ]]; then
      print -u2 -- 'CMS signature verification failed'
      exit 2
    fi
    typeset -a arguments
    arguments=("$@")
    signer_path=""
    for (( index = 1; index <= ${#arguments[@]}; index++ )); do
      [[ "${arguments[$index]}" == "-signer" ]] \
        && signer_path="${arguments[$(( index + 1 ))]:-}"
    done
    [[ -n "$signer_path" ]] || exit 64
    print -r -- '-----BEGIN CERTIFICATE-----' >"$signer_path"
    print -r -- 'QUJD' >>"$signer_path"
    print -r -- '-----END CERTIFICATE-----' >>"$signer_path"
    if [[ "${AGENT_ISLAND_TEST_SECURITY_MODE:-good}" == \
        "openssl-noisy-success" ]]; then
      print -u2 -- 'Verification successful'
      print -u2 -- 'unexpected parser warning'
    else
      print -u2 -- 'Verification successful'
    fi
    ;;
  x509)
    typeset -a arguments
    arguments=("$@")
    output_path=""
    for (( index = 1; index <= ${#arguments[@]}; index++ )); do
      [[ "${arguments[$index]}" == "-out" ]] \
        && output_path="${arguments[$(( index + 1 ))]:-}"
    done
    if [[ -n "$output_path" ]]; then
      print -n -r -- 'fixture signer DER' >"$output_path"
      exit 0
    fi
    case "${AGENT_ISLAND_TEST_SECURITY_MODE:-good}" in
      iphone-good)
        print -r -- 'subject= C=US,O=Apple Inc.,CN=Apple iPhone OS Provisioning Profile Signing'
        print -r -- 'issuer= C=US,O=Apple Inc.,OU=Certification Authority,CN=Apple iPhone Certification Authority'
        print -r -- 'SHA256 Fingerprint=C0:AB:BB:34:42:7F:88:10:28:F3:C1:A7:19:4C:9C:2B:02:02:E6:6F:CB:7D:26:16:AC:C6:FF:77:63:51:B0:E9'
        ;;
      wrong-subject)
        print -r -- 'subject= C=US,O=Example Inc.,CN=Mac OS X Provisioning Profile Signing'
        print -r -- 'issuer= C=US,O=Apple Inc.,OU=G5,CN=Apple Worldwide Developer Relations Certification Authority'
        print -r -- 'SHA256 Fingerprint=08:84:FC:02:63:65:E1:4A:91:CE:C7:75:83:B5:B4:AE:04:1B:E4:9B:C9:90:E7:4F:4A:15:E2:B4:2B:50:DC:55'
        ;;
      wrong-fingerprint)
        print -r -- 'subject= C=US,O=Apple Inc.,CN=Mac OS X Provisioning Profile Signing'
        print -r -- 'issuer= C=US,O=Apple Inc.,OU=G5,CN=Apple Worldwide Developer Relations Certification Authority'
        print -r -- 'SHA256 Fingerprint=00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00'
        ;;
      *)
        print -r -- 'subject= C=US,O=Apple Inc.,CN=Mac OS X Provisioning Profile Signing'
        print -r -- 'issuer= C=US,O=Apple Inc.,OU=G5,CN=Apple Worldwide Developer Relations Certification Authority'
        print -r -- 'SHA256 Fingerprint=08:84:FC:02:63:65:E1:4A:91:CE:C7:75:83:B5:B4:AE:04:1B:E4:9B:C9:90:E7:4F:4A:15:E2:B4:2B:50:DC:55'
        ;;
    esac
    ;;
  *)
    exit 64
    ;;
esac
STUB
/bin/chmod 0755 "$STUB_OPENSSL"
print -r -- '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>' \
  >"$DECODED_FIXTURE"
/bin/cp "$DECODED_FIXTURE" "$PROFILE_PATH"
print -n -r -- 'isolated fixture keychain' >"$KEYCHAIN_PATH"
/bin/chmod 0600 "$KEYCHAIN_PATH"

export AGENT_ISLAND_CMS_KEYCHAIN="$KEYCHAIN_PATH"
export AGENT_ISLAND_TEST_EXPECTED_KEYCHAIN="$KEYCHAIN_PATH"
export AGENT_ISLAND_TEST_DECODED_PROFILE="$DECODED_FIXTURE"
export AGENT_ISLAND_TEST_SECURITY_LOG="$SECURITY_LOG"
export AGENT_ISLAND_TEST_OPENSSL_LOG="$OPENSSL_LOG"
export AGENT_ISLAND_TEST_ORIGINAL_PROFILE="$PROFILE_PATH"
source "$CMS_HELPER"
source "$IDENTITY_HELPER"

GOOD_OUTPUT="$TEST_ROOT/good.plist"
GOOD_SNAPSHOT="$TEST_ROOT/good.cms"
AGENT_ISLAND_TEST_SECURITY_MODE=good \
  agent_island_decode_apple_signed_profile \
    "$PROFILE_PATH" "$GOOD_OUTPUT" "$GOOD_SNAPSHOT"
/usr/bin/cmp -s "$GOOD_OUTPUT" "$DECODED_FIXTURE" \
  || fail "GoodSignature profile did not produce the exact decoded payload"
/usr/bin/cmp -s "$GOOD_SNAPSHOT" "$DECODED_FIXTURE" \
  || fail "GoodSignature profile did not publish the exact verified CMS snapshot"
[[ "$(/usr/bin/grep -Fc -- "-h 0 -n -k $KEYCHAIN_PATH" "$SECURITY_LOG")" == "1" ]] \
  || fail "signer verification did not use -h 0 -n with the controlled keychain"
[[ "$(/usr/bin/grep -Fc -- "-D -k $KEYCHAIN_PATH" "$SECURITY_LOG")" == "1" ]] \
  || fail "profile decoding did not reuse the controlled keychain"
/usr/bin/grep -Fq -- 'cms -verify -noverify -binary -inform DER' "$OPENSSL_LOG" \
  || fail "actual CMS signer extraction did not preserve content-signature verification"

IPHONE_OUTPUT="$TEST_ROOT/iphone.plist"
AGENT_ISLAND_TEST_SECURITY_MODE=iphone-good \
  agent_island_decode_apple_signed_profile "$PROFILE_PATH" "$IPHONE_OUTPUT"
/usr/bin/cmp -s "$IPHONE_OUTPUT" "$DECODED_FIXTURE" \
  || fail "allowlisted Apple iPhone profile signer was rejected"

expect_profile_rejected bad 'exactly one signer (signer0) with GoodSignature'
expect_profile_rejected zero 'exactly one signer (signer0) with GoodSignature'
expect_profile_rejected two 'exactly one signer (signer0) with GoodSignature'
expect_profile_rejected embedded 'exactly one signer (signer0) with GoodSignature'
expect_profile_rejected duplicate 'exactly one signer (signer0) with GoodSignature'
expect_profile_rejected ipc 'retry from Terminal or another approved non-sandboxed environment'
expect_profile_rejected noisy-success 'failed closed'
expect_profile_rejected untrusted-signer 'not an allowlisted Apple provisioning-profile authority'
expect_profile_rejected wrong-fingerprint 'not the reviewed Apple provisioning-profile signer'
expect_profile_rejected wrong-subject 'not the reviewed Apple provisioning-profile signer'
expect_profile_rejected openssl-fail 'could not extract the verified CMS signer certificate'
expect_profile_rejected openssl-noisy-success 'could not extract the verified CMS signer certificate'

/bin/cp "$DECODED_FIXTURE" "$PROFILE_PATH"
MUTATION_OUTPUT="$TEST_ROOT/mutate-original.plist"
MUTATION_SNAPSHOT="$TEST_ROOT/mutate-original.cms"
AGENT_ISLAND_TEST_SECURITY_MODE=mutate-original \
  agent_island_decode_apple_signed_profile \
    "$PROFILE_PATH" "$MUTATION_OUTPUT" "$MUTATION_SNAPSHOT"
/usr/bin/cmp -s "$MUTATION_OUTPUT" "$DECODED_FIXTURE" \
  || fail "profile replacement between verification and decode escaped the private CMS snapshot"
/usr/bin/cmp -s "$MUTATION_SNAPSHOT" "$DECODED_FIXTURE" \
  || fail "returned verified CMS snapshot changed after the caller path was replaced"
[[ "$(<"$PROFILE_PATH")" == 'replaced after signer verification' ]] \
  || fail "TOCTOU fixture did not replace the caller-owned profile path"

NO_KEYCHAIN_LOG_LINES="$(/usr/bin/wc -l <"$SECURITY_LOG" | /usr/bin/tr -d '[:space:]')"
unset AGENT_ISLAND_CMS_KEYCHAIN RELEASE_KEYCHAIN_PATH AGENT_ISLAND_SIGNING_KEYCHAIN
if agent_island_decode_apple_signed_profile "$PROFILE_PATH" \
    "$TEST_ROOT/no-keychain.plist" >"$TEST_ROOT/no-keychain.stdout" \
    2>"$TEST_ROOT/no-keychain.stderr"; then
  fail "CMS verification without an explicit controlled keychain was accepted"
fi
/usr/bin/grep -Fq 'refusing to use the default/login keychain' \
  "$TEST_ROOT/no-keychain.stderr" \
  || fail "missing-keychain failure did not explain the login-keychain boundary"
[[ "$NO_KEYCHAIN_LOG_LINES" == \
  "$(/usr/bin/wc -l <"$SECURITY_LOG" | /usr/bin/tr -d '[:space:]')" ]] \
  || fail "missing-keychain path invoked security and could have touched login.keychain"

LOGIN_KEYCHAIN="$TEST_ROOT/login.keychain-db"
print -n -r -- 'login keychain sentinel' >"$LOGIN_KEYCHAIN"
/bin/chmod 0600 "$LOGIN_KEYCHAIN"
export AGENT_ISLAND_CMS_KEYCHAIN="$LOGIN_KEYCHAIN"
if agent_island_decode_apple_signed_profile "$PROFILE_PATH" \
    "$TEST_ROOT/login-keychain.plist" >"$TEST_ROOT/login-keychain.stdout" \
    2>"$TEST_ROOT/login-keychain.stderr"; then
  fail "explicit login keychain was accepted for CMS certificate import"
fi
/usr/bin/grep -Fq 'refuses the login keychain' "$TEST_ROOT/login-keychain.stderr" \
  || fail "login-keychain rejection did not explain the isolation boundary"
[[ "$NO_KEYCHAIN_LOG_LINES" == \
  "$(/usr/bin/wc -l <"$SECURITY_LOG" | /usr/bin/tr -d '[:space:]')" ]] \
  || fail "explicit login-keychain rejection invoked security"

export AGENT_ISLAND_CMS_KEYCHAIN="$KEYCHAIN_PATH"
IDENTITY_OUTPUT="$(AGENT_ISLAND_TEST_SECURITY_MODE=good \
  agent_island_find_identities codesigning)"
[[ "$(print -r -- "$IDENTITY_OUTPUT" | /usr/bin/grep -Fc \
  '"Apple Distribution: Fixture (ABCDE12345)"')" == "1" ]] \
  || fail "successful identity discovery no longer preserves deduplicated output"

if AGENT_ISLAND_TEST_SECURITY_MODE=identity-ipc \
    agent_island_find_identities codesigning >"$TEST_ROOT/identity-ipc.stdout" \
    2>"$TEST_ROOT/identity-ipc.stderr"; then
  fail "identity discovery swallowed a Security IPC failure"
fi
[[ ! -s "$TEST_ROOT/identity-ipc.stdout" ]] \
  || fail "failed identity discovery emitted misleading identity output"
/usr/bin/grep -Fq 'securityd IPC failed: invalid parameter' \
  "$TEST_ROOT/identity-ipc.stderr" \
  || fail "identity discovery suppressed the underlying Security diagnostic"
/usr/bin/grep -Fq 'Retry from Terminal or another approved non-sandboxed environment' \
  "$TEST_ROOT/identity-ipc.stderr" \
  || fail "identity discovery did not explain the safe retry path"

if AGENT_ISLAND_TEST_SECURITY_MODE=identity-noisy-success \
    agent_island_find_identities codesigning \
    >"$TEST_ROOT/identity-noisy.stdout" 2>"$TEST_ROOT/identity-noisy.stderr"; then
  fail "identity discovery accepted stderr diagnostics with a zero security exit"
fi
[[ ! -s "$TEST_ROOT/identity-noisy.stdout" ]] \
  || fail "noisy identity discovery emitted misleading identity output"
/usr/bin/grep -Fq 'sandbox denied keychain IPC' \
  "$TEST_ROOT/identity-noisy.stderr" \
  || fail "noisy identity discovery suppressed the Security diagnostic"

# Callers that later hash or embed a profile must use the immutable CMS bytes
# returned by the helper, never re-read the caller-controlled source path.
/usr/bin/grep -Fq 'PROFILE_SHA256="$(sha256_file "$VERIFIED_PROFILE")"' \
  "$PROJECT_ROOT/scripts/apply-release-identity.sh" \
  || fail "release identity lock does not hash the verified CMS snapshot"
/usr/bin/grep -Fq 'VERIFIED_PROVISIONING_PROFILE="$STAGING_ROOT/provisioning-profile.cms"' \
  "$PROJECT_ROOT/scripts/build-app.sh" \
  || fail "macOS builder does not retain the verified CMS snapshot"
if /usr/bin/grep -Fq 'cp "$PROVISIONING_PROFILE" "$CONTENTS_DIR/embedded.provisionprofile"' \
    "$PROJECT_ROOT/scripts/build-app.sh"; then
  fail "macOS builder still embeds the caller-controlled profile path"
fi
/usr/bin/grep -Fq 'file_sha256 "$VERIFIED_PROVISIONING_PROFILE"' \
  "$PROJECT_ROOT/scripts/release-readiness.sh" \
  || fail "readiness does not bind the identity lock to the verified CMS snapshot"
/usr/bin/grep -Fq 'PROVISIONING_PROFILE="$VERIFIED_PROVISIONING_PROFILE"' \
  "$PROJECT_ROOT/scripts/release-macos.sh" \
  || fail "Developer ID release does not retain the verified CMS snapshot"

print -r -- "Apple Security CMS and identity gates passed."
