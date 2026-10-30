# Intercom Pocket – iOS port (work in progress)

Native Swift/SwiftUI port of the Android app (PR #2). **Written on Linux, never compiled** – expect compile fixes.

* `Core/` – SwiftPM package: Wire (HMAC tokens), WebSocket codec, HTTP/WS server (Network.framework), Engine state machine. Wire/codec tests run with `swift test` on Linux/macOS.
* `App/` – SwiftUI UI, AVAudioEngine pipe (16 kHz PCM16, 80 ms frames), CallKit + PushKit.
* Build: `brew install xcodegen && cd ios && xcodegen && open IntercomPocket.xcodeproj`.

## Not done yet
* Bonjour discovery (`_kiosk-satellite._tcp`) – manual peer add only; shared key / settings UI; TLS server + cert pinning; DND/quiet hours/history.
* **Background receive**: iOS suspends apps, so calls while backgrounded need a VoIP push (APNs cert + a sender). The LAN protocol has no push step; the caller (Kiosk Satellite) would need a relay. With the `audio` background mode the app can keep listening only while an audio session is active.
