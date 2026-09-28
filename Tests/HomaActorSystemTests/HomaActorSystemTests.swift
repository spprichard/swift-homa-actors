import Distributed
import Foundation
import XCTest
@testable import HomaActorSystem

distributed actor TestService {
    typealias ActorSystem = HomaActorSystem
    distributed func double(_ number: Int) -> Int { number * 2 }
    distributed func fail() throws -> Int { throw TestError.expected }
    distributed func pause(_ milliseconds: UInt64) async -> Int {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        return 1
    }
    distributed func ping() {}
}
enum TestError: Error { case expected }

final class HomaActorSystemTests: XCTestCase {
    private func pair(deadline: TimeInterval = 2) throws -> (HomaActorSystem, HomaActorSystem, TestService) {
        for port in 39000..<39100 {
            guard let server = try? HomaActorSystem.listen(port: UInt16(port), deadline: deadline) else { continue }
            server.prepareActor(id: "test")
            _ = TestService(actorSystem: server)
            let client = try HomaActorSystem.connect(port: UInt16(port), deadline: deadline)
            let proxy = try TestService.resolve(id: "test", using: client)
            return (server, client, proxy)
        }
        throw ActorSystemFailure.protocolError("no free test port")
    }

    func testConcurrentCallsAndVoid() async throws {
        let (server, client, proxy) = try pair()
        defer { client.shutdown(); server.shutdown() }
        try await proxy.ping()
        let values = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<100 { group.addTask { try await proxy.double(i) } }
            var values: [Int] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(values.sorted(), (0..<100).map { $0 * 2 })
    }

    func testRemoteErrorAndMissingActor() async throws {
        let (server, client, proxy) = try pair()
        defer { client.shutdown(); server.shutdown() }
        do { _ = try await proxy.fail(); XCTFail("expected remote error") }
        catch { XCTAssertTrue(String(describing: error).contains("expected")) }
        let missing = try TestService.resolve(id: "missing", using: client)
        do { _ = try await missing.double(1); XCTFail("expected missing actor") }
        catch { XCTAssertTrue(String(describing: error).contains("actor not found")) }
    }

    func testTimeoutAndShutdown() async throws {
        let (server, client, proxy) = try pair(deadline: 0.05)
        defer { client.shutdown(); server.shutdown() }
        do { _ = try await proxy.pause(200); XCTFail("expected timeout") }
        catch { XCTAssertTrue(String(describing: error).contains("timeout") || String(describing: error).contains("timed out")) }
        try await Task.sleep(nanoseconds: 250_000_000)
        let afterLateReply = try await proxy.pause(0)
        XCTAssertEqual(afterLateReply, 1)
        client.shutdown()
        do { _ = try await proxy.double(3); XCTFail("expected shutdown") }
        catch { XCTAssertTrue(String(describing: error).contains("shutdown") || String(describing: error).contains("shut down")) }
    }

    func testCancellationAndPendingShutdown() async throws {
        let (server, client, proxy) = try pair(deadline: 5)
        defer { client.shutdown(); server.shutdown() }
        let cancelled = Task { try await proxy.pause(1000) }
        try await Task.sleep(nanoseconds: 20_000_000)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("expected cancellation") }
        catch is CancellationError {}

        let pending = Task { try await proxy.pause(1000) }
        try await Task.sleep(nanoseconds: 20_000_000)
        client.shutdown()
        do { _ = try await pending.value; XCTFail("expected shutdown") }
        catch { XCTAssertTrue(String(describing: error).contains("shutdown") || String(describing: error).contains("shut down")) }
    }

    func testServerDisconnectFailsPendingCall() async throws {
        let (server, client, proxy) = try pair(deadline: 5)
        defer { client.shutdown(); server.shutdown() }
        let pending = Task { try await proxy.pause(1000) }
        try await Task.sleep(nanoseconds: 20_000_000)
        server.shutdown()
        do { _ = try await pending.value; XCTFail("expected disconnect") }
        catch { XCTAssertTrue(String(describing: error).contains("shutdown") || String(describing: error).contains("shut down")) }
    }

    func testLateRepliesAcrossConnectionChurn() async throws {
        var selected: (HomaActorSystem, UInt16)?
        for port in 39100..<39200 {
            if let server = try? HomaActorSystem.listen(port: UInt16(port), deadline: 0.02) {
                selected = (server, UInt16(port))
                break
            }
        }
        guard let (server, port) = selected else { throw ActorSystemFailure.protocolError("no free test port") }
        defer { server.shutdown() }
        server.prepareActor(id: "test")
        _ = TestService(actorSystem: server)
        let firstClient = try HomaActorSystem.connect(port: port, deadline: 0.02)
        let firstProxy = try TestService.resolve(id: "test", using: firstClient)
        do { _ = try await firstProxy.pause(100); XCTFail("expected timeout") }
        catch { XCTAssertTrue(String(describing: error).contains("timeout") || String(describing: error).contains("timed out")) }
        firstClient.shutdown()
        let secondClient = try HomaActorSystem.connect(port: port, deadline: 1)
        defer { secondClient.shutdown() }
        let secondProxy = try TestService.resolve(id: "test", using: secondClient)
        let value = try await secondProxy.double(42)
        XCTAssertEqual(value, 84)
        // The old reply completes while the new connection is live.
        try await Task.sleep(nanoseconds: 150_000_000)
        let next = try await secondProxy.double(21)
        XCTAssertEqual(next, 42)
    }

    func testHomaUnavailableOnMac() throws {
        do { _ = try HomaActorSystem.listenHoma(port: 39117); XCTFail("expected invalid Homa server port") }
        catch { XCTAssertTrue(String(describing: error).contains("1...32767")) }
        #if os(macOS)
        XCTAssertThrowsError(try HomaActorSystem.connectHoma(host: "127.0.0.1", port: 34567))
        #endif
    }

    func testInvalidDeadlinesFailBeforeOpeningSocket() throws {
        for deadline in [0.0, -1.0, .infinity, .nan, 3601.0] {
            XCTAssertThrowsError(try HomaActorSystem.listen(port: 0, deadline: deadline))
            XCTAssertThrowsError(try HomaActorSystem.connect(port: 0, deadline: deadline))
            XCTAssertThrowsError(try HomaActorSystem.listenHoma(port: 7317, deadline: deadline))
            XCTAssertThrowsError(try HomaActorSystem.connectHoma(host: "127.0.0.1", port: 7317, deadline: deadline))
        }
    }
}
