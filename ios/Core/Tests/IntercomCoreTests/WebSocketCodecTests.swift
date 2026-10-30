import XCTest
@testable import IntercomCore

final class WebSocketCodecTests: XCTestCase {
    func testAcceptKeyMatchesRFCExample() {
        XCTAssertEqual(WebSocketCodec.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testRoundTripMaskedAndUnmasked() throws {
        for size in [0, 5, 125, 126, 2560, 70000] {
            let payload = Data((0..<size).map { UInt8($0 & 255) })
            for mask in [false, true] {
                var buf = WebSocketCodec.encode(WSFrame(.binary, payload), mask: mask)
                let f = try WebSocketCodec.decode(&buf)
                XCTAssertEqual(f, WSFrame(.binary, payload))
                XCTAssertTrue(buf.isEmpty)
            }
        }
    }

    func testPartialFrameNeedsMoreBytes() throws {
        let full = WebSocketCodec.encode(WSFrame(.text, Data("hello".utf8)), mask: true)
        var buf = full.prefix(full.count - 1)
        XCTAssertNil(try WebSocketCodec.decode(&buf))
        buf.append(full.last!)
        XCTAssertEqual(try WebSocketCodec.decode(&buf)?.payload, Data("hello".utf8))
    }
}
