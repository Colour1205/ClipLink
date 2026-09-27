import Darwin
import Foundation

/// The discovery socket: one BSD UDP socket bound to 0.0.0.0:49000 that sends
/// broadcast and unicast beacons and receives any beacon addressed to it.
///
/// BSD sockets rather than Network.framework because broadcast needs them
/// (Apple DTS, "Broadcasts and Multicasts, Hints and Tips"), and because a
/// plain `sendto` errno is the clearest signal we get about what iOS is
/// blocking: broadcast without the multicast entitlement fails with
/// EHOSTUNREACH while unicast to the same LAN still works; unicast to a LAN
/// address failing too means Local Network access is off.
final class UDPSocket {
    private let fd: Int32
    private let source: DispatchSourceRead
    private var closed = false

    /// Called on `queue` with the datagram and its sender's IPv4 address.
    var onDatagram: ((Data, String) -> Void)?

    init(port: UInt16, queue: DispatchQueue) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EADDRINUSE)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    deinit { close() }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !closed {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &fromLen)
                    }
                }
            }
            if n <= 0 { return } // EAGAIN (drained) or an error; the source fires again on new data
            let sender = NetworkInterfaces.format(UInt32(bigEndian: from.sin_addr.s_addr))
            onDatagram?(Data(buffer[0..<n]), sender)
        }
    }

    /// Returns 0 on success, otherwise the errno.
    @discardableResult
    func send(_ data: Data, to ip: String, port: UInt16) -> Int32 {
        guard !closed, let value = NetworkInterfaces.parse(ip) else { return EINVAL }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = value.bigEndian
        let sent = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent < 0 ? errno : 0
    }

    func close() {
        guard !closed else { return }
        closed = true
        source.cancel()
    }
}
