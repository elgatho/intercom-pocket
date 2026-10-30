import Foundation
import Network
import IntercomCore

/// Bonjour advertise + browse for `_kiosk-satellite._tcp` (port of Discovery.java).
/// TXT keys: id, name, version, port, tls ("1").
final class Discovery {
    static let type = "_kiosk-satellite._tcp"
    private var browser: NWBrowser?
    private var advert: NWListener?
    private var resolvers: [NWConnection] = []
    private let queue = DispatchQueue(label: "intercom.discovery")
    var onPeers: (([Peer]) -> Void)?

    func start(id: String, name: String, version: String, port: UInt16) {
        stop()
        // Advertise with a throwaway listener so the service record is published; real traffic uses IntercomServer.
        if let l = try? NWListener(using: .tcp, on: .any) {
            var txt = NWTXTRecord()
            txt["id"] = id; txt["name"] = name; txt["version"] = version; txt["port"] = String(port)
            l.service = NWListener.Service(name: "ks-\(id)", type: Self.type, txtRecord: txt)
            l.newConnectionHandler = { $0.cancel() }
            l.start(queue: queue); advert = l
        }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.type, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.resolve(results, selfId: id) }
        b.start(queue: queue); browser = b
    }

    func stop() { browser?.cancel(); advert?.cancel(); resolvers.forEach { $0.cancel() }; resolvers = [] }

    private func resolve(_ results: Set<NWBrowser.Result>, selfId: String) {
        resolvers.forEach { $0.cancel() }; resolvers = []
        var found: [String: Peer] = [:]
        let group = DispatchGroup()
        for r in results {
            guard case let .bonjour(txt) = r.metadata, let pid = txt["id"], pid != selfId else { continue }
            let name = txt["name"] ?? pid
            let port = Int(txt["port"] ?? "") ?? 2324
            let tls = txt["tls"] == "1"
            // Resolve service endpoint to an IP via a short-lived connection.
            let c = NWConnection(to: r.endpoint, using: .tcp)
            resolvers.append(c); group.enter()
            c.stateUpdateHandler = { st in
                if case .ready = st, case let .hostPort(h, _)? = c.currentPath?.remoteEndpoint {
                    var host = "\(h)"; if let i = host.firstIndex(of: "%") { host = String(host[..<i]) }
                    found[pid] = Peer(id: pid, name: name, host: host.contains(":") ? "[\(host)]" : host, port: port, tls: tls)
                    c.cancel()
                } else if case .failed = st { c.cancel() }
                else if case .cancelled = st { group.leave() }
            }
            c.start(queue: queue)
        }
        group.notify(queue: queue) { [weak self] in self?.onPeers?(Array(found.values)) }
    }
}
