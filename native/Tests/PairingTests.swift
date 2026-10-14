// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
import CryptoKit
import XCTest
@testable import ScrnshrMac

final class PairingTests: XCTestCase {
    private let id = UUID().uuidString
    private let key = Data(repeating: 42, count: 32).base64URL

    func testQRRoundTripAndExpiry() throws {
        let code = try PairingCode(server: XCTUnwrap(URL(string: "https://pair.example.com")),
                                   sessionId: id, joinToken: Data(repeating: 1, count: 32).base64URL,
                                   expiresAt: .now.addingTimeInterval(7200))
        XCTAssertEqual(try PairingCode.parse(code.url.absoluteString), code)
        XCTAssertThrowsError(try PairingCode.parse(code.url.absoluteString, now: code.joinExpiresAt))
    }

    func testRejectsNonHTTPSAndEmbeddedCredentials() throws {
        for value in ["http://example.com", "https://user:pass@example.com", "https://example.com/?token=x", "https://example.com/path"] {
            XCTAssertThrowsError(try PairingCode.validateServer(XCTUnwrap(URL(string: value))))
        }
        XCTAssertThrowsError(try PairingCode.parse("scrnshr://join?data=not_json"))
        XCTAssertThrowsError(try PairingCode.parse(String(repeating: "A", count: 8193)))
    }

    func testAuthenticatesBothDirectionsAndRejectsReplay() throws {
        var phone = try SignalAuthenticator(sessionId: id, pairingKey: key, role: .sender)
        var mac = try SignalAuthenticator(sessionId: id, pairingKey: key, role: .receiver)
        let offer = try phone.sign(.offer("v=0\r\n"))
        XCTAssertEqual(try mac.verify(payload: offer.payload, mac: offer.mac), .offer("v=0\r\n"))
        XCTAssertThrowsError(try mac.verify(payload: offer.payload, mac: offer.mac))
        let answer = try mac.sign(.answer("v=0\r\na=answer\r\n"))
        XCTAssertEqual(try phone.verify(payload: answer.payload, mac: answer.mac), .answer("v=0\r\na=answer\r\n"))
    }

    func testRejectsTamperingWrongSessionAndReflection() throws {
        var phone = try SignalAuthenticator(sessionId: id, pairingKey: key, role: .sender)
        var mac = try SignalAuthenticator(sessionId: id, pairingKey: key, role: .receiver)
        var differentSession = try SignalAuthenticator(sessionId: UUID().uuidString, pairingKey: key, role: .receiver)
        let offer = try phone.sign(.offer("v=0\r\n"))
        XCTAssertThrowsError(try mac.verify(payload: offer.payload + " ", mac: offer.mac))
        XCTAssertThrowsError(try mac.verify(payload: offer.payload, mac: Data(repeating: 0, count: 32).base64URL))
        XCTAssertThrowsError(try differentSession.verify(payload: offer.payload, mac: offer.mac))
        XCTAssertThrowsError(try phone.verify(payload: offer.payload, mac: offer.mac))
        XCTAssertEqual(try mac.verify(payload: offer.payload, mac: offer.mac), .offer("v=0\r\n"))
    }

    func testNewOfferResetsAnswerSequenceAndRetiresOldGeneration() throws {
        var phone = try SignalAuthenticator(sessionId: id, pairingKey: key, role: .sender)
        var mac = try SignalAuthenticator(sessionId: id, pairingKey: key, role: .receiver)
        let first = try phone.sign(.offer("first"))
        _ = try mac.verify(payload: first.payload, mac: first.mac)
        let oldAnswer = try mac.sign(.answer("old"))
        _ = try phone.verify(payload: oldAnswer.payload, mac: oldAnswer.mac)
        let second = try phone.sign(.offer("second"))
        _ = try mac.verify(payload: second.payload, mac: second.mac)
        let newAnswer = try mac.sign(.answer("new"))
        XCTAssertEqual(try phone.verify(payload: newAnswer.payload, mac: newAnswer.mac), .answer("new"))
        XCTAssertThrowsError(try mac.verify(payload: first.payload, mac: first.mac))
        XCTAssertThrowsError(try phone.verify(payload: oldAnswer.payload, mac: oldAnswer.mac))
    }

    func testBase64URLStrictAlphabet() {
        let data = Data([0, 127, 254, 255])
        XCTAssertEqual(Data(base64URL: data.base64URL), data)
        XCTAssertNil(Data(base64URL: "a+b/"))
        XCTAssertNil(Data(base64URL: "a b"))
    }

