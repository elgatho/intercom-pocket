import Foundation

/// Audio/control channel to one peer; implemented by both the server side and the client side.
public protocol Link: AnyObject {
    func text(_ s: String)
    func bytes(_ d: Data)
    func close()
}

public protocol IntercomServerListener: AnyObject {
    func identity() -> [String: Any]
    func incoming(_ body: [String: Any], token: String, host: String) -> [String: Any]
    func signal(id: String, body: [String: Any], token: String, host: String) -> [String: Any]
    func allowAudio(id: String, token: String?, host: String) -> Bool
    func attach(id: String, link: Link)
    func message(id: String, link: Link, text: String?, bytes: Data?)
    func disconnected(id: String, link: Link)
}

#if canImport(Network)
import Network

/// HTTP/1.1 + WebSocket server on one port (port of IntercomServer.java).
/// Routes: GET /api/intercom/identity, POST /api/intercom/call[/<id>], WS /api/intercom/audio/<id>?token=…
public final class IntercomServer {
    private let listener: NWListener
    private weak var delegate: IntercomServerListener?
    private let queue = DispatchQueue(label: "intercom.server")
    private var identityTimes: [String: Date] = [:]
    private var conns = Set<ObjectIdentifier>()
    public let requireTLS: Bool, secure: Bool

    /// `parameters` carries TLS options for the encrypted (2325) listener; nil = plain.
    public init(port: UInt16, delegate: IntercomServerListener, parameters: NWParameters? = nil, requireTLS: Bool = false) throws {
        self.delegate = delegate
        self.secure = parameters != nil
        self.requireTLS = requireTLS
        listener = try NWListener(using: parameters ?? .tcp, on: NWEndpoint.Port(rawValue: port)!)
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
    }

    public func stop() { listener.cancel() }

    private func accept(_ c: NWConnection) {
        let h = ServerConnection(c, server: self, queue: queue)
        conns.insert(ObjectIdentifier(h)); h.onDone = { [weak self] in self?.conns.remove(ObjectIdentifier(h)) }
        retained.insert(h)
        c.start(queue: queue)
        h.receive()
    }
    fileprivate var retained = Set<ServerConnection>()

    fileprivate func serve(_ req: HTTPRequest, conn: ServerConnection) {
        let host = conn.remoteHost
        func reply(_ code: Int, _ j: [String: Any]) { conn.respond(code, j) }
        if req.path == "/api/intercom/identity", req.method == "GET" {
            let now = Date()
            identityTimes = identityTimes.filter { $0.value > now.addingTimeInterval(-1) }
            if identityTimes[host] != nil { return reply(429, ["error": "too many probes"]) }
            if identityTimes.count > 512 { return reply(503, ["error": "busy"]) }
            identityTimes[host] = now
            return reply(200, delegate?.identity() ?? [:])
        }
        if requireTLS && !secure { return reply(426, ["status": "tls"]) }
        let audio = "/api/intercom/audio/"
        if req.path.hasPrefix(audio) {
            let id = String(req.path.dropFirst(audio.count))
            guard Wire.validCallId(id), req.headers["upgrade"]?.lowercased() == "websocket",
                  let key = req.headers["sec-websocket-key"],
                  delegate?.allowAudio(id: id, token: req.query["token"], host: host) == true
            else { return reply(403, ["error": "refused"]) }
            conn.upgrade(key: key, id: id)
            delegate?.attach(id: id, link: conn)
            return
        }
        guard req.method == "POST", req.path == "/api/intercom/call" || req.path.hasPrefix("/api/intercom/call/")
        else { return reply(404, ["error": "not found"]) }
        guard let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any]
        else { return reply(400, ["error": "invalid request"]) }
        let auth = req.headers["authorization"] ?? ""
        let token = auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : ""
        let answer: [String: Any]
        if req.path == "/api/intercom/call" { answer = delegate?.incoming(body, token: token, host: host) ?? [:] }
        else {
            answer = delegate?.signal(id: String(req.path.dropFirst("/api/intercom/call/".count)),
                                      body: body, token: token, host: host) ?? [:]
        }
        reply((answer["code"] as? Int) ?? 200, answer)
    }

    fileprivate func wsMessage(_ conn: ServerConnection, _ f: WSFrame) {
        guard let id = conn.wsId else { return }
        switch f.opcode {
        case .binary: delegate?.message(id: id, link: conn, text: nil, bytes: f.payload)
        case .text: delegate?.message(id: id, link: conn, text: String(data: f.payload, encoding: .utf8), bytes: nil)
        default: break
        }
    }

    fileprivate func wsClosed(_ conn: ServerConnection) {
        if let id = conn.wsId { delegate?.disconnected(id: id, link: conn) }
        retained.remove(conn)
    }
}

