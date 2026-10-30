import Crypto
import Foundation

/// Minimal RFC 6455 framing. Needed because the kiosk protocol serves HTTP POST and the audio
/// WebSocket on the same port, which NWProtocolWebSocket cannot do.
public enum WSOpcode: UInt8 { case cont = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10 }

public struct WSFrame: Equatable {
    public var opcode: WSOpcode
    public var payload: Data
    public init(_ opcode: WSOpcode, _ payload: Data = Data()) { self.opcode = opcode; self.payload = payload }
}

public enum WebSocketCodec {
    public static let maxPayload = 1 << 20

    public static func acceptKey(for key: String) -> String {
        let d = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(d).base64EncodedString()
    }

    /// Encodes one unfragmented frame. Clients must mask (RFC 6455 §5.3); servers must not.
    public static func encode(_ f: WSFrame, mask: Bool) -> Data {
        var out = Data([0x80 | f.opcode.rawValue])
        let n = f.payload.count, m: UInt8 = mask ? 0x80 : 0
        if n < 126 { out.append(m | UInt8(n)) }
        else if n < 65536 { out.append(m | 126); out.append(UInt8(n >> 8)); out.append(UInt8(n & 255)) }
        else { out.append(m | 127); for s in stride(from: 56, through: 0, by: -8) { out.append(UInt8((n >> s) & 255)) } }
        if mask {
            var key = [UInt8](repeating: 0, count: 4)
            for i in 0..<4 { key[i] = UInt8.random(in: 0...255) }
            out.append(contentsOf: key)
            for (i, b) in f.payload.enumerated() { out.append(b ^ key[i % 4]) }
        } else { out.append(f.payload) }
        return out
    }

    public enum DecodeError: Error { case tooLarge, badOpcode, fragmented }

    /// Pops one complete frame from `buffer`, or nil if more bytes are needed.
    public static func decode(_ buffer: inout Data) throws -> WSFrame? {
        let b = [UInt8](buffer.prefix(14))
        guard b.count >= 2 else { return nil }
        let fin = b[0] & 0x80 != 0
        guard let op = WSOpcode(rawValue: b[0] & 0x0f) else { throw DecodeError.badOpcode }
        if !fin || op == .cont { throw DecodeError.fragmented }  // kiosks send whole frames
        let masked = b[1] & 0x80 != 0
        var len = Int(b[1] & 0x7f), idx = 2
        if len == 126 { guard b.count >= 4 else { return nil }; len = Int(b[2]) << 8 | Int(b[3]); idx = 4 }
        else if len == 127 {
            guard b.count >= 10 else { return nil }
            var v: UInt64 = 0; for i in 2..<10 { v = v << 8 | UInt64(b[i]) }
            guard v <= UInt64(maxPayload) else { throw DecodeError.tooLarge }
            len = Int(v); idx = 10
        }
        guard len <= maxPayload else { throw DecodeError.tooLarge }
        let total = idx + (masked ? 4 : 0) + len
        guard buffer.count >= total else { return nil }
        let base = buffer.startIndex
        var payload = Data(buffer[(base + idx + (masked ? 4 : 0))..<(base + total)])
        if masked {
            let key = [UInt8](buffer[(base + idx)..<(base + idx + 4)])
            for i in 0..<payload.count { payload[payload.startIndex + i] ^= key[i % 4] }
        }
        buffer.removeSubrange(base..<(base + total))
        return WSFrame(op, payload)
    }
}
