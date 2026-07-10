#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(git -C "$ROOT" rev-parse --show-toplevel)"
PROJECT="$ROOT/Crumb.xcodeproj"
SCHEME="Crumb"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$BUILD_DIR/Crumb.xcarchive}"
EXPORT_OPTIONS="$ROOT/Config/ExportOptions-TestFlight.plist"
SECRETS_PATH="${SECRETS_PATH:-$ROOT/Crumb/Resources/Secrets.plist}"
SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17 Pro}"
SIMULATOR_OS="${SIMULATOR_OS:-27.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: scripts/testflight.sh [--dry-run] <preflight|archive|upload|submit>

  preflight  Regenerate and run the complete Crumb scheme on an iOS 27 simulator.
  archive    Produce and validate a signed iOS archive.
  upload     Upload the existing archive for internal TestFlight only.
  submit     Run preflight, archive, and upload in order.

Environment:
  BUILD_NUMBER       Numeric CFBundleVersion (default: UTC YYYYMMDDHHMM).
  SIMULATOR_NAME     Simulator device name (default: iPhone 17 Pro).
  SIMULATOR_OS       Simulator OS version (default: 27.0).
  DEVELOPER_DIR      Xcode developer directory (auto-selects Xcode-beta when present).
  ALLOW_DIRTY=1      Permit archiving from an app worktree with uncommitted changes.
  ALLOW_MOCK_TESTFLIGHT=1
                     Permit an intentional mock-catalog TestFlight build.
  SECRETS_PATH       Broker plist to validate (default: Crumb/Resources/Secrets.plist).
  ASC_KEY_PATH       Optional App Store Connect API private-key path.
  ASC_KEY_ID         API key ID; required with ASC_KEY_PATH.
  ASC_ISSUER_ID      API issuer ID; required with ASC_KEY_PATH.
USAGE
}

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi

ACTION="${1:-}"
case "$ACTION" in
  preflight|archive|upload|submit) ;;
  -h|--help|help|"") usage; exit 0 ;;
  *) echo "error: unknown action: $ACTION" >&2; usage >&2; exit 2 ;;
esac

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

print_command() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
}

run() {
  print_command "$@"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@"
  fi
}

