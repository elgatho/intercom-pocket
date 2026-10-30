import Crypto
import Foundation

/// Kiosk Satellite intercom wire format (port of Wire.java).
/// Token = base64url(JSON payload, WITH '=' padding) + "." + base64url(HMAC-SHA256("intercom:"+key, payload)).
public final class Wire {
    public static let rate = 16000
    public static let frameBytes = 2560

    private let key: String
    private let clock: () -> Int64
    private var used: [String: Int64] = [:]
    private let lock = NSLock()

    public init(key: String, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.key = key
        self.clock = clock
    }

    public static func fingerprint(_ key: String) -> String {
        if key.isEmpty { return "" }
        let digest = SHA256.hash(data: Data(key.utf8))
        return String(hex(Data(digest)).prefix(8))
    }

    public static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    public static func validCallId(_ id: String?) -> Bool {
        guard let id = id, (1...160).contains(id.utf8.count) else { return false }
        return id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    /// Java's Base64.getUrlEncoder() keeps padding; so must we.
    static func b64(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    static func unb64(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    private func sign(_ payload: String) -> String {
        let k = SymmetricKey(data: Data(("intercom:" + key).utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: k)
        return Wire.b64(Data(mac))
    }

    public func token(call: String, from: String) -> String {
        let obj: [String: Any] = [
            "intercom": call, "from": from, "n": UUID().uuidString, "exp": clock() + 60000,
        ]
        let json = try! JSONSerialization.data(withJSONObject: obj)
        let payload = Wire.b64(json)
        return payload + "." + sign(payload)
    }

    /// Returns claims, or nil if invalid/expired/replayed. Tokens are single use.
    public func verify(_ token: String?, call: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard !key.isEmpty, let token = token, token.utf8.count <= 8192 else { return nil }
        let parts = token.components(separatedBy: ".")
        guard parts.count == 2 else { return nil }
        let expected = Data(sign(parts[0]).utf8), given = Data(parts[1].utf8)
        guard expected.count == given.count, zip(expected, given).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0,
              let raw = Wire.unb64(parts[0]),
              let j = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let exp = (j["exp"] as? NSNumber)?.int64Value
        else { return nil }
        let now = clock()
        guard exp > now, exp <= now + 90000,
              (j["intercom"] as? String) == call,
              !((j["from"] as? String) ?? "").isEmpty else { return nil }
        used = used.filter { $0.value >= now }
        if used[token] != nil || used.count > 4096 { return nil }
        used[token] = exp
        return j
    }
}
