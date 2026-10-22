#!/bin/zsh
# Build the windowless Finder agent app: scripts/build-finder-agent.sh <output.app>
set -euo pipefail

project_dir="${0:A:h:h}"
agent="$1"
sdk_args=()
if [[ -n "${SWIFT_SDK_PATH:-}" ]]; then sdk_args=(-sdk "$SWIFT_SDK_PATH"); fi

rm -rf "$agent"
mkdir -p "$agent/Contents/MacOS"
swiftc "${sdk_args[@]}" -swift-version 5 -O -framework AppKit \
  -o "$agent/Contents/MacOS/FinderAgent" \
  "$project_dir/Sources/FinderAgent/main.swift" \
  "$project_dir/Sources/MacInterfaceController/FinderActions.swift"
cp "$project_dir/Resources/FinderAgent-Info.plist" "$agent/Contents/Info.plist"
