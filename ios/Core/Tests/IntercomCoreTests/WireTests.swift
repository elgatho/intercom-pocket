import Crypto
import XCTest
@testable import IntercomCore

/// Mirrors WireTest.java: tokens built independently in the Kiosk Satellite (Dart) order/encoding.
final class WireTests: XCTestCase {
    func kioskToken(_ payload: String, key: String) -> String {
        let enc = Wire.b64(Data(payload.utf8))
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(enc.utf8), using: SymmetricKey(data: Data(("intercom:" + key).utf8)))
        return enc + "." + Wire.b64(Data(mac))
    }

    func testAcceptsKioskTokenAndIsSingleUse() {
        let t = kioskToken("{\"intercom\":\"test-call-1\",\"from\":\"kitchen\",\"n\":\"a1b\",\"exp\":1060000}",
                           key: "test-shared-key")
        let w = Wire(key: "test-shared-key", clock: { 1_000_000 })
        XCTAssertEqual(w.verify(t, call: "test-call-1")?["from"] as? String, "kitchen")
        XCTAssertNil(w.verify(t, call: "test-call-1"))
    }

    func testRefusesWrongKeyCallAndTampering() {
        let t = Wire(key: "correct").token(call: "call", from: "phone")
        XCTAssertNil(Wire(key: "wrong").verify(t, call: "call"))
        XCTAssertNil(Wire(key: "correct").verify(t, call: "other"))
        XCTAssertNil(Wire(key: "correct").verify(t + "x", call: "call"))
        XCTAssertNotNil(Wire(key: "correct").verify(t, call: "call"))
    }

    func testExpiryStrict() {
        var now: Int64 = 1_000_000
        let w = Wire(key: "key", clock: { now })
        let t = w.token(call: "call", from: "phone")
        now += 60000
        XCTAssertNil(w.verify(t, call: "call"))
    }

    func testFingerprintAndCallId() {
        XCTAssertEqual(Wire.fingerprint("").count, 0)
        XCTAssertEqual(Wire.fingerprint("abc"), "ba7816bf")
        XCTAssertTrue(Wire.validCallId("a-b_C1"))
        XCTAssertFalse(Wire.validCallId("a/b"))
        XCTAssertFalse(Wire.validCallId(""))
    }
}
