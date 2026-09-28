import CHoma
import Foundation

/// Linux Homa transport. This path must be exercised with a matching HomaModule
/// kernel module; macOS initialization fails with ENOTSUP.
final class HomaTransport: RPCTransport, @unchecked Sendable {
    private let socket: OpaquePointer
    private let server: Bool
    private let lock = NSLock()
    private var stopped = false
    private var nextID: UInt64 = 1
    private var pending: [UInt64: PendingCall] = [:]
    private let maxPending = 1024
    var onCall: ((Call) async -> Reply)?

    init(host: String, port: UInt16, server: Bool) throws {
        guard let socket = host.withCString({ choma_open($0, port, server ? 1 : 0) }) else {
            throw ActorSystemFailure.protocolError("Homa socket unavailable (errno \(errno)): \(String(cString: strerror(errno)))")
        }
        self.socket = socket
        self.server = server
    }

    deinit { choma_close(socket) }

    func start() { DispatchQueue.global().async { [self] in receiveLoop() } }

    private func receiveLoop() {
        while true {
            var raw: UnsafeMutableRawPointer?
            var length = 0
            var rpcID: UInt64 = 0
            var cookie: UInt64 = 0
            var peer = [UInt8](repeating: 0, count: 128)
            var peerLength = UInt32(peer.count)
            let status = peer.withUnsafeMutableBytes { buffer in
                choma_receive(socket, &raw, &length, &rpcID, &cookie, buffer.baseAddress, &peerLength)
            }
            if status < 0 {
                let code = errno
                if code == EINTR { continue }
                if cookie != 0 { fail(id: cookie, error: ActorSystemFailure.remote("Homa receive error \(code)")); continue }
                lock.lock(); let done = stopped; lock.unlock()
                if done { return }
                shutdown()
                return
            }
            guard let raw else { continue }
            let bytes = Data(bytes: raw, count: length)
            choma_free(raw)
            if rpcID & 1 == 0 {
                if let reply = try? JSONDecoder().decode(Reply.self, from: bytes) {
                    // The kernel cookie identifies the application call even when
                    // Homa RPC IDs differ between peers.
                    let id = cookie == 0 ? reply.id : cookie
                    lock.lock(); let call = pending.removeValue(forKey: id); lock.unlock()
                    call?.timeout?.cancel()
                    call?.continuation.resume(returning: reply)
                }
            } else if let call = try? JSONDecoder().decode(Call.self, from: bytes) {
                let address = Data(peer.prefix(Int(peerLength)))
                Task { [self] in
                    let reply = await onCall?(call) ?? Reply(id: call.id, value: nil, error: "system unavailable")
                    if let response = try? JSONEncoder().encode(reply) {
                        DispatchQueue.global().async { [self] in
                            _ = response.withUnsafeBytes { responseBuffer in
                                address.withUnsafeBytes { addressBuffer in
                                    choma_send(socket, responseBuffer.baseAddress, response.count,
                                               rpcID, 0, addressBuffer.baseAddress, UInt32(address.count))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func request(actorID: String, target: String, genericTypes: [String], arguments: [Data], deadline: TimeInterval) async throws -> Reply {
        guard !server else { throw ActorSystemFailure.protocolError("server system cannot initiate calls") }
        let token = CancellationToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !stopped else { lock.unlock(); continuation.resume(throwing: ActorSystemFailure.shutdown); return }
                guard pending.count < maxPending else { lock.unlock(); continuation.resume(throwing: ActorSystemFailure.protocolError("too many pending calls")); return }
                let id = nextID
                nextID &+= 1
                let pendingCall = PendingCall(continuation)
                pending[id] = pendingCall
                lock.unlock()
                token.install { [self] in fail(id: id, error: CancellationError()) }
                let timeout = Task { [self] in
                    let nanos = UInt64(max(0, deadline) * 1_000_000_000)
                    do { try await Task.sleep(nanoseconds: nanos) } catch { return }
                    fail(id: id, error: ActorSystemFailure.timeout)
                }
                lock.lock()
                if pending[id] === pendingCall { pendingCall.timeout = timeout }
                else { timeout.cancel() }
                lock.unlock()
                let call = Call(id: id, actorID: actorID, target: target, genericTypes: genericTypes, arguments: arguments)
                DispatchQueue.global().async { [self] in
                    do {
                        let bytes = try JSONEncoder().encode(call)
                        let status = bytes.withUnsafeBytes { buffer in
                            choma_send(socket, buffer.baseAddress, bytes.count, 0, id, nil, 0)
                        }
                        if status < 0 { fail(id: id, error: ActorSystemFailure.protocolError("Homa send error \(errno)")) }
                    } catch { fail(id: id, error: error) }
                }
            }
        } onCancel: { token.cancel() }
    }

    private func fail(id: UInt64, error: Error) {
        lock.lock(); let call = pending.removeValue(forKey: id); lock.unlock()
        call?.timeout?.cancel()
        call?.continuation.resume(throwing: error)
    }

    func shutdown() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let calls = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        choma_shutdown(socket)
        calls.forEach { $0.timeout?.cancel(); $0.continuation.resume(throwing: ActorSystemFailure.shutdown) }
    }
}
