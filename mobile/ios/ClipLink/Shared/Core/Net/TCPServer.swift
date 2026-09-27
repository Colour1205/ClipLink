import Foundation
import Network

/// The TCP listener peers dial into. Foreground-only on iOS: a suspended
/// app's listening socket is defuncted by the system (TN2277), so the engine
/// tears this down on background and builds a fresh one on foreground.
final class TCPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cliplink.listener")

    /// Unstarted connections, on the listener's queue.
    var onConnection: ((NWConnection) -> Void)?
    /// `true` once listening, `false` + error when it failed for good.
    var onState: ((Bool, Error?) -> Void)?

    init(port: UInt16) throws {
        let params = NWParameters(tls: nil, tcp: {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 20
            tcp.keepaliveInterval = 10
            tcp.keepaliveCount = 5
            return tcp
        }())
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw WireError.malformed("port") }
        // IPv4 only: every peer dials IPv4, and it keeps remote endpoints as
        // plain dotted quads (never ::ffff:a.b.c.d, whose colons must never
        // reach a beacon or trust-store address).
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: nwPort)
        listener = try NWListener(using: params)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.onConnection?(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onState?(true, nil)
            case .failed(let error): self?.onState?(false, error)
            case .waiting(let error): self?.onState?(false, error)
            default: break
            }
        }
        listener.start(queue: queue)
    }

    deinit { stop() }

    func stop() {
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
        listener.cancel()
    }
}
