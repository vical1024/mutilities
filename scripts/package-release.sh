#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
release_tag="${1:-v$version}"
if [[ ! "$release_tag" =~ '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ]]; then
  print -u2 'Release tags must use vMAJOR.MINOR.PATCH (for example v0.7.2).'
  exit 1
fi
if [[ "$release_tag" != "v$version" ]]; then
  print -u2 "Tag $release_tag does not match Resources/Info.plist version $version."
  exit 1
fi

architecture="$(uname -m)"
case "$architecture" in
  arm64|x86_64) ;;
  *) print -u2 "Unsupported build architecture: $architecture"; exit 1 ;;
esac

release_dir="${PACKAGE_OUTPUT_DIR:-$project_dir/dist/releases}"
mkdir -p "$release_dir"
work_dir="$(mktemp -d "$release_dir/.package.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

# Package a fresh bundle without replacing the app being used locally.
BUILD_OUTPUT_DIR="$work_dir" ./scripts/build-app.sh release
app_dir="$work_dir/Mac Interface Controller.app"
for executable in MacInterfaceController FunctionKeyRestore DisplayGuard; do
  lipo "$app_dir/Contents/MacOS/$executable" -verify_arch "$architecture"
done
codesign --verify --deep --strict "$app_dir"
plutil -lint "$app_dir/Contents/Info.plist"

archive="Mac-Interface-Controller-$release_tag-macos-$architecture.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$work_dir/$archive"

# Verify the distributed ZIP, including executable permissions and signatures.
ditto -x -k "$work_dir/$archive" "$work_dir/unpacked"
codesign --verify --deep --strict "$work_dir/unpacked/Mac Interface Controller.app"
for executable in MacInterfaceController FunctionKeyRestore DisplayGuard; do
  test -x "$work_dir/unpacked/Mac Interface Controller.app/Contents/MacOS/$executable"
done
(
  cd "$work_dir"
  shasum -a 256 "$archive" > "$archive.sha256"
  shasum -a 256 -c "$archive.sha256"
)
mv "$work_dir/$archive" "$work_dir/$archive.sha256" "$release_dir/"
print "$release_dir/$archive"
