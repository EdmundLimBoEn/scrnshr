# Test scrnshr on your devices

The source implements the iPhone sender, native Mac receiver, direct LAN validation, internet pairing, TURN credential issuance, recovery, and experimental USB capture. Hardware checks below have not run. CI checks compilation and deterministic behavior; it cannot prove signing, capture while backgrounded, HDMI output, or protected-app support.

## Build on the Mac

1. Install/select Xcode 27.1 or newer with iOS 27 device and simulator SDKs.
2. Open `Scrnshr.xcodeproj`. Select your Apple development team for ScrnshrPhone and ScrnshrMac in Signing & Capabilities. Keep the phone's Screen Recording entitlement enabled.
3. Run `bash scripts/check-native.sh` for unsigned Debug/Release device, simulator, and Mac builds plus Mac and iOS XCTest. CI runs this same command.
4. Run ScrnshrMac on your Mac. Select ScrnshrPhone and your iPhone 17 Pro, then build/run the signed phone app. Approve Local Network access for direct Wi-Fi. Camera access is only used for QR scanning. The phone app requests no microphone permission.

If provisioning rejects `com.apple.developer.screen-recording`, record the actual signing error. The unsigned CI build does not verify entitlement provisioning.

CI uses stable Xcode 27.0. When ScreenCaptureKit is unavailable in the iOS Simulator SDK, the simulator app explicitly reports that screen sharing requires a physical iPhone; its UI, WebRTC, and audio-adapter tests still compile and run. The device build separately compiles the real capture implementation. Native loopback tests negotiate two WebRTC peers, encode and decode a synthetic video marker, handle offer retries, and verify sharing/stop messages over the data channel. They also inject one static frame before negotiation, require it to decode without another capture sample, and verify that stopping capture clears it before a later resume. They use custom audio devices and do not verify speakers or real captured sound.

The native check script uses `-collect-test-diagnostics never` because CI's verbose system diagnostic collector hung after all tests passed. Normal XCTest results, coverage, runtime warnings, and strict pass/failure/skip counts remain enabled, including Thread Performance Checker. Apple documents this [diagnostic collection option](https://developer.apple.com/forums/thread/698054).

## Prove capture and direct LAN HDMI

Keep the devices on the same reachable Wi-Fi for this first gate. No Worker, TURN account, Device Hub, or meeting app is needed.

1. In both apps choose Direct LAN and New direct session. On the phone tap Share screen and approve full-display capture in Apple's picker.
2. Wait for the phone's outgoing connection bundle, then copy/share it to the Mac and Import bundle. Copy the Mac's outgoing bundle back to the phone and import it. Repeat with the updated bundles if more ICE candidates arrived. Already imported entries are ignored.
   Keep a static phone screen visible while pairing. Confirm its first picture appears after connection without touching or scrolling the phone.
3. Switch to Home, Safari, the keyboard, and your actual demo app. Confirm the entire phone picture, app sounds, and continued sharing outside scrnshr. Speak near the phone and verify speech does not appear in the received sound.
4. Use an extended HDMI desktop. Move the phone presentation window onto the display and fullscreen it. Keep the controls on the Mac. Verify the four edges of the Calibration screen and small text, resize the window, then rotate repeatedly. No cropping, stretch, double rotation, or mirroring should occur.
5. Select the Mac's speakers in macOS Sound, then select the HDMI output if it has audio. Check sound in both cases, silence, mute/unmute, and sound-output changes while streaming. If the pinned WebRTC output requires restarting the connection after an output change, record that limitation.
6. Use a clip with a flash and simultaneous tone to check audiovisual sync. Film the phone and HDMI picture together to measure glass-to-glass delay. The targets are readable text, 30 fps during motion, and local latency under 200 ms. Record actual measurements rather than treating the targets as results.

The Calibration screen provides a clock, corner labels, small text, and a flash button. It does not generate a synchronized tone, so use a known audiovisual test clip for the sound check.

## Deploy signaling after the native gate

After signed capture, app audio, and the LAN HDMI checks pass, follow `signaling/README.md`. Configure Cloudflare TURN and the five GitHub deployment secrets listed there. Dispatch Deploy signaling on the tested commit and set hardware_validation to passed. The workflow reruns CI and deploys its tested Worker artifact. It does not deploy automatically on push.

In Mac Internet settings, enter the HTTPS Worker origin and owner credential. Create a session. Scan its QR in the phone app, verify the server shown on the phone, and approve the phone on the Mac. Then approve Apple's full-display picker. The owner credential and active-session credentials remain in device Keychain. A QR allows requests for five minutes, and the active session expires two hours after creation.

Test phone cellular to Mac Wi-Fi, then create a session with relay-only enabled. Repeat on a network that blocks UDP and confirm TLS/TCP TURN connectivity using the connection diagnostics. A server deliberately configured with ALLOW_STUN_ONLY is marked local-only and does not qualify for the internet gate.

## Recovery and the 30-minute demo

- Blackout and mute with Command-Shift-B. Interrupt networking, close/reopen the presentation window, reconnect, and verify the picture stays black and audio muted until explicit Resume.
- Stop sharing through iOS. The Mac must replace its last picture with a stopped state. Restarting capture requires Apple's picker approval again.
- Interrupt signaling alone while WebRTC remains healthy. The current picture must continue. Interrupt media transport separately; the presentation must show reconnecting and replace stale video.
- Leave a static screen visible for more than eight seconds. It must remain visible while capture heartbeats are healthy.
- Restart the receiver and use Reconnect saved session on each device. The Mac restores transport with the picture blacked out and audio muted; press Resume explicitly to present again. Confirm expired or rejected sessions cannot reconnect.
- Test Wi-Fi/cellular changes, phone lock/unlock, and an incoming call. Record which interruptions require new sharing approval.
- Unplug/replug HDMI while playing and while blacked out. After display loss is detected the app blackouts and mutes until Resume. macOS may move the window or change audio output before its notification; test that ordering rather than assuming zero leakage.
- Run the actual demo for 30 minutes. Record frame rate during movement, local latency, audio drift, recovery times, and Mac/iPhone heat or battery behavior.

Some apps intentionally block capture. Protected video and call audio are not promised.

## Experimental USB fallback

Connect a data cable, unlock the phone, approve Trust, and open USB phone capture in the Mac controls. Refresh phones, select your iPhone, and start capture. The app fails closed if it cannot identify Apple's phone-screen source. It does not substitute a webcam or microphone.

USB defaults to video only. Enable experimental USB audio deliberately for testing, then speak near both devices to establish whether that source contains only app sounds. Validate picture edges, orientation, sound synchronization, and unplug recovery before counting USB as a working fallback. The current implementation is a hardware experiment, not a verified cable capability.

## Results to return

Record the git commit, Xcode/iOS/macOS versions, signing result, app used for sound, network path and selected ICE candidate, HDMI resolution/output, latency and sync measurements, any output-switch restart needed, and the first failing step with its error.

Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
