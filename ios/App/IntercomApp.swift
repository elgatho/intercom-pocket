import SwiftUI
import IntercomCore

@main struct IntercomApp: App {
    @StateObject private var model = Model()
    var body: some Scene { WindowGroup { ContentView().environmentObject(model) } }
}

final class Model: ObservableObject, EngineDelegate {
    @Published var state: CallState = .idle
    @Published var peers: [Peer] = []
    @Published var current: Peer?
    let engine: Engine
    var calls: CallController!
    private var servers: [IntercomServer] = []

    init() {
        let d = UserDefaults.standard
        let id = d.string(forKey: "id") ?? UUID().uuidString.prefix(8).lowercased().description
        d.set(id, forKey: "id")
        engine = Engine(id: id, name: d.string(forKey: "name") ?? UIDevice.current.name, key: d.string(forKey: "key") ?? "")
        engine.audio = AudioPipe(); engine.delegate = self
        if let data = d.data(forKey: "peers"), let p = try? JSONDecoder().decode([Peer].self, from: data) { peers = p }
        calls = CallController(engine: engine)
        if let s = try? IntercomServer(port: 2324, delegate: engine) { s.start(); servers.append(s) }
    }

    func engineChanged(state: CallState, peer: Peer?) {
        self.state = state; current = peer
        if state == .idle { calls.ended() }
    }
    func engineIncoming(callId: String, from: Peer, broadcast: Bool) { if !broadcast { calls.reportIncoming(from: from) } }

    func add(_ p: Peer) { peers.append(p); UserDefaults.standard.set(try? JSONEncoder().encode(peers), forKey: "peers") }
}

struct ContentView: View {
    @EnvironmentObject var m: Model
    @State private var host = ""
    var body: some View {
        NavigationStack {
            List {
                if m.state != .idle {
                    Section { Text(m.current?.name ?? "").font(.title2)
                        Button("hangup", role: .destructive) { m.engine.hangup() } }
                }
                Section("peers") {
                    ForEach(m.peers) { p in
                        HStack { Text(p.name); Spacer()
                            Button("call") { m.engine.call(p) }.buttonStyle(.borderedProminent)
                            Button("announce") { m.engine.call(p, broadcast: true) }.buttonStyle(.bordered) }
                    }
                }
                Section("add_peer") {
                    TextField("host", text: $host).textInputAutocapitalization(.never)
                    Button("add") { m.add(Peer(id: host, name: host, host: host)); host = "" }
                }
            }.navigationTitle("Intercom")
        }
    }
}
