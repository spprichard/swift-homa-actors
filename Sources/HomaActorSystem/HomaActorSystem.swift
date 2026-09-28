import Distributed
import Foundation

public enum ActorSystemFailure: Error, LocalizedError, Sendable {
    case remote(String)
    case missingActor(String)
    case timeout
    case shutdown
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .remote(let message): return "Remote error: \(message)"
        case .missingActor(let id): return "Actor not found: \(id)"
        case .timeout: return "Remote call timed out"
        case .shutdown: return "Actor system shut down"
        case .protocolError(let message): return "Protocol error: \(message)"
        }
    }
}

struct Call: Codable {
    let id: UInt64
    let actorID: String
    let target: String
    let genericTypes: [String]
    let arguments: [Data]
}

struct Reply: Codable {
    let id: UInt64
    let value: Data?
    let error: String?
}

public struct POCInvocationEncoder: DistributedTargetInvocationEncoder {
    public typealias SerializationRequirement = Codable
    var genericTypes: [String] = []
    var arguments: [Data] = []

    public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
        genericTypes.append(_mangledTypeName(type) ?? _typeName(type))
    }
    public mutating func recordArgument<Value: Codable>(_ argument: RemoteCallArgument<Value>) throws {
        arguments.append(try JSONEncoder().encode(argument.value))
    }
    public mutating func recordReturnType<Success: Codable>(_ type: Success.Type) throws {}
    public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {}
    public mutating func doneRecording() throws {}
}

public struct POCInvocationDecoder: DistributedTargetInvocationDecoder {
    public typealias SerializationRequirement = Codable
    let call: Call
    var index = 0

    public mutating func decodeGenericSubstitutions() throws -> [Any.Type] {
        try call.genericTypes.map { name in
            guard let type = _typeByName(name) else { throw ActorSystemFailure.protocolError("unknown generic type \(name)") }
            return type
        }
    }
    public mutating func decodeNextArgument<Argument: Codable>() throws -> Argument {
        guard index < call.arguments.count else { throw ActorSystemFailure.protocolError("missing argument") }
        defer { index += 1 }
        return try JSONDecoder().decode(Argument.self, from: call.arguments[index])
    }
    public mutating func decodeErrorType() throws -> Any.Type? { nil }
    public mutating func decodeReturnType() throws -> Any.Type? { nil }
}

final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Reply?
    func set(_ value: Reply) { lock.lock(); stored = value; lock.unlock() }
    func get() -> Reply? { lock.lock(); defer { lock.unlock() }; return stored }
}

public struct POCInvocationResultHandler: DistributedTargetInvocationResultHandler {
    public typealias SerializationRequirement = Codable
    let id: UInt64
    let box: ReplyBox

    public func onReturn<Success: Codable>(value: Success) async throws {
        box.set(Reply(id: id, value: try JSONEncoder().encode(value), error: nil))
    }
    public func onReturnVoid() async throws { box.set(Reply(id: id, value: nil, error: nil)) }
    public func onThrow<Err: Error>(error: Err) async throws {
        box.set(Reply(id: id, value: nil, error: String(describing: error)))
    }
}

public final class HomaActorSystem: DistributedActorSystem, @unchecked Sendable {
    public typealias ActorID = String
    public typealias InvocationEncoder = POCInvocationEncoder
    public typealias InvocationDecoder = POCInvocationDecoder
    public typealias ResultHandler = POCInvocationResultHandler
    public typealias SerializationRequirement = Codable

    private let lock = NSLock()
    private var actors: [String: any DistributedActor] = [:]
    private var assignedID: String?
    private let transport: any RPCTransport
    public let deadline: TimeInterval

    private init(transport: any RPCTransport, deadline: TimeInterval) {
        self.transport = transport
        self.deadline = deadline
        transport.onCall = { [weak self] call in
            guard let self else { return Reply(id: call.id, value: nil, error: "system shut down") }
            return await self.receive(call)
        }
    }

    private static func checkDeadline(_ deadline: TimeInterval) throws {
        guard deadline.isFinite && deadline > 0 && deadline <= 3600 else {
            throw ActorSystemFailure.protocolError("deadline must be finite and in (0, 3600] seconds")
        }
    }

