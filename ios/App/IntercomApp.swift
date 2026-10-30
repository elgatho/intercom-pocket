import SwiftUI
import IntercomCore
import UIKit

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
    let discovery = Discovery()
    @Published var found: [Peer] = []
    @Published var name: String
    @Published var key: String
    @Published var relayURL: String
    @Published var relaySecret: String
    var voipToken: String?

    init() {
        let d = UserDefaults.standard
        let id = d.string(forKey: "id") ?? UUID().uuidString.prefix(8).lowercased().description
        d.set(id, forKey: "id")
        engine = Engine(id: id, name: d.string(forKey: "name") ?? UIDevice.current.name, key: Keychain.get("key") ?? "")
        name = d.string(forKey: "name") ?? UIDevice.current.name
        key = Keychain.get("key") ?? ""
        relayURL = d.string(forKey: "relayURL") ?? ""
        relaySecret = Keychain.get("relaySecret") ?? ""
        engine.audio = AudioPipe(); engine.delegate = self
        if let data = d.data(forKey: "peers"), let p = try? JSONDecoder().decode([Peer].self, from: data) { peers = p }
        calls = CallController(engine: engine)
        if let s = try? IntercomServer(port: 2324, delegate: engine) { s.start(); servers.append(s) }
        calls.onToken = { [weak self] t in self?.voipToken = t; self?.registerPush() }
        discovery.onPeers = { [weak self] p in DispatchQueue.main.async { self?.found = p } }
        discovery.start(id: id, name: name, version: engine.version, port: 2324)
    }

    func engineChanged(state: CallState, peer: Peer?) {
        self.state = state; current = peer
        if state == .idle { calls.ended() }
    }
    func engineIncoming(callId: String, from: Peer, broadcast: Bool) {
        guard !broadcast else { return }
        if calls.isReported { calls.lanCallArrived() } else { calls.reportIncoming(from: from) }
    }

    func registerPush() {
        guard let t = voipToken, let url = URL(string: relayURL + "/register"), !relayURL.isEmpty else { return }
        var r = URLRequest(url: url, timeoutInterval: 8)
        r.httpMethod = "POST"; r.setValue("Bearer " + relaySecret, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["id": engine.selfId, "token": t, "name": name])
        URLSession.shared.dataTask(with: r).resume()
    }

    func save() {
        UserDefaults.standard.set(relayURL, forKey: "relayURL"); Keychain.set("relaySecret", relaySecret)
        registerPush()
        UserDefaults.standard.set(name, forKey: "name"); Keychain.set("key", key)
        engine.configure(name: name, key: key)
        discovery.start(id: engine.selfId, name: name, version: engine.version, port: 2324)
    }

    func add(_ p: Peer) { peers.append(p); UserDefaults.standard.set(try? JSONEncoder().encode(peers), forKey: "peers") }
}

struct ContentView: View {
    @EnvironmentObject var m: Model
    @State private var host = ""
    @State private var showSettings = false
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
                Section("discovered") {
                    ForEach(m.found.filter { f in !m.peers.contains { $0.id == f.id } }) { p in
                        Button(p.name) { m.add(p) }
                    }
                }
                Section("add_peer") {
                    TextField("host", text: $host).textInputAutocapitalization(.never)
                    Button("add") { m.add(Peer(id: host, name: host, host: host)); host = "" }
                }
            }.navigationTitle("Intercom")
            .toolbar { Button { showSettings = true } label: { Image(systemName: "gearshape") } }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(m) }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("device") {
                    TextField("name", text: $m.name)
                    Text("id: \(m.engine.selfId)").font(.footnote).foregroundStyle(.secondary)
                }
                Section(header: Text("push_relay"), footer: Text("push_relay_hint")) {
                    TextField("relay_url", text: $m.relayURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("relay_secret", text: $m.relaySecret)
                }
                Section(header: Text("shared_key"), footer: Text("shared_key_hint")) {
                    SecureField("shared_key", text: $m.key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("fingerprint: \(Wire.fingerprint(m.key))").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("settings")
            .toolbar { Button("save") { m.save(); dismiss() } }
        }
    }
}
