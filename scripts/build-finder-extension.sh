#!/bin/zsh
# Build the Finder Sync extension bundle: scripts/build-finder-extension.sh <output.appex>
set -euo pipefail

project_dir="${0:A:h:h}"
appex="$1"
sdk_args=()
if [[ -n "${SWIFT_SDK_PATH:-}" ]]; then sdk_args=(-sdk "$SWIFT_SDK_PATH"); fi

rm -rf "$appex"
mkdir -p "$appex/Contents/MacOS"
# An extension has no main(); the system entry point runs it.
swiftc "${sdk_args[@]}" -swift-version 5 -O -application-extension \
  -framework FinderSync -framework Cocoa \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$appex/Contents/MacOS/FinderExtension" \
  "$project_dir/Sources/FinderExtension/FinderSync.swift"
cp "$project_dir/Resources/FinderExtension-Info.plist" "$appex/Contents/Info.plist"
