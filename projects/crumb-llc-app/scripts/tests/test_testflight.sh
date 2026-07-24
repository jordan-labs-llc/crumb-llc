#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/testflight.sh"
EXPORT_OPTIONS="$ROOT/Config/ExportOptions-TestFlight.plist"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x "$SCRIPT" ]] || fail "scripts/testflight.sh must exist and be executable"
[[ -f "$EXPORT_OPTIONS" ]] || fail "TestFlight export options plist must exist"

dry_run="$(BUILD_NUMBER=2026071001 "$SCRIPT" --dry-run preflight)"
grep -q "platform=iOS Simulator" <<<"$dry_run" || fail "preflight must target an iOS simulator"
grep -q 'simctl shutdown' <<<"$dry_run" || fail "preflight must reset stale simulator state"
grep -q 'simctl bootstatus' <<<"$dry_run" || fail "preflight must wait for simulator boot"
grep -q 'xcodebuild.*build-for-testing' <<<"$dry_run" || fail "preflight must build the test bundle once"
grep -q 'xcodebuild.*test-without-building' <<<"$dry_run" \
  || fail "preflight must isolate simulator test invocations"

archive_run="$(BUILD_NUMBER=2026071001 "$SCRIPT" --dry-run archive)"
grep -q "generic/platform=iOS" <<<"$archive_run" || fail "archive must target generic iOS"
grep -q "CURRENT_PROJECT_VERSION=2026071001" <<<"$archive_run" || fail "archive must use BUILD_NUMBER"

if BUILD_NUMBER=2026071001 SECRETS_PATH=/tmp/crumb-missing-secrets.plist \
  "$SCRIPT" --dry-run archive >/dev/null 2>&1; then
  fail "archive must reject a missing live broker configuration"
fi
BUILD_NUMBER=2026071001 SECRETS_PATH=/tmp/crumb-missing-secrets.plist ALLOW_MOCK_TESTFLIGHT=1 \
  "$SCRIPT" --dry-run archive >/dev/null

upload_run="$(BUILD_NUMBER=2026071001 ASC_AUTH_FILE=/nonexistent "$SCRIPT" --dry-run upload)"
grep -q 'xcodebuild.*-exportArchive' <<<"$upload_run" \
  || fail "upload must support the signed-in Xcode account without API-key arguments"
grep -q 'authenticationKey' <<<"$upload_run" \
  && fail "upload must not inject API-key arguments when no auth is configured"

# A local auth file supplies API credentials with no per-invocation environment variables.
auth_file="$(mktemp "${TMPDIR:-/tmp}/crumb-asc-auth.XXXXXX")"
key_file="$(mktemp "${TMPDIR:-/tmp}/AuthKey_TESTKEY123.XXXXXX")"
trap 'rm -f "$auth_file" "$key_file"' EXIT
cat >"$auth_file" <<EOF
ASC_KEY_ID=TESTKEY123
ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000
ASC_KEY_PATH=$key_file
EOF

auth_run="$(BUILD_NUMBER=2026071001 ASC_AUTH_FILE="$auth_file" "$SCRIPT" --dry-run upload)"
grep -q -- '-authenticationKeyID TESTKEY123' <<<"$auth_run" \
  || fail "upload must load API key ID from the local auth file"
grep -q -- '-authenticationKeyIssuerID 00000000-0000-0000-0000-000000000000' <<<"$auth_run" \
  || fail "upload must load API issuer ID from the local auth file"
grep -q -- "-authenticationKeyPath $key_file" <<<"$auth_run" \
  || fail "upload must load API key path from the local auth file"

# Explicit environment variables win over the local auth file.
override_run="$(BUILD_NUMBER=2026071001 ASC_AUTH_FILE="$auth_file" ASC_KEY_ID=ENVKEY9999 \
  "$SCRIPT" --dry-run upload)"
grep -q -- '-authenticationKeyID ENVKEY9999' <<<"$override_run" \
  || fail "an explicit ASC_KEY_ID must override the local auth file"

if BUILD_NUMBER=not-a-number "$SCRIPT" --dry-run archive >/dev/null 2>&1; then
  fail "archive must reject a non-numeric BUILD_NUMBER"
fi

[[ "$(/usr/libexec/PlistBuddy -c 'Print :method' "$EXPORT_OPTIONS")" == "app-store-connect" ]] \
  || fail "export method must be app-store-connect"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :destination' "$EXPORT_OPTIONS")" == "upload" ]] \
  || fail "export destination must be upload"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :testFlightInternalTestingOnly' "$EXPORT_OPTIONS")" == "true" ]] \
  || fail "exports must be restricted to internal TestFlight"

grep -q 'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad:.*UIInterfaceOrientationPortraitUpsideDown' \
  "$ROOT/project.yml" || fail "iPad must declare all four orientations for store validation"

echo "PASS: TestFlight script contract"
