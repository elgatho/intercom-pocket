import CallKit
import PushKit
import IntercomCore

/// CallKit + PushKit glue so incoming calls ring while the app is backgrounded.
/// NOTE: iOS requires a VoIP push to wake a suspended app; the Kiosk Satellite side must send one
/// (see ios/README.md). While the app is alive (audio background mode) LAN calls arrive directly.
final class CallController: NSObject, CXProviderDelegate, PKPushRegistryDelegate {
    private let provider = CXProvider(configuration: {
        let c = CXProviderConfiguration(); c.supportsVideo = false; c.maximumCallsPerCallGroup = 1
        c.supportedHandleTypes = [.generic]; return c
    }())
    private let ctl = CXCallController()
    private var uuid: UUID?
    private let engine: Engine
    private let push = PKPushRegistry(queue: .main)
    var onToken: ((String) -> Void)?

    init(engine: Engine) {
        self.engine = engine; super.init()
        provider.setDelegate(self, queue: .main)
        push.delegate = self; push.desiredPushTypes = [.voIP]
    }

    func reportIncoming(from p: Peer, completion: ((Error?) -> Void)? = nil) {
        let u = UUID(); uuid = u
        let upd = CXCallUpdate(); upd.remoteHandle = CXHandle(type: .generic, value: p.id)
        upd.localizedCallerName = p.name; upd.hasVideo = false
        provider.reportNewIncomingCall(with: u, update: upd) { completion?($0) }
    }

    func ended() { if let u = uuid { provider.reportCall(with: u, endedAt: nil, reason: .remoteEnded); uuid = nil } }

    func providerDidReset(_ p: CXProvider) { engine.hangup() }
    func provider(_ p: CXProvider, perform a: CXAnswerCallAction) { engine.answer(); a.fulfill() }
    func provider(_ p: CXProvider, perform a: CXEndCallAction) { engine.state == .ringing ? engine.decline() : engine.hangup(); a.fulfill() }
    func provider(_ p: CXProvider, didActivate s: AVAudioSession) {}

    func pushRegistry(_ r: PKPushRegistry, didUpdate c: PKPushCredentials, for t: PKPushType) {
        onToken?(c.token.map { String(format: "%02x", $0) }.joined())
    }
    func pushRegistry(_ r: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for t: PKPushType, completion: @escaping () -> Void) {
        // Must report a CallKit call immediately or iOS terminates the app.
        let d = payload.dictionaryPayload
        let p = Peer(id: d["id"] as? String ?? "?", name: d["name"] as? String ?? "Intercom",
                     host: d["host"] as? String ?? "", port: d["port"] as? Int ?? 2324)
        reportIncoming(from: p) { _ in completion() }
    }
}
import AVFoundation
