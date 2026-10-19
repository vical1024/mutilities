#!/bin/zsh
# Builds Helper/SwapHelper against the header-only C++ client of Karabiner-DriverKit-VirtualHIDDevice.
# The client headers must match the installed driver's client_protocol_version (v8.6.0 -> 7).
set -euo pipefail

project_dir="${0:A:h:h}"
output="${1:?usage: build-swap-helper.sh OUTPUT}"
driver_tag="v8.6.0"
driver_dir="$project_dir/.build/Karabiner-DriverKit-VirtualHIDDevice-$driver_tag"

if [[ ! -d "$driver_dir/include" ]]; then
  rm -rf "$driver_dir"
  git clone --quiet --depth 1 --branch "$driver_tag" \
    https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice.git "$driver_dir"
fi

sdk_args=()
if [[ -n "${SWIFT_SDK_PATH:-}" ]]; then
  sdk_args=(-isysroot "$SWIFT_SDK_PATH")
fi
clang++ -std=c++23 -O2 -Wall "${sdk_args[@]}" \
  -I "$driver_dir/vendor/vendor/include" -I "$driver_dir/include" \
  "$project_dir/Helper/SwapHelper/main.cpp" -framework IOKit -framework CoreFoundation -o "$output"
