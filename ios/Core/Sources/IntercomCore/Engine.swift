import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CallState: String { case idle, calling, ringing, connecting, inCall, broadcasting, listening }

public struct Peer: Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var tls: Bool
    public init(id: String, name: String, host: String, port: Int = 2324, tls: Bool = false) {
        self.id = id; self.name = name; self.host = host; self.port = port; self.tls = tls
    }
    var base: String { "\(tls ? "https" : "http")://\(host):\(port)" }
}

public enum PeerStatus: String { case ready, off, keyMismatch, tlsMismatch, dnd, confirmCert, unreachable }

/// Platform hooks: microphone/speaker pipeline and UI (CallKit) notifications.
public protocol AudioSink: AnyObject {
    /// Start capture/playback. `speaker` = loudspeaker routing (announcements).
    func start(speaker: Bool, onCapture: @escaping (Data) -> Void)
    func play(_ pcm: Data)
    func setTalking(_ on: Bool)
    func stop()
}

public protocol EngineDelegate: AnyObject {
    func engineChanged(state: CallState, peer: Peer?)
    func engineIncoming(callId: String, from: Peer, broadcast: Bool)
}

/// Call state machine (port of Engine.java): signalling over HTTP, audio over WebSocket.
public final class Engine: IntercomServerListener {
    public let selfId: String, version: String
    public private(set) var selfName: String
    public var enabled = true, dnd = false
    public weak var delegate: EngineDelegate?
    public var audio: AudioSink?
    public private(set) var state: CallState = .idle
    public private(set) var peer: Peer?
    private var wire: Wire
    private var sharedKey: String
    private var callId: String?
    private var link: Link?
    private var timer: Timer?
    private var outgoing: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .ephemeral)
    private let lock = NSRecursiveLock()
    public var port = 2324, tls = false

    public init(id: String, name: String, key: String, version: String = "2.0.1") {
        selfId = id; selfName = name; sharedKey = key; self.version = version; wire = Wire(key: key)
    }

    /// Apply settings changes (name / shared key) at runtime.
    public func configure(name: String, key: String) {
        lock.lock(); defer { lock.unlock() }
        selfName = name; sharedKey = key; wire = Wire(key: key)
    }

    // MARK: server side
    public func identity() -> [String: Any] {
        ["id": selfId, "name": selfName, "version": version, "enabled": enabled, "key": Wire.fingerprint(sharedKey),
         "dnd": dnd, "endpoint": ["port": port, "tls": tls]]
    }

    public func incoming(_ b: [String: Any], token: String, host: String) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return ["status": "off"] }
        guard let id = b["call"] as? String, Wire.validCallId(id), let f = b["from"] as? [String: Any],
              let fid = f["id"] as? String, !fid.isEmpty else { return ["status": "invalid", "code": 400] }
        guard (wire.verify(token, call: id) != nil) else { return ["status": "key", "code": 403] }
        let broadcast = (b["kind"] as? String) == "broadcast"
        let from = Peer(id: fid, name: (f["name"] as? String) ?? fid, host: (f["address"] as? String) ?? host,
                        port: (f["port"] as? Int) ?? 2324, tls: (f["tls"] as? Bool) ?? false)
        if dnd && !broadcast { return ["status": "dnd"] }
        guard state == .idle else { return ["status": "busy"] }
        callId = id; peer = from
        set(broadcast ? .listening : .ringing)
        arm(broadcast ? 12 : 45) { [weak self] in self?.end(notify: broadcast ? nil : "missed") }
        delegate?.engineIncoming(callId: id, from: from, broadcast: broadcast)
        return ["status": broadcast ? "listening" : "ringing"]
    }

    public func signal(id: String, body: [String: Any], token: String, host: String) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard id == callId, (wire.verify(token, call: id) != nil) else { return ["error": "forbidden", "code": 403] }
        switch body["action"] as? String {
        case "answer" where state == .calling: set(.connecting); openAudio()
        case "hangup", "cancel", "decline", "missed": end(notify: nil)
        default: break
        }
        return ["ok": true]
    }

    public func allowAudio(id: String, token: String?, host: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard id == callId, state == .connecting || state == .listening, let t = token else { return false }
        return (wire.verify(t, call: id) != nil)
    }

    public func attach(id: String, link l: Link) {
        lock.lock(); defer { lock.unlock() }
        link = l; timer?.invalidate()
        let broadcast = state == .listening
        set(broadcast ? .listening : .inCall)
        audio?.start(speaker: broadcast) { [weak self] pcm in self?.link?.bytes(pcm) }
        if !broadcast { l.text(#"{"type":"talk","on":false}"#) }
    }

    public func message(id: String, link: Link, text: String?, bytes: Data?) {
        if let b = bytes, b.count >= 2, b.count <= 8192, b.count % 2 == 0 { audio?.play(b) }
        if let t = text, let d = t.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            if j["type"] as? String == "end" { lock.lock(); end(notify: nil); lock.unlock() }
        }
    }

    public func disconnected(id: String, link l: Link) {
        lock.lock(); defer { lock.unlock() }
        if id == callId, link === l { end(notify: nil) }
    }

    // MARK: user actions
    public func answer() {
        lock.lock(); defer { lock.unlock() }
        guard state == .ringing, let id = callId, let p = peer else { return }
        set(.connecting)
        arm(12) { [weak self] in self?.end(notify: "hangup") }
        post(p, "/api/intercom/call/\(id)", ["action": "answer"], id: id) { _ in }
    }

    public func decline() { lock.lock(); end(notify: "decline"); lock.unlock() }
    public func hangup() { lock.lock(); end(notify: state == .calling ? "cancel" : "hangup"); lock.unlock() }

    public func setTalking(_ on: Bool) {
        audio?.setTalking(on)
        link?.text(#"{"type":"talk","on":\#(on)}"#)
    }

    public func call(_ p: Peer, broadcast: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard state == .idle else { return }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        callId = id; peer = p
        set(broadcast ? .broadcasting : .calling)
        let body: [String: Any] = ["call": id, "kind": broadcast ? "broadcast" : "call",
            "from": ["id": selfId, "name": selfName, "address": "", "port": port, "version": version, "tls": tls]]
        post(p, "/api/intercom/call", body, id: id) { [weak self] r in
            guard let self = self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.callId == id else { return }
            switch r?["status"] as? String {
            case "ringing": self.arm(45) { [weak self] in self?.end(notify: "cancel") }
            case "listening" where broadcast: self.openAudio()
            default: self.end(notify: nil)
            }
        }
    }

    // MARK: internals
    private func openAudio() {
        guard let p = peer, let id = callId else { return }
        let broadcast = state == .broadcasting
        var c = URLComponents(string: p.base.replacingOccurrences(of: "http", with: "ws") + "/api/intercom/audio/\(id)")!
        c.queryItems = [URLQueryItem(name: "token", value: wire.token(call: id, from: selfId))]
        let task = session.webSocketTask(with: c.url!)
        outgoing = task; task.resume()
        let l = ClientLink(task)
        link = l
        audio?.start(speaker: false) { [weak l] pcm in l?.bytes(pcm) }
        if !broadcast { set(.inCall); l.text(#"{"type":"talk","on":false}"#) }
        receiveLoop(task, id: id, l)
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask, id: String, _ l: ClientLink) {
        t.receive { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let m):
                switch m {
                case .data(let d): self.message(id: id, link: l, text: nil, bytes: d)
                case .string(let s): self.message(id: id, link: l, text: s, bytes: nil)
                @unknown default: break
                }
                self.receiveLoop(t, id: id, l)
            case .failure: self.disconnected(id: id, link: l)
            }
        }
    }

    private func end(notify action: String?) {
        guard callId != nil else { return }
        let id = callId!, p = peer
        timer?.invalidate(); timer = nil
        link?.text(#"{"type":"end"}"#); link?.close(); link = nil
        outgoing?.cancel(with: .normalClosure, reason: nil); outgoing = nil
        audio?.stop()
        if let a = action, let p = p { post(p, "/api/intercom/call/\(id)", ["action": a], id: id) { _ in } }
        callId = nil; peer = nil
        set(.idle)
    }

    private func set(_ s: CallState) {
        state = s
        let p = peer
        DispatchQueue.main.async { self.delegate?.engineChanged(state: s, peer: p) }
    }

    private func arm(_ sec: TimeInterval, _ f: @escaping () -> Void) {
        timer?.invalidate()
        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(withTimeInterval: sec, repeats: false) { _ in
                self.lock.lock(); f(); self.lock.unlock()
            }
        }
    }

    private func post(_ p: Peer, _ path: String, _ body: [String: Any], id: String, done: @escaping ([String: Any]?) -> Void) {
        var r = URLRequest(url: URL(string: p.base + path)!, timeoutInterval: 6)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer " + wire.token(call: id, from: selfId), forHTTPHeaderField: "Authorization")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: r) { d, _, _ in
            done(d.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] })
        }.resume()
    }

    /// Probe a peer's identity endpoint (port of Engine.probe).
    public func probe(_ p: Peer, done: @escaping (PeerStatus) -> Void) {
        var r = URLRequest(url: URL(string: p.base + "/api/intercom/identity")!, timeoutInterval: 4)
        r.httpMethod = "GET"
        session.dataTask(with: r) { [sharedKey] d, resp, _ in
            guard let d = d, let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return done(.unreachable) }
            if (resp as? HTTPURLResponse)?.statusCode == 426 { return done(.tlsMismatch) }
            if j["enabled"] as? Bool == false { return done(.off) }
            if j["key"] as? String != Wire.fingerprint(sharedKey) { return done(.keyMismatch) }
            done((j["dnd"] as? Bool) == true ? .dnd : .ready)
        }.resume()
    }
}

final class ClientLink: Link {
    let t: URLSessionWebSocketTask
    private var queued = 0
    private let q = DispatchQueue(label: "intercom.clientlink")
    init(_ t: URLSessionWebSocketTask) { self.t = t }
    func text(_ s: String) { t.send(.string(s)) { _ in } }
    func bytes(_ d: Data) {
        q.async {
            if self.queued >= 6 { return }
            self.queued += 1
            self.t.send(.data(d)) { _ in self.q.async { self.queued -= 1 } }
        }
    }
    func close() { t.cancel(with: .normalClosure, reason: nil) }
}

#if canImport(FoundationNetworking)
// swift-corelibs-foundation only offers async send/receive; add the callback forms used above (build/test only).
extension URLSessionWebSocketTask {
    func send(_ m: Message, completionHandler: @escaping (Error?) -> Void) {
        Task { do { try await self.send(m); completionHandler(nil) } catch { completionHandler(error) } }
    }
    func receive(completionHandler: @escaping (Result<Message, Error>) -> Void) {
        Task { do { completionHandler(.success(try await self.receive())) } catch { completionHandler(.failure(error)) } }
    }
}
#endif
