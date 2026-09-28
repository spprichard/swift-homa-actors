import Distributed
import Foundation
import HomaActorSystem

distributed actor DemoService {
    typealias ActorSystem = HomaActorSystem

    distributed func echo(_ text: String) -> String { text }
    distributed func add(_ a: Int, _ b: Int) -> Int { a + b }
    distributed func fail() throws -> String { throw DemoError.deliberate }
    distributed func acknowledge() {}
    distributed func wait(milliseconds: UInt64) async -> String {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        return "done"
    }
}

enum DemoError: Error { case deliberate }

@main
struct Main {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3, let port = UInt16(args[2]) else {
            fputs("usage: actor-demo server|client|server-homa|client-homa PORT [HOST]\n", stderr)
            exit(2)
        }
        let host = args.count > 3 ? args[3] : "127.0.0.1"
        if args[1] == "server" || args[1] == "server-homa" {
            let system = try args[1] == "server-homa"
                ? HomaActorSystem.listenHoma(host: host, port: port)
                : HomaActorSystem.listen(host: host, port: port)
            system.prepareActor(id: "demo")
            let service = DemoService(actorSystem: system)
            print("READY \(service.id)")
            fflush(stdout)
            while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
        } else if args[1] == "client" || args[1] == "client-homa" {
            let system = try args[1] == "client-homa"
                ? HomaActorSystem.connectHoma(host: host, port: port)
                : HomaActorSystem.connect(host: host, port: port)
            defer { system.shutdown() }
            let service = try DemoService.resolve(id: "demo", using: system)
            print("echo: \(try await service.echo("hello"))")
            print("add: \(try await service.add(20, 22))")
            try await service.acknowledge()
            print("acknowledge: ok")
            do { _ = try await service.fail(); print("unexpected success"); exit(1) }
            catch { print("expected remote error: \(error)") }
            let values = try await withThrowingTaskGroup(of: Int.self) { group in
                for i in 0..<32 { group.addTask { try await service.add(i, i) } }
                var result: [Int] = []
                for try await value in group { result.append(value) }
                return result
            }
            let expected = (0..<32).map { $0 * 2 }
            guard values.sorted() == expected else { fatalError("correlation mismatch") }
            print("concurrent calls: 32 matched")
        } else {
            fputs("unknown command\n", stderr)
            exit(2)
        }
    }
}
