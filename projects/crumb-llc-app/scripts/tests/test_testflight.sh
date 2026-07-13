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
grep -q -- '-only-testing:CrumbUITests/MissionThreadUITests' <<<"$dry_run" \
  || fail "preflight must include the persistent mission-thread journey"
grep -A1 'ui_expected_count=2' <<<"$dry_run" | grep -q 'KitCompletenessCartUITests' \
  || fail "preflight must expect both kit-completeness UI tests"

archive_run="$(BUILD_NUMBER=2026071001 ALLOW_MOCK_TESTFLIGHT=1 "$SCRIPT" --dry-run archive)"
grep -q "generic/platform=iOS" <<<"$archive_run" || fail "archive must target generic iOS"
grep -q "CURRENT_PROJECT_VERSION=2026071001" <<<"$archive_run" || fail "archive must use BUILD_NUMBER"

if BUILD_NUMBER=2026071001 SECRETS_PATH=/tmp/crumb-missing-secrets.plist \
  "$SCRIPT" --dry-run archive >/dev/null 2>&1; then
  fail "archive must reject a missing live broker configuration"
fi
BUILD_NUMBER=2026071001 SECRETS_PATH=/tmp/crumb-missing-secrets.plist ALLOW_MOCK_TESTFLIGHT=1 \
  "$SCRIPT" --dry-run archive >/dev/null

upload_run="$(BUILD_NUMBER=2026071001 "$SCRIPT" --dry-run upload)"
grep -q 'xcodebuild.*-exportArchive' <<<"$upload_run" \
  || fail "upload must support the signed-in Xcode account without API-key arguments"

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
