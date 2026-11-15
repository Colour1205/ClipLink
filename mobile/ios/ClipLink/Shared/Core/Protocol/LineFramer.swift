import Foundation

/// Newline framing over a byte stream, for the whole life of a connection
/// (handshake and session alike). Windows writes `\r\n` (StreamWriter on
/// Windows), Android and HarmonyOS write `\n`; a trailing `\r` is stripped so
/// both read the same. Empty lines are skipped, as every peer does.
///
/// Unlike StreamReader/BufferedReader this never buffers an unbounded line
/// (docs/security.md finding #3):
/// - until the first line (always the handshake) arrives, at most
///   `firstLineMaxBytes` may be buffered - an unauthenticated stranger can't
///   pin more than that per connection; exceeding it throws;
/// - after that, a line over `maxLineBytes` is SKIPPED, not fatal: the bytes
///   are dropped as they arrive and framing resumes at the next newline. The
///   other ports impose no cap and resend the same history batch on every
///   reconnect, so tearing the link down would just loop forever.
public struct LineFramer {
    public let maxLineBytes: Int
    public let firstLineMaxBytes: Int
    /// Lines dropped for exceeding `maxLineBytes`.
    public private(set) var droppedLines = 0

    private var buffer = Data()
    /// How far into `buffer` has already been searched for a newline, so a
    /// multi-megabyte line arriving in pieces isn't rescanned from the start.
    private var scanned = 0
    private var producedLine = false
    private var discarding = false

    public init(maxLineBytes: Int, firstLineMaxBytes: Int = 64 * 1024) {
        self.maxLineBytes = maxLineBytes
        self.firstLineMaxBytes = min(firstLineMaxBytes, maxLineBytes)
    }

    public var bufferedByteCount: Int { buffer.count }

    /// The lines `data` completes, each a slice of the buffer they arrived in -
    /// not a copy: a history line can be tens of megabytes, and copying it out
    /// (then keeping the grown buffer) held it two or three times over. The
    /// part after the last newline is copied into a buffer of its own, so the
    /// slices share nothing that is written to again.
    public mutating func append(_ data: Data) throws -> [Data] {
        var incoming = data
        if discarding {
            guard let newline = incoming.firstIndex(of: 0x0A) else { return [] }
            incoming = incoming.suffix(from: newline + 1)
            discarding = false
            droppedLines += 1
        }
        buffer.append(incoming)
        var lines: [Data] = []
        // Where the part not yet framed starts.
        var head = buffer.startIndex
        while true {
            let cap = producedLine ? maxLineBytes : firstLineMaxBytes
            let searchStart = head + scanned
            guard let newline = buffer[searchStart..<buffer.endIndex].firstIndex(of: 0x0A) else {
                if head != buffer.startIndex { buffer = Data(buffer[head..<buffer.endIndex]) }
                scanned = buffer.count
                if buffer.count > cap {
                    guard producedLine else { throw WireError.lineTooLong(cap) }
                    // Drop what we have and everything up to the next newline.
                    buffer = Data()
                    scanned = 0
                    discarding = true
                }
                return lines
            }
            var end = newline
            if end > head, buffer[end - 1] == 0x0D { end -= 1 }
            let length = end - head
            let line = buffer[head..<end]
            head = newline + 1
            scanned = 0
            if length > cap {
                guard producedLine else {
                    buffer = Data(buffer[head..<buffer.endIndex])
                    throw WireError.lineTooLong(cap)
                }
                droppedLines += 1
                continue
            }
            if length > 0 {
                producedLine = true
                lines.append(line)
            }
        }
    }
}