    func testRestoredReceiverAuthenticatesRestartAndStillRejectsOldOffer() throws {
        var phone = try SignalAuthenticator(sessionId: id, pairingKey: key, role: .sender)
        var mac = try SignalAuthenticator(sessionId: id, pairingKey: key, role: .receiver)
        let initial = try phone.sign(.offer("initial"))
        _ = try mac.verify(payload: initial.payload, mac: initial.mac)
        let answer = try mac.sign(.answer("answer"))
        _ = try phone.verify(payload: answer.payload, mac: answer.mac)
        let data = try JSONEncoder().encode(mac.checkpoint)
        let checkpoint = try JSONDecoder().decode(SignalAuthenticationState.self, from: data)
        var restored = try SignalAuthenticator(sessionId: id, pairingKey: key, role: .receiver, checkpoint: checkpoint)
        XCTAssertThrowsError(try restored.verify(payload: initial.payload, mac: initial.mac))
        let restart = try restored.sign(.restart)
        XCTAssertEqual(try phone.verify(payload: restart.payload, mac: restart.mac), .restart)
        let fresh = try phone.sign(.offer("fresh"))
        XCTAssertEqual(try restored.verify(payload: fresh.payload, mac: fresh.mac), .offer("fresh"))
    }

    func testOutstandingOfferRetryKeepsGenerationAndAdvancesSequenceAcrossCheckpoint() throws {
        var phone = try SignalAuthenticator(sessionId: id, pairingKey: key, role: .sender)
        var mac = try SignalAuthenticator(sessionId: id, pairingKey: key, role: .receiver)
        let sdp = "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\nc=IN IP4 0.0.0.0\r\na=rtcp:9 IN IP4 0.0.0.0\r\na=mid:0\r\na=ice-ufrag:first\r\na=sendonly\r\n"
        let first = try phone.sign(.offer(sdp))
        _ = try mac.verify(payload: first.payload, mac: first.mac)
        let firstEnvelope = try JSONDecoder().decode(AuthenticatedSignal.self, from: Data(first.payload.utf8))
        let checkpoint = try JSONDecoder().decode(SignalAuthenticationState.self, from: JSONEncoder().encode(phone.checkpoint))
        phone = try SignalAuthenticator(sessionId: id, pairingKey: key, role: .sender, checkpoint: checkpoint)
        let gathered = sdp.replacingOccurrences(of: "m=video 9 ", with: "m=video 5000 ")
            .replacingOccurrences(of: "c=IN IP4 0.0.0.0", with: "c=IN IP4 192.0.2.1")
            .replacingOccurrences(of: "a=rtcp:9 IN IP4 0.0.0.0", with: "a=rtcp:5001 IN IP4 192.0.2.1")
            + "a=candidate:1 1 udp 2122260223 192.0.2.1 5000 typ host\r\na=end-of-candidates\r\n"
        let retry = try phone.sign(.offer(gathered))
        let retryEnvelope = try JSONDecoder().decode(AuthenticatedSignal.self, from: Data(retry.payload.utf8))
        XCTAssertEqual(retryEnvelope.generation, firstEnvelope.generation)
        XCTAssertGreaterThan(retryEnvelope.sequence, firstEnvelope.sequence)
        XCTAssertEqual(try mac.verify(payload: retry.payload, mac: retry.mac), .offer(gathered))
        XCTAssertThrowsError(try mac.verify(payload: first.payload, mac: first.mac))
        let answer = try mac.sign(.answer("answer-to-the-outstanding-offer"))
        XCTAssertEqual(try phone.verify(payload: answer.payload, mac: answer.mac), .answer("answer-to-the-outstanding-offer"))
    }

    func testSDPDirectionOrICECredentialChangesStartNewGeneration() throws {
        var phone = try SignalAuthenticator(sessionId: id, pairingKey: key, role: .sender)
        let base = "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=ice-ufrag:first\r\na=sendonly\r\n"
        let first = try phone.sign(.offer(base))
        let direction = try phone.sign(.offer(base.replacingOccurrences(of: "a=sendonly", with: "a=inactive")))
        let ice = try phone.sign(.offer(base.replacingOccurrences(of: "a=ice-ufrag:first", with: "a=ice-ufrag:second")))
        let rejected = try phone.sign(.offer(base.replacingOccurrences(of: "m=video 9 ", with: "m=video 0 ")))
        let envelopes = try [first, direction, ice, rejected].map {
            try JSONDecoder().decode(AuthenticatedSignal.self, from: Data($0.payload.utf8))
        }
        XCTAssertEqual(Set(envelopes.map(\.generation)).count, 4)
    }

    func testManualBundleRejectsOwnRoleAndAcceptsPeer() throws {
        let bundle = ManualSignalBundle(version: 1, id: UUID(), role: .sender, signals: [.offer("offer")])
        let data = try JSONEncoder().encode(bundle)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(try ManualSignalBundle.parse(text, expectedRole: .sender).signals, [.offer("offer")])
        XCTAssertThrowsError(try ManualSignalBundle.parse(text, expectedRole: .receiver))
    }
}
