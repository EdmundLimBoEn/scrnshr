#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

check_phone=true
check_mac=true
case "${1:-}" in
  '') ;;
  --phone) check_mac=false ;;
  --mac) check_phone=false ;;
  *) echo "Usage: bash scripts/check-native.sh [--phone|--mac]" >&2; exit 2 ;;
esac
if [[ "$#" -gt 1 ]]; then
  echo "Usage: bash scripts/check-native.sh [--phone|--mac]" >&2
  exit 2
fi

if [[ "$(uname -s)" != Darwin ]]; then
  echo "Native compilation requires macOS and Xcode 27+. Run source checks here with python3 scripts/check-source.py." >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Install Xcode 27+ and select its Developer directory before running native checks." >&2
  exit 1
fi

python3 scripts/check-source.py
xcodebuild -version
if $check_phone; then
  device_sdk="$(xcrun --sdk iphoneos --show-sdk-version)"
  simulator_sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)"
  if [[ "${device_sdk%%.*}" -lt 27 || "${simulator_sdk%%.*}" -lt 27 ]]; then
    echo "iOS 27+ SDKs are required. Found device $device_sdk and simulator $simulator_sdk." >&2
    exit 1
  fi
fi

mkdir -p .build
package_dir="$repo_dir/.build/SourcePackages"
derived_dir="$repo_dir/.build/DerivedData"
resolve_scheme=ScrnshrMac
if ! $check_mac; then resolve_scheme=ScrnshrPhone; fi
xcodebuild -resolvePackageDependencies -project Scrnshr.xcodeproj -scheme "$resolve_scheme" \
  -clonedSourcePackagesDirPath "$package_dir" -onlyUsePackageVersionsFromResolvedFile

common=(
  -project Scrnshr.xcodeproj
  -clonedSourcePackagesDirPath "$package_dir"
  -derivedDataPath "$derived_dir"
  -disableAutomaticPackageResolution
  -onlyUsePackageVersionsFromResolvedFile
  CODE_SIGNING_ALLOWED=NO
)

for configuration in Debug Release; do
  if $check_phone; then
    echo "Building iPhone device and simulator in $configuration."
    xcodebuild -quiet "${common[@]}" -scheme ScrnshrPhone -configuration "$configuration" \
      -destination 'generic/platform=iOS' build
    xcodebuild -quiet "${common[@]}" -scheme ScrnshrPhone -configuration "$configuration" \
      -destination 'generic/platform=iOS Simulator' build
  fi
  if $check_mac; then
    echo "Building Mac in $configuration."
    xcodebuild -quiet "${common[@]}" -scheme ScrnshrMac -configuration "$configuration" \
      -destination 'generic/platform=macOS' build
  fi
done

results_dir="$(mktemp -d "$repo_dir/.build/native-test-results.XXXXXX")"
if $check_mac; then
  echo "Running Mac unit tests. Results: $results_dir/Mac.xcresult"
  xcodebuild -quiet "${common[@]}" -scheme ScrnshrMac -configuration Debug \
    -destination 'platform=macOS' -enableCodeCoverage YES \
    -resultBundlePath "$results_dir/Mac.xcresult" test
fi

if $check_phone; then
  simulator_id="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime in sorted(devices, reverse=True):
    if "iOS-27" in runtime:
        for device in devices[runtime]:
            if device["name"].startswith("iPhone") and device.get("isAvailable", False):
                print(device["udid"])
                sys.exit(0)
sys.exit("No available iOS 27 iPhone simulator. Install an iOS 27 runtime in Xcode Settings > Components.")
')"
  echo "Running iPhone app-audio tests on simulator $simulator_id."
  xcodebuild -quiet "${common[@]}" -scheme ScrnshrPhone -configuration Debug \
    -destination "platform=iOS Simulator,id=$simulator_id" -enableCodeCoverage YES \
    -resultBundlePath "$results_dir/iPhone.xcresult" test
fi
echo "Requested native builds and unit tests passed. Signing, iPhone capture, sound, and HDMI still require device checks."