require_tools() {
  [[ "$DRY_RUN" -eq 1 ]] && return
  local tool
  for tool in xcodebuild xcrun xcodegen /usr/libexec/PlistBuddy codesign; do
    if [[ "$tool" == /* ]]; then
      [[ -x "$tool" ]] || { echo "error: missing $tool" >&2; exit 1; }
    else
      command -v "$tool" >/dev/null 2>&1 || { echo "error: missing $tool" >&2; exit 1; }
    fi
  done
}

require_xcode_27() {
  [[ "$DRY_RUN" -eq 1 ]] && return
  local major
  major="$(xcodebuild -version | awk 'NR == 1 { split($2, version, "."); print version[1] }')"
  [[ "$major" =~ ^[0-9]+$ && "$major" -ge 27 ]] || {
    echo "error: Xcode 27 or newer is required; selected: $(xcodebuild -version | head -1)" >&2
    exit 1
  }
}

require_numeric_build_number() {
  [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
    echo "error: BUILD_NUMBER must contain digits only: $BUILD_NUMBER" >&2
    exit 2
  }
}

require_clean_app_tree() {
  [[ "${ALLOW_DIRTY:-0}" == "1" || "$DRY_RUN" -eq 1 ]] && return
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal -- projects/crumb-llc-app)" ]]; then
    echo "error: projects/crumb-llc-app has uncommitted changes." >&2
    echo "       Commit them first, or set ALLOW_DIRTY=1 for an intentional local archive." >&2
    exit 1
  fi
}

require_live_broker() {
  if [[ ! -f "$SECRETS_PATH" ]]; then
    if [[ "${ALLOW_MOCK_TESTFLIGHT:-0}" == "1" ]]; then
      echo "warning: archiving an intentional mock-catalog TestFlight build"
      return
    fi
    echo "error: live broker configuration not found: $SECRETS_PATH" >&2
    echo "       Create Secrets.plist, or set ALLOW_MOCK_TESTFLIGHT=1 intentionally." >&2
    exit 1
  fi

  local base_url
  base_url="$(/usr/libexec/PlistBuddy -c 'Print :CRUMB_API_BASE_URL' "$SECRETS_PATH" 2>/dev/null || true)"
  [[ "$base_url" == https://* ]] || {
    echo "error: CRUMB_API_BASE_URL must be an HTTPS URL in $SECRETS_PATH" >&2
    exit 1
  }
  echo "broker: $base_url"
}

bootstrap() {
  run "$ROOT/scripts/bootstrap.sh"
}

resolve_simulator_udid() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "RESOLVED-IOS-SIMULATOR-UDID"
    return
  fi

  local section="-- iOS $SIMULATOR_OS --"
  local udid
  udid="$(xcrun simctl list devices available | awk -v section="$section" -v name="$SIMULATOR_NAME" '
    $0 == section { in_runtime = 1; next }
    /^-- / { in_runtime = 0 }
    in_runtime && index($0, name " (") > 0 {
      if (match($0, /\([0-9A-F-]+\)/)) {
        candidate = substr($0, RSTART + 1, RLENGTH - 2)
        if (length(candidate) == 36) {
          print candidate
          exit
        }
      }
    }
  ')"
  [[ -n "$udid" ]] || {
    echo "error: no available $SIMULATOR_NAME simulator on iOS $SIMULATOR_OS" >&2
    exit 1
  }
  echo "$udid"
}

reset_simulator() {
  local udid="$1"
  printf '+ xcrun simctl shutdown %q\n' "$udid"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  fi
  run xcrun simctl boot "$udid"
  run xcrun simctl bootstatus "$udid" -b
}

cleanup_ui_runner() {
  local udid="$1"
  xcrun simctl terminate "$udid" llc.crumb.Crumb >/dev/null 2>&1 || true
  xcrun simctl terminate "$udid" com.crumbllc.CrumbUITests.xctrunner >/dev/null 2>&1 || true
}

run_ui_test() {
  local expected_count="$1"
  local udid="$2"
  shift 2

  if [[ "$DRY_RUN" -eq 1 ]]; then
    run "$@"
    return
  fi

  local log_file
  log_file="$(mktemp "${TMPDIR:-/tmp}/crumb-ui-test.XXXXXX")"
  print_command "$@"
  "$@" >"$log_file" 2>&1 &
  local pid=$!
  local deadline=$((SECONDS + 600))
  local passed_at=0
  local stop_reason=""
  local expected_summary="Executed $expected_count test"

  while kill -0 "$pid" >/dev/null 2>&1; do
    if grep -q 'Restarting after unexpected exit, crash, or test timeout' "$log_file"; then
      stop_reason="runner-crashed"
      break
    fi
    if grep -q "Test Suite 'Selected tests' failed" "$log_file"; then
      stop_reason="tests-failed"
      break
    fi
    if grep -q "$expected_summary.*with 0 failures" "$log_file"; then
      if [[ "$passed_at" -eq 0 ]]; then
        passed_at=$SECONDS
      elif (( SECONDS - passed_at >= 15 )); then
        stop_reason="passed-logger-stuck"
        break
      fi
    fi
    if (( SECONDS >= deadline )); then
      stop_reason="timeout"
      break
    fi
    sleep 1
  done

  if [[ -z "$stop_reason" ]]; then
    local status
    if wait "$pid"; then status=0; else status=$?; fi
    cat "$log_file"
    rm -f "$log_file"
    cleanup_ui_runner "$udid"
    return "$status"
  fi

  kill "$pid" >/dev/null 2>&1 || true
  sleep 2
  kill -9 "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
  cat "$log_file"
  rm -f "$log_file"
  cleanup_ui_runner "$udid"

  if [[ "$stop_reason" == "passed-logger-stuck" ]]; then
    echo "note: expected UI tests passed; terminated a stuck Xcode 27 beta log finalizer"
    return 0
  fi
  echo "error: UI test session stopped: $stop_reason" >&2
  return 1
}

preflight() {
  local udid
  udid="$(resolve_simulator_udid)"
  local destination="platform=iOS Simulator,id=$udid"
  local xcode_test=(
    xcodebuild
    -project "$PROJECT"
    -scheme "$SCHEME"
    -destination "$destination"
    -parallel-testing-enabled NO
  )
  echo "simulator: $destination"
  bootstrap
  reset_simulator "$udid"
  run "${xcode_test[@]}" build-for-testing
  run "${xcode_test[@]}" \
    -only-testing:CrumbTests \
    -only-testing:CrumbKitSimTests \
    test-without-building

  local ui_spec
  for ui_spec in \
    '1:CrumbUITests/CrumbUITests' \
    '1:CrumbUITests/JasmineTeaJourneyTests' \
    '1:CrumbUITests/KitCompletenessCartUITests' \
    '1:CrumbUITests/LacrosseGearJourneyTests' \
    '2:CrumbUITests/MissionEntryAccessibilityUITests'; do
    local expected_count="${ui_spec%%:*}"
    local ui_suite="${ui_spec#*:}"
    run_ui_test "$expected_count" "$udid" \
      "${xcode_test[@]}" "-only-testing:$ui_suite" test-without-building
  done
}

validate_archive() {
  [[ "$DRY_RUN" -eq 1 ]] && { echo "+ validate archive metadata and code signature"; return; }

  local archive_plist="$ARCHIVE_PATH/Info.plist"
  local app="$ARCHIVE_PATH/Products/Applications/Crumb.app"
  [[ -f "$archive_plist" && -d "$app" ]] || {
    echo "error: archive is incomplete: $ARCHIVE_PATH" >&2
    exit 1
  }

  local identifier version build
  identifier="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleIdentifier' "$archive_plist")"
  version="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$archive_plist")"
  build="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$archive_plist")"

  [[ "$identifier" == "llc.crumb.Crumb" ]] || { echo "error: unexpected bundle ID: $identifier" >&2; exit 1; }
  [[ "$build" == "$BUILD_NUMBER" ]] || { echo "error: archive build $build != $BUILD_NUMBER" >&2; exit 1; }
  codesign --verify --deep --strict --verbose=2 "$app"
  echo "validated: Crumb $version ($build), $identifier"
}

archive() {
  require_numeric_build_number
  require_live_broker
  require_clean_app_tree
  bootstrap
  run rm -rf "$ARCHIVE_PATH"
  run mkdir -p "$BUILD_DIR"
  run xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" \
    archive
  validate_archive
}

authentication_args=()
configure_authentication() {
  if [[ -n "${ASC_KEY_PATH:-}${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}" ]]; then
    [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]] || {
      echo "error: ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID must be supplied together" >&2
      exit 2
    }
    authentication_args=(
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID"
    )
  fi
}

upload() {
  [[ "$DRY_RUN" -eq 1 || -d "$ARCHIVE_PATH" ]] || {
    echo "error: archive not found: $ARCHIVE_PATH; run archive first" >&2
    exit 1
  }
  configure_authentication
  run rm -rf "$BUILD_DIR/Upload"
  run mkdir -p "$BUILD_DIR/Upload"
  local export_command=(xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$BUILD_DIR/Upload" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates)
  if [[ -n "${ASC_KEY_PATH:-}" ]]; then
    export_command+=("${authentication_args[@]}")
  fi
  run "${export_command[@]}"
}

require_tools
require_xcode_27

case "$ACTION" in
  preflight) preflight ;;
  archive) archive ;;
  upload) upload ;;
  submit) preflight; archive; upload ;;
esac
