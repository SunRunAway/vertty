import XCTest
@testable import VerttyRemote

final class RemoteURLTests: XCTestCase {
    func testAddsSchemeAndDefaultPort() {
        XCTAssertEqual(remoteURL(from: "192.168.1.5")?.absoluteString, "ws://192.168.1.5:58563")
        XCTAssertEqual(remoteURL(from: " mac.local:9000 ")?.absoluteString, "ws://mac.local:9000")
        XCTAssertEqual(remoteURL(from: "wss://example.com/vh")?.absoluteString, "wss://example.com:58563/vh")
        XCTAssertEqual(remoteURL(from: "http://127.0.0.1:1234")?.absoluteString, "ws://127.0.0.1:1234")
    }

    func testRejectsGarbage() {
        XCTAssertNil(remoteURL(from: ""))
        XCTAssertNil(remoteURL(from: "ftp://host"))
    }

    func testMessagesRoundTrip() throws {
        var msg = Remote.ClientMessage()
        msg.requestID = 7
        msg.newSession.projectID = "p"
        msg.newSession.operationID = "op"
        let decoded = try Remote.ClientMessage(serializedBytes: msg.serializedData())
        XCTAssertEqual(decoded.requestID, 7)
        XCTAssertEqual(decoded.newSession.operationID, "op")
    }
}
