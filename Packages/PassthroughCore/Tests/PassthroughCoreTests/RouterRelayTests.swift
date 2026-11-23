import Network
import XCTest
@testable import PassthroughCore
@testable import PhoneTransport
import TestSupport

@available(macOS 15, *)
final class RouterRelayTests: XCTestCase {
    func testMacDialsPinnedPhoneAndLosesTheLinkWhenItsPairingIsRevoked() throws {
        let identity = try makeTestIdentity()
        let suite = "router-relay-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = PairingRegistry(defaults: defaults)
        let clientID = "mac"
        let key = WirelessLink.randomBytes(32)
        let certificate = identity.fingerprint
        XCTAssertNotNil(registry.addClient(id: clientID, name: "Test Mac", kind: .mac,
                                           certificateSHA256: certificate, linkKey: key))
        let queued = DispatchQueue(label: suite)
        let listenerPort = Locked<UInt16?>(nil)
        let ready = expectation(description: "phone listener is ready")
        let payload = Data("through the router relay".utf8)
        let destination: UInt16 = 7890
        let server = RouterRelay.Server(identity: identity, registry: registry, host: .ipv4(.loopback), port: .any) { port, stream in
            guard port == destination else { stream.cancel(); return }
            stream.receive(maximumLength: 1024) { data, _, error in
                XCTAssertNil(error)
                XCTAssertEqual(data, payload)
                stream.send(data, isComplete: true) { XCTAssertNil($0) }
            }
        }
        try server.start { port in
            listenerPort.set(port)
            ready.fulfill()
        }
        defer { server.stop() }
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(listenerPort.get())
        let tag = WirelessLink.macTag(clientID: clientID)
        let phone = WirelessPhone(phoneID: registry.phoneID, linkKey: key, isAndroid: false, label: "Test iPhone",
                                  pairingSlot: "test", routerCertificate: certificate)

        func dial(_ phone: WirelessPhone) throws -> Mux? {
            let result = Locked<Mux?>(nil)
            let completed = expectation(description: "direct connection attempt resolved")
            let stream = try XCTUnwrap(RouterRelay.dial(phone: phone, macTag: tag, queue: queued,
                                                       host: .ipv4(.loopback), port: port, wifiOnly: false) { mux in
                result.set(mux)
                completed.fulfill()
            })
            withExtendedLifetime(stream) { wait(for: [completed], timeout: 8) }
            return result.get()
        }

        var stranger = phone
        stranger.routerCertificate = String(repeating: "0", count: 64)
        XCTAssertNil(try dial(stranger), "the Mac rejects another server's certificate")
        stranger = phone
        stranger.linkKey = WirelessLink.randomBytes(32)
        XCTAssertNil(try dial(stranger), "the phone rejects an unpaired Mac")

        let mux = try XCTUnwrap(dial(phone))
        let disconnected = expectation(description: "revoked link closed")
        mux.onClose = { _ in disconnected.fulfill() }
        mux.start()
        let opened = mux.open(port: destination)
        let echoed = expectation(description: "bytes returned through the authenticated mux")
        opened.receive(maximumLength: 1024) { data, _, error in
            XCTAssertNil(error)
            XCTAssertEqual(data, payload)
            echoed.fulfill()
        }
        opened.send(payload, isComplete: true) { XCTAssertNil($0) }
        wait(for: [echoed], timeout: 5)

        registry.revoke(clientID: clientID)
        wait(for: [disconnected], timeout: 5)
        XCTAssertNil(try dial(phone), "the old pairing does not reconnect")
    }
}
