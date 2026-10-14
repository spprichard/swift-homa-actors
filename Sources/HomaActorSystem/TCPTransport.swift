import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private let maxFrame = 2_000_000

private func socketError(_ operation: String) -> ActorSystemFailure {
    ActorSystemFailure.protocolError("\(operation): \(String(cString: strerror(errno)))")
}

private func openSocket(host: String, port: UInt16, server: Bool) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    #if canImport(Darwin)
    hints.ai_socktype = SOCK_STREAM
    #else
    hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
    #endif
    hints.ai_protocol = Int32(IPPROTO_TCP)
    hints.ai_flags = server ? AI_PASSIVE : 0
    var result: UnsafeMutablePointer<addrinfo>?
    let code = getaddrinfo(host, String(port), &hints, &result)
    guard code == 0, let first = result else { throw ActorSystemFailure.protocolError("getaddrinfo: \(String(cString: gai_strerror(code)))") }
    defer { freeaddrinfo(first) }
    let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
    guard fd >= 0 else { throw socketError("socket") }
    do {
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif
        if server {
            guard bind(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else { throw socketError("bind") }
            guard listen(fd, 64) == 0 else { throw socketError("listen") }
        } else {
            guard DarwinOrGlibcConnect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else { throw socketError("connect") }
        }
        return fd
    } catch {
        _ = close(fd)
        throw error
    }
}

private func DarwinOrGlibcConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.connect(fd, address, length)
    #else
    return Glibc.connect(fd, address, length)
    #endif
}

private func readExact(_ fd: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    let readCount = data.withUnsafeMutableBytes { buffer -> Int in
        guard let base = buffer.baseAddress else { return 0 }
        var offset = 0
        while offset < count {
            let n = recv(fd, base.advanced(by: offset), count - offset, 0)
            if n == 0 { return -1 }
            if n < 0 {
                if errno == EINTR { continue }
                return -1
            }
            offset += n
        }
        return offset
    }
    guard readCount == count else { throw ActorSystemFailure.shutdown }
    return data
}

private func writeExact(_ fd: Int32, data: Data) throws {
    let sent = data.withUnsafeBytes { buffer -> Int in
        guard let base = buffer.baseAddress else { return 0 }
        var offset = 0
        while offset < buffer.count {
            #if canImport(Darwin)
            let n = send(fd, base.advanced(by: offset), buffer.count - offset, 0)
            #else
            let n = send(fd, base.advanced(by: offset), buffer.count - offset, Int32(MSG_NOSIGNAL))
            #endif
            if n < 0 {
                if errno == EINTR { continue }
                return -1
            }
            offset += n
        }
        return offset
    }
    guard sent == data.count else { throw socketError("send") }
}

private final class Connection: @unchecked Sendable {
    let fd: Int32
    private let writeLock = NSLock()
    private let closeLock = NSLock()
    private var closed = false
    init(_ fd: Int32) { self.fd = fd }
    func readFrame() throws -> Data {
        let header = try readExact(fd, count: 4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0 && length <= maxFrame else { throw ActorSystemFailure.protocolError("invalid frame length \(length)") }
        return try readExact(fd, count: Int(length))
    }
    func writeFrame(_ data: Data) throws {
        guard data.count > 0 && data.count <= maxFrame else { throw ActorSystemFailure.protocolError("frame too large") }
        var header = Data()
        let length = UInt32(data.count)
        header.append(UInt8((length >> 24) & 0xff))
        header.append(UInt8((length >> 16) & 0xff))
        header.append(UInt8((length >> 8) & 0xff))
        header.append(UInt8(length & 0xff))
        writeLock.lock(); defer { writeLock.unlock() }
        closeLock.lock(); let isClosed = closed; closeLock.unlock()
        guard !isClosed else { throw ActorSystemFailure.shutdown }
        try writeExact(fd, data: header)
        try writeExact(fd, data: data)
    }
    func shutdown() {
        closeLock.lock()
        guard !closed else { closeLock.unlock(); return }
        closed = true
        _ = DarwinOrGlibcShutdown(fd)
        closeLock.unlock()
    }
    deinit { _ = close(fd) }
}

final class PendingCall {
    let continuation: CheckedContinuation<Reply, Error>
    var timeout: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<Reply, Error>) { self.continuation = continuation }
}

