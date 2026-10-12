#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
output_dir="${BUILD_OUTPUT_DIR:-$project_dir/dist}"
app_dir="$output_dir/Mac Interface Controller.app"

cd "$project_dir"
swift_build_args=(-c "$configuration")
if [[ -n "${SWIFT_SDK_PATH:-}" ]]; then
  swift_build_args+=(--sdk "$SWIFT_SDK_PATH")
fi
swift build "${swift_build_args[@]}"
binary_dir="$(swift build "${swift_build_args[@]}" --show-bin-path)"
mkdir -p "$output_dir"
staging_dir="$(mktemp -d "$output_dir/.build-app.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/Mac Interface Controller.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$binary_dir/MacInterfaceController" "$staged_app/Contents/MacOS/MacInterfaceController"
cp "$binary_dir/FunctionKeyRestore" "$staged_app/Contents/MacOS/FunctionKeyRestore"
cp "$binary_dir/DisplayGuard" "$staged_app/Contents/MacOS/DisplayGuard"
cp "$project_dir/Resources/Info.plist" "$staged_app/Contents/Info.plist"
signing_identity="${CODE_SIGN_IDENTITY:--}"
codesign --force --sign "$signing_identity" "$staged_app/Contents/MacOS/FunctionKeyRestore"
codesign --force --sign "$signing_identity" "$staged_app/Contents/MacOS/DisplayGuard"
if [[ "$signing_identity" == "-" ]]; then
  codesign --force --sign - \
    --requirements '=designated => identifier "dev.local.MacInterfaceController"' \
    "$staged_app"
else
  codesign --force --sign "$signing_identity" "$staged_app"
fi
codesign --verify --deep --strict "$staged_app"
# Move the old inode out of the way instead of truncating a running executable.
previous_app="$staging_dir/previous.app"
if [[ -e "$app_dir" ]]; then mv "$app_dir" "$previous_app"; fi
if ! mv "$staged_app" "$app_dir"; then
  if [[ -e "$previous_app" ]]; then mv "$previous_app" "$app_dir"; fi
  exit 1
fi
echo "$app_dir"
