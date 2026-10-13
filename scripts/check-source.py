#!/usr/bin/env python3
"""Check project membership, pairing fixtures, and capture permission configuration."""

import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_plist(path):
    with (ROOT / path).open("rb") as source:
        return plistlib.load(source)


def main():
    spec = importlib.util.spec_from_file_location("project_generator", ROOT / "scripts/generate-project.py")
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    original_arguments = sys.argv
    try:
        sys.argv = ["generate-project.py", "--check"]
        require(generator.main() == 0, "Regenerate the Xcode project after adding or removing source files.")
    finally:
        sys.argv = original_arguments

    phone = read_plist("native/iOS/Info.plist")
    mac = read_plist("native/Mac/Info.plist")
    phone_entitlements = read_plist("native/iOS/ScrnshrPhone.entitlements")
    mac_entitlements = read_plist("native/Mac/ScrnshrMac.entitlements")
    require(phone.get("UIBackgroundModes") == ["screen-capture"], "iPhone must use only the screen-capture background mode.")
    require("NSMicrophoneUsageDescription" not in phone, "iPhone sender must not request microphone access.")
    require("NSPhotoLibraryUsageDescription" not in phone, "Screen streaming must not request photo-library access.")
    require(phone.get("NSScreenCaptureUsageDescription"), "iPhone screen capture needs a usage description.")
    require(phone.get("NSCameraUsageDescription"), "QR scanning needs a camera usage description.")
    require(phone.get("NSLocalNetworkUsageDescription"), "Direct Wi-Fi media needs a local-network usage description.")
    require(phone_entitlements.get("com.apple.developer.screen-recording") is True, "iPhone capture entitlement is missing.")
    require(mac_entitlements.get("com.apple.security.app-sandbox") is True, "Mac app must retain its sandbox.")
    for capability in ("network.client", "network.server", "device.camera", "device.audio-input"):
        require(mac_entitlements.get(f"com.apple.security.{capability}") is True, f"Mac entitlement missing: {capability}")
    require(mac.get("NSCameraUsageDescription") and mac.get("NSMicrophoneUsageDescription"), "USB sharing needs explicit Mac capture descriptions.")

    for entrypoint in ("native/iOS/ScrnshrPhoneApp.swift", "native/Mac/ScrnshrMacApp.swift"):
        require((ROOT / entrypoint).exists(), f"App entrypoint missing: {entrypoint}")
    require(generator.sources("native/Tests"), "Native XCTest source files are required.")
    require(generator.sources("native/Tests/iOS"), "iOS app-audio XCTest source files are required.")
    require(generator.sources("native/Audio"), "Custom app-audio input implementation is required.")
    for name in ("ScrnshrMac", "ScrnshrPhone"):
        document = ET.parse(ROOT / f"Scrnshr.xcodeproj/xcshareddata/xcschemes/{name}.xcscheme")
        testables = document.findall("./TestAction/Testables/TestableReference")
        require(len(testables) == 1 and testables[0].get("skipped") == "NO", f"{name} scheme must run its XCTest target.")
    resolved = json.loads((ROOT / "Scrnshr.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())
    pin = resolved["pins"][0]
    require(pin["state"] == {"revision": generator.WEBRTC_REVISION, "version": "155.0.0"}, "WebRTC must remain pinned to the validated package version.")
    print("Source membership, native schemes, package pin, and capture permission checks passed.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        print(f"Source checks failed: {error}", file=sys.stderr)
        sys.exit(1)