final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    private var cancelled = false
    func install(_ action: @escaping () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); action(); return }
        self.action = action
        lock.unlock()
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let action = self.action
        lock.unlock()
        action?()
    }
}

private func DarwinOrGlibcShutdown(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.shutdown(fd, SHUT_RDWR)
    #else
    return Glibc.shutdown(fd, Int32(SHUT_RDWR))
    #endif
}

protocol RPCTransport: AnyObject {
    var onCall: ((Call) async -> Reply)? { get set }
    func start()
    func request(actorID: String, target: String, genericTypes: [String], arguments: [Data], deadline: TimeInterval) async throws -> Reply
    func shutdown()
}

final class TCPTransport: RPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UInt64: PendingCall] = [:]
    private let maxPending = 1024
    private var nextID: UInt64 = 1
    private var stopped = false
    private let listener: Int32?
    private let client: Connection?
    private var accepted: [Connection] = []
    var onCall: ((Call) async -> Reply)?

    private init(listener: Int32?, client: Connection?) { self.listener = listener; self.client = client }
    static func listen(host: String, port: UInt16) throws -> TCPTransport { try TCPTransport(listener: openSocket(host: host, port: port, server: true), client: nil) }
    static func connect(host: String, port: UInt16) throws -> TCPTransport { try TCPTransport(listener: nil, client: Connection(openSocket(host: host, port: port, server: false))) }

    func start() {
        if let listener {
            DispatchQueue.global().async { [self] in
                while true {
                    let fd = accept(listener, nil, nil)
                    if fd < 0 { return }
                    let connection = Connection(fd)
                    lock.lock()
                    if stopped { lock.unlock(); connection.shutdown(); return }
                    accepted.append(connection)
                    lock.unlock()
                    DispatchQueue.global().async { self.serve(connection) }
                }
            }
        } else if let client {
            DispatchQueue.global().async { self.receiveReplies(client) }
        }
    }

    private func serve(_ connection: Connection) {
        while let frame = try? connection.readFrame() {
            guard let call = try? JSONDecoder().decode(Call.self, from: frame) else { break }
            Task { [self] in
                let reply = await onCall?(call) ?? Reply(id: call.id, value: nil, error: "system unavailable")
                if let bytes = try? JSONEncoder().encode(reply) {
                    DispatchQueue.global().async { try? connection.writeFrame(bytes) }
                }
            }
        }
        connection.shutdown()
        lock.lock(); accepted.removeAll { $0 === connection }; lock.unlock()
    }

    private func receiveReplies(_ connection: Connection) {
        while let frame = try? connection.readFrame() {
            guard let reply = try? JSONDecoder().decode(Reply.self, from: frame) else { break }
            lock.lock(); let call = pending.removeValue(forKey: reply.id); lock.unlock()
            call?.timeout?.cancel()
            call?.continuation.resume(returning: reply)
        }
        shutdown()
    }

    func request(actorID: String, target: String, genericTypes: [String], arguments: [Data], deadline: TimeInterval) async throws -> Reply {
        guard let client else { throw ActorSystemFailure.protocolError("server system cannot initiate calls") }
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
                    do { try await Task.sleep(nanoseconds: nanos) }
                    catch { return }
                    fail(id: id, error: ActorSystemFailure.timeout)
                }
                lock.lock()
                if pending[id] === pendingCall { pendingCall.timeout = timeout }
                else { timeout.cancel() }
                lock.unlock()
                let call = Call(id: id, actorID: actorID, target: target, genericTypes: genericTypes, arguments: arguments)
                DispatchQueue.global().async { [self] in
                    do { try client.writeFrame(JSONEncoder().encode(call)) }
                    catch { fail(id: id, error: error) }
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
        let connections = accepted
        accepted.removeAll()
        lock.unlock()
        if let listener { _ = DarwinOrGlibcShutdown(listener); _ = close(listener) }
        client?.shutdown()
        connections.forEach { $0.shutdown() }
        calls.forEach { $0.timeout?.cancel(); $0.continuation.resume(throwing: ActorSystemFailure.shutdown) }
    }
}
