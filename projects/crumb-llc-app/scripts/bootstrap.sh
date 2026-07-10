#!/usr/bin/env bash
# Regenerate Crumb.xcodeproj from project.yml.
#
# The .xcodeproj is a build artifact: it is gitignored and must never be hand-edited or
# committed. Any change to build settings, targets, schemes, or the source tree belongs in
# project.yml (structure) or Config/*.xcconfig (signing, versioning, per-config flags).
#
# Run this after: a fresh clone, adding/renaming/deleting any source file, or editing
# project.yml. Xcode will not notice new files on its own.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found." >&2
  echo "       brew install xcodegen" >&2
  exit 1
fi

# The app deploys to iOS 27 (see project.yml). The default toolchain may still be 26.x,
# which cannot compile the FoundationModels dynamic-session API that CrumbKit links.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  echo "note: DEVELOPER_DIR -> $DEVELOPER_DIR"
fi

if command -v xcodebuild >/dev/null 2>&1; then
  echo "note: $(xcodebuild -version | head -1)"
fi

echo "==> xcodegen generate"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"

# Sanity-check that the generated project picked up the xcconfig layer. If configFiles
# stopped being wired, signing silently reverts to whatever project.yml inlines, and the
# failure only surfaces at archive time.
PBX="$ROOT/Crumb.xcodeproj/project.pbxproj"
if ! grep -q "baseConfigurationReference" "$PBX"; then
  echo "error: generated project has no baseConfigurationReference." >&2
  echo "       Config/*.xcconfig is not wired up; check 'configFiles:' in project.yml." >&2
  exit 1
fi

if grep -qE "^[[:space:]]*CODE_SIGNING_ALLOWED = NO;" "$PBX"; then
  echo "error: signing is disabled in the generated project; archives will not be" >&2
  echo "       distributable. Remove CODE_SIGNING_ALLOWED from project.yml." >&2
  exit 1
fi

echo "==> ok: Crumb.xcodeproj regenerated"
echo "    open Crumb.xcodeproj"
