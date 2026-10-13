<img src="assets/icon.svg" width="64" height="64" alt="">

# scrnshr

Native iPhone screen and app-audio sharing to a Mac presentation window. Use the physical phone for input and fullscreen the receiver on an HDMI display.

The iOS 27 sender uses ScreenCaptureKit and a native WebRTC app-audio adapter. The Mac receives with Metal rendering, keeps controls in a separate window, and supports sticky blackout/mute. Internet sessions use a small Cloudflare signaling Worker with authenticated pairing and expiring TURN credentials. A direct LAN mode works without cloud deployment; USB capture is experimental.

Open `Scrnshr.xcodeproj` in Xcode 27.1 or newer and select your Apple signing team. Both apps pin WebRTC 155.0.0. Follow [the device testing guide](docs/testing.md) to validate capture and HDMI before deploying signaling.

```sh
# Linux or Mac: verify project source membership and privacy configuration.
python3 scripts/check-source.py

# Mac: build both apps for device/simulator/Mac and run native tests.
bash scripts/check-native.sh

# Linux or Mac: test and build Cloudflare signaling locally.
cd signaling
bun install --frozen-lockfile
bun run check
```

CI builds Debug and Release apps and runs Mac and iOS Simulator XCTest plus signaling integration tests in the real Cloudflare runtime. Deployment is manual and gated on device validation. Signing, full-display capture while backgrounded, HDMI, sound routing, and USB require Edmund's devices; source and CI checks do not prove those behaviors.

[Protocol](docs/protocol.md) · [Signaling setup](signaling/README.md) · [Planning handoff](docs/handoffs/2026-10-13-edserve.md)

Created in [T3 Code](https://t3.codes).

Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
