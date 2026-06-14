import Darwin
import Foundation

/// Minimal UDP datagram transport for call media: sends encrypted voice packets to a Telegram
/// reflector (`host:port` taken from `callStateReady.servers`) and receives the peer's packets.
/// Kept small and dependency-free so the full media pipeline is loopback-testable in-process —
/// the headless test sends to `127.0.0.1` on the bound port and reads its own datagram back.
///
/// The live engine runs `startReceiving` on a background thread; tests use `receiveOnce`.
final class CallUDPTransport: @unchecked Sendable {
    enum TransportError: Error { case socketCreationFailed, bindFailed, sendFailed }

    private let fd: Int32
    private var closed = false
    private var running = false
    private var receiveThread: Thread?
    /// Signaled when the background receive loop exits, so `close()` can join it.
    private let receiveStopped = DispatchSemaphore(value: 0)
    private var hasReceiveThread = false

    init() throws {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw TransportError.socketCreationFailed }
    }

    deinit { close() }

    /// Binds to a local UDP port (0 = ephemeral) and returns the actual bound port.
    @discardableResult
    func bind(toPort port: UInt16 = 0) throws -> UInt16 {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = 0  // INADDR_ANY
        addr.sin_port = port.bigEndian
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw TransportError.bindFailed }

        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        return UInt16(bigEndian: local.sin_port)
    }

    /// Sends one datagram. Non-blocking (`MSG_DONTWAIT`) so it can be safely called from the
    /// real-time audio capture thread: if the kernel send buffer is momentarily full under
    /// congestion the frame is dropped (correct for realtime voice) rather than stalling audio.
    func send(_ data: [UInt8], host: String, port: UInt16) throws {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        _ = host.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        let sent = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, data.count, Int32(MSG_DONTWAIT), $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent == data.count { return }
        if sent < 0 && (errno == EWOULDBLOCK || errno == EAGAIN) { return }  // buffer full: drop this frame
        throw TransportError.sendFailed
    }

    /// Blocking receive with a timeout (used by tests). Returns nil on timeout/error.
    func receiveOnce(timeoutMilliseconds: Int) -> [UInt8]? {
        var tv = timeval(tv_sec: timeoutMilliseconds / 1000,
                         tv_usec: Int32((timeoutMilliseconds % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 2048)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        return Array(buffer.prefix(count))
    }

    /// Background receive loop for the live engine; calls `handler` per datagram until `close()`.
    /// Uses a receive timeout so the loop polls `running` and exits promptly on `close()` instead
    /// of relying on `close(fd)` to interrupt a blocked `recv` (which POSIX does not guarantee).
    func startReceiving(_ handler: @escaping @Sendable ([UInt8]) -> Void) {
        running = true
        hasReceiveThread = true
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)  // 200 ms poll interval
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let fd = self.fd
        let stopped = receiveStopped
        let isRunning: @Sendable () -> Bool = { [weak self] in self?.running ?? false }
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 2048)
            while isRunning() {
                let count = recv(fd, &buffer, buffer.count, 0)
                if count > 0 {
                    handler(Array(buffer.prefix(count)))
                } else if count < 0 && (errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR) {
                    continue  // timeout / interrupt → re-check running
                } else {
                    break  // socket closed or fatal error
                }
            }
            stopped.signal()
        }
        thread.name = "me.giannak.nick.cocogram.call.udp"
        receiveThread = thread
        thread.start()
    }

    func close() {
        guard !closed else { return }
        closed = true
        running = false
        shutdown(fd, SHUT_RDWR)  // wake a blocked recv promptly
        // Join the receive thread (bounded) before closing the fd, so no callback can fire after
        // close() returns and the fd is never closed out from under an in-flight recv.
        if hasReceiveThread {
            _ = receiveStopped.wait(timeout: .now() + 1.0)
        }
        Darwin.close(fd)
    }
}