    public static func listen(host: String = "127.0.0.1", port: UInt16, deadline: TimeInterval = 5) throws -> HomaActorSystem {
        try checkDeadline(deadline)
        let transport = try TCPTransport.listen(host: host, port: port)
        let system = HomaActorSystem(transport: transport, deadline: deadline)
        transport.start()
        return system
    }

    public static func connect(host: String = "127.0.0.1", port: UInt16, deadline: TimeInterval = 5) throws -> HomaActorSystem {
        try checkDeadline(deadline)
        let transport = try TCPTransport.connect(host: host, port: port)
        let system = HomaActorSystem(transport: transport, deadline: deadline)
        transport.start()
        return system
    }

    public static func listenHoma(host: String = "0.0.0.0", port: UInt16, deadline: TimeInterval = 5) throws -> HomaActorSystem {
        try checkDeadline(deadline)
        guard port > 0 && port < 32768 else {
            throw ActorSystemFailure.protocolError("Homa server port must be in 1...32767")
        }
        let transport = try HomaTransport(host: host, port: port, server: true)
        let system = HomaActorSystem(transport: transport, deadline: deadline)
        transport.start()
        return system
    }

    public static func connectHoma(host: String, port: UInt16, deadline: TimeInterval = 5) throws -> HomaActorSystem {
        try checkDeadline(deadline)
        let transport = try HomaTransport(host: host, port: port, server: false)
        let system = HomaActorSystem(transport: transport, deadline: deadline)
        transport.start()
        return system
    }

    /// Assign the static identity to the next actor constructed in this system.
    public func prepareActor(id: String) {
        lock.lock(); assignedID = id; lock.unlock()
    }

    public func assignID<Act>(_ actorType: Act.Type) -> String where Act: DistributedActor {
        lock.lock(); defer { lock.unlock() }
        let id = assignedID ?? UUID().uuidString
        assignedID = nil
        return id
    }
    public func actorReady<Act>(_ actor: Act) where Act: DistributedActor, Act.ID == String {
        lock.lock(); actors[actor.id] = actor; lock.unlock()
    }
    public func resignID(_ id: String) { lock.lock(); actors.removeValue(forKey: id); lock.unlock() }
    public func resolve<Act>(id: String, as actorType: Act.Type) throws -> Act? where Act: DistributedActor, Act.ID == String {
        lock.lock(); defer { lock.unlock() }
        return actors[id] as? Act
    }
    public func makeInvocationEncoder() -> InvocationEncoder { InvocationEncoder() }

    public func remoteCall<Act, Err, Res>(on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder, throwing: Err.Type, returning: Res.Type) async throws -> Res where Act: DistributedActor, Act.ID == String, Err: Error, Res: Codable {
        let reply = try await transport.request(actorID: actor.id, target: target.identifier, genericTypes: invocation.genericTypes, arguments: invocation.arguments, deadline: deadline)
        if let error = reply.error { throw ActorSystemFailure.remote(error) }
        guard let data = reply.value else { throw ActorSystemFailure.protocolError("missing return value") }
        return try JSONDecoder().decode(Res.self, from: data)
    }

    public func remoteCallVoid<Act, Err>(on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder, throwing: Err.Type) async throws where Act: DistributedActor, Act.ID == String, Err: Error {
        let reply = try await transport.request(actorID: actor.id, target: target.identifier, genericTypes: invocation.genericTypes, arguments: invocation.arguments, deadline: deadline)
        if let error = reply.error { throw ActorSystemFailure.remote(error) }
    }

    private func localActor(id: String) -> (any DistributedActor)? {
        lock.lock(); defer { lock.unlock() }; return actors[id]
    }

    private func receive(_ call: Call) async -> Reply {
        let actor = localActor(id: call.actorID)
        guard let actor else { return Reply(id: call.id, value: nil, error: "actor not found: \(call.actorID)") }
        let box = ReplyBox()
        var decoder = InvocationDecoder(call: call)
        do {
            try await executeDistributedTarget(on: actor, target: RemoteCallTarget(call.target), invocationDecoder: &decoder, handler: POCInvocationResultHandler(id: call.id, box: box))
            return box.get() ?? Reply(id: call.id, value: nil, error: "target did not return")
        } catch {
            return Reply(id: call.id, value: nil, error: String(describing: error))
        }
    }

    public func shutdown() {
        transport.shutdown()
        lock.lock()
        let previous = actors
        actors.removeAll()
        lock.unlock()
        withExtendedLifetime(previous) {}
    }
}