struct HTTPRequest {
    var method: String, path: String, query: [String: String], headers: [String: String], body: Data
}

final class ServerConnection: Link, Hashable {
    static func == (a: ServerConnection, b: ServerConnection) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }

    let c: NWConnection
    unowned let server: IntercomServer
    let queue: DispatchQueue
    var buf = Data()
    var wsId: String?
    var onDone: (() -> Void)?
    private var queuedAudio = 0
    static let maxQueuedAudio = 6  // drop audio rather than build a backlog on slow peers
    var remoteHost: String {
        if case let .hostPort(h, _) = c.endpoint {
            var s = "\(h)"; if let i = s.firstIndex(of: "%") { s = String(s[..<i]) }; return s
        }
        return ""
    }

    init(_ c: NWConnection, server: IntercomServer, queue: DispatchQueue) {
        self.c = c; self.server = server; self.queue = queue
    }

    func receive() {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, err in
            if let d = data { buf.append(d) }
            if err != nil || (done && data == nil) { return finish() }
            if wsId != nil { pumpFrames() } else { pumpHTTP() }
            if c.state != .cancelled { receive() }
        }
    }

    private func pumpHTTP() {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
            if buf.count > 16384 { respond(400, ["error": "invalid request"]) }
            return
        }
        guard let head = String(data: buf[buf.startIndex..<end.lowerBound], encoding: .utf8) else { return respond(400, ["error": "invalid request"]) }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return respond(400, ["error": "invalid request"]) }
        var headers: [String: String] = [:]
        for l in lines { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        if len > 65536 { return respond(413, ["error": "invalid body"]) }
        let bodyStart = end.upperBound
        guard buf.count - (bodyStart - buf.startIndex) >= len else { return }
        let body = buf[bodyStart..<(bodyStart + len)]
        buf.removeSubrange(buf.startIndex..<(bodyStart + len))
        let comps = URLComponents(string: parts[1])
        var q: [String: String] = [:]
        comps?.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
        server.serve(HTTPRequest(method: parts[0], path: comps?.path ?? parts[1], query: q, headers: headers, body: Data(body)), conn: self)
    }

    func respond(_ code: Int, _ j: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: j.filter { $0.key != "code" || code != 200 })) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(code) Intercom\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { [self] _ in c.cancel(); finish() })
    }

    func upgrade(key: String, id: String) {
        wsId = id
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(WebSocketCodec.acceptKey(for: key))\r\n\r\n"
        c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
    }

    private func pumpFrames() {
        do {
            while let f = try WebSocketCodec.decode(&buf) {
                switch f.opcode {
                case .ping: send(WSFrame(.pong, f.payload))
                case .close: send(WSFrame(.close, f.payload)); finish(); return
                default: server.wsMessage(self, f)
                }
            }
        } catch { finish() }
    }

    private var finished = false
    func finish() {
        guard !finished else { return }
        finished = true; c.cancel(); onDone?(); server.wsClosed(self)
    }

    private func send(_ f: WSFrame, done: (() -> Void)? = nil) {
        c.send(content: WebSocketCodec.encode(f, mask: false), completion: .contentProcessed { _ in done?() })
    }

    func text(_ s: String) { queue.async { self.send(WSFrame(.text, Data(s.utf8))) } }
    func bytes(_ d: Data) {
        queue.async {
            if self.queuedAudio >= Self.maxQueuedAudio { return }
            self.queuedAudio += 1
            self.send(WSFrame(.binary, d)) { self.queue.async { self.queuedAudio -= 1 } }
        }
    }
    func close() { queue.async { self.send(WSFrame(.close, Data([0x03, 0xe8]))) { self.finish() } } }
}
#endif
