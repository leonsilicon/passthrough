import Foundation
import Network

/// A router's upstream IPv4 address on this iPhone's Personal Hotspot.
public struct TravelRouterLink: Equatable, Sendable {
    public static let port: UInt16 = 17891

    public let address: String
    public let macClientID: String
    var macTag: String { WirelessLink.macTag(clientID: macClientID) }
    var endpoint: NWEndpoint { .hostPort(host: .init(address), port: NWEndpoint.Port(rawValue: Self.port)!) }

    public init?(address: String, macClientID: String) {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ip = IPv4Address(text),
              WirelessLink.isHotspotAddress(.hostPort(host: .ipv4(ip), port: 1)),
              let last = ip.rawValue.last, (2...14).contains(last),
              (1...64).contains(macClientID.utf8.count) else { return nil }
        self.address = String(describing: ip)
        self.macClientID = macClientID
    }
}
