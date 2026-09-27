import Darwin
import Foundation

/// One IPv4 address on an up, non-loopback interface.
public struct InterfaceAddress: Equatable {
    public var name: String
    public var ip: String
    public var netmask: String
    public var ipValue: UInt32    // host byte order
    public var maskValue: UInt32  // host byte order

    public var prefixLength: Int { maskValue.nonzeroBitCount }
}

/// Local IPv4 facts via getifaddrs - the only way on iOS to learn our own
/// Wi-Fi address and subnet, which the subnet sweeps and the pairing QR need.
public enum NetworkInterfaces {

    public static func ipv4() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = ifa.pointee.ifa_netmask
            else { continue }
            let ipValue = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let maskValue = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            result.append(InterfaceAddress(
                name: String(cString: ifa.pointee.ifa_name),
                ip: format(ipValue),
                netmask: format(maskValue),
                ipValue: ipValue,
                maskValue: maskValue
            ))
        }
        return result
    }

    /// The address peers on the same Wi-Fi reach us at. en0 is Wi-Fi on every
    /// iPhone and iPad; bridge100 is the Personal Hotspot network, which is a
    /// LAN too when other devices join it.
    public static func lan() -> InterfaceAddress? {
        let all = ipv4()
        return all.first { $0.name == "en0" && isPrivateLAN($0.ipValue) }
            ?? all.first { $0.name.hasPrefix("bridge") && isPrivateLAN($0.ipValue) }
            ?? all.first { $0.name.hasPrefix("en") && isPrivateLAN($0.ipValue) }
    }

    /// A Tailscale address, if the Tailscale VPN is up on this device
    /// (utun* in 100.64.0.0/10). The other platforms make the user type this;
    /// on iOS it is visible, so the app can offer it as a suggestion.
    public static func tailscale() -> String? {
        ipv4().first { $0.name.hasPrefix("utun") && isCGNAT($0.ipValue) }?.ip
    }

    /// Every IPv4 worth showing on the Me screen.
    public static func displayAddresses() -> [String] {
        var seen = Set<String>()
        return ipv4().map(\.ip).filter { seen.insert($0).inserted }
    }

    /// Hosts to sweep on our LAN, excluding the network, broadcast and our own
    /// address. Subnets wider than /24 are narrowed to the /24 around us:
    /// sweeping a /16 would be 65k probes, and home networks are /24 anyway.
    public static func sweepHosts(for iface: InterfaceAddress) -> [String] {
        let mask: UInt32 = iface.prefixLength < 24 ? 0xFFFF_FF00 : iface.maskValue
        let network = iface.ipValue & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }
        var hosts: [String] = []
        var host = network + 1
        while host < broadcast {
            if host != iface.ipValue { hosts.append(format(host)) }
            host += 1
        }
        return hosts
    }

    /// Directed broadcast address for the interface's real subnet.
    public static func directedBroadcast(for iface: InterfaceAddress) -> String {
        format((iface.ipValue & iface.maskValue) | ~iface.maskValue)
    }

    public static func format(_ value: UInt32) -> String {
        "\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    public static func parse(_ ip: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    /// RFC 1918 + link-local: addresses iOS treats as "local network" and
    /// gates behind the Local Network permission.
    public static func isPrivateLAN(_ v: UInt32) -> Bool {
        (v & 0xFF00_0000) == 0x0A00_0000 ||   // 10/8
        (v & 0xFFF0_0000) == 0xAC10_0000 ||   // 172.16/12
        (v & 0xFFFF_0000) == 0xC0A8_0000 ||   // 192.168/16
        (v & 0xFFFF_0000) == 0xA9FE_0000      // 169.254/16
    }

    public static func isCGNAT(_ v: UInt32) -> Bool {
        (v & 0xFFC0_0000) == 0x6440_0000      // 100.64/10 (Tailscale)
    }

    public static func isPrivateLAN(_ ip: String) -> Bool { parse(ip).map(isPrivateLAN) ?? false }
    public static func isTailscale(_ ip: String) -> Bool { parse(ip).map(isCGNAT) ?? false }

    /// Normalises an address string as NWEndpoint renders it: drops an
    /// IPv4-mapped IPv6 prefix and any `%scope` suffix.
    public static func normalize(_ host: String) -> String {
        var h = host
        if let percent = h.firstIndex(of: "%") { h = String(h[..<percent]) }
        if h.lowercased().hasPrefix("::ffff:"), parse(String(h.dropFirst(7))) != nil { h = String(h.dropFirst(7)) }
        return h
    }
}
