import Foundation
import Testing
@testable import FocusPilotCore

/// A fresh short directory: socket paths must fit in 104 bytes, which the
/// usual temporary directory does not leave room for.
func makeShortDirectory() throws -> URL {
    let url = URL(fileURLWithPath: "/tmp/fp-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Command socket")
final class CommandSocketTests {
    private let directory: URL
    private var path: String { directory.appending(path: "cli.sock").path }
    private let scope = HerdrTaskScope(now: nil, projectTitle: "NLP report", tasks: [])

    init() throws {
        directory = try makeShortDirectory()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func server(answer: CommandResponse? = nil) -> CommandSocketServer {
        let answer = answer ?? .tasks(scope)
        return CommandSocketServer(path: path) { _ in answer }
    }

    @Test func aRequestGetsTheHandlersAnswer() async throws {
        let server = server()
        try server.start()
        defer { server.stop() }

        #expect(try CommandSocketClient(path: path).send(.tasks(nil)) == .tasks(scope))
    }

    // The Chrome host tells the blocked page whether FocusPilot is running.
    @Test func listeningSaysWhetherTheAppIsRunning() async throws {
        #expect(!CommandSocketClient(path: path).isListening())
        let server = server()
        try server.start()
        defer { server.stop() }

        #expect(CommandSocketClient(path: path).isListening())
    }

    @Test func theHandlerReceivesTheRequestIntact() async throws {
        let received = Received()
        let server = CommandSocketServer(path: path) { request in
            await received.set(request)
            return .refused("ok")
        }
        try server.start()
        defer { server.stop() }
        let add = CommandRequest.add(herdrAdd("Reply to co-advisor by fri 23:59"))

        _ = try CommandSocketClient(path: path).send(add)

        #expect(await received.request == add)
    }

    @Test func theSocketIsReadableOnlyByTheOwner() throws {
        let server = server()
        try server.start()
        defer { server.stop() }

        let mode = try #require(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        #expect(mode & 0o777 == 0o600)
    }

    @Test func withNoAppTheClientReportsNotRunning() {
        #expect(throws: CommandSocketClient.Failure.notRunning) {
            try CommandSocketClient(path: path).send(.tasks(nil))
        }
    }

    @Test func aSocketLeftByACrashIsReplaced() throws {
        try makeStaleSocket(at: path)
        #expect(throws: CommandSocketClient.Failure.notRunning) {
            try CommandSocketClient(path: path).send(.tasks(nil))
        }

        let restarted = server()
        try restarted.start()
        defer { restarted.stop() }
        #expect(try CommandSocketClient(path: path).send(.tasks(nil)) == .tasks(scope))
    }

    // A second FocusPilot copy used to take the path and leave it dead on
    // quit, so the running app got no reports (#42).
    @Test func aSecondCopyLeavesTheRunningOneInPlace() throws {
        let running = server()
        try running.start()
        defer { running.stop() }
        let second = server(answer: .refused("second copy"))

        #expect(throws: CommandSocketServer.Failure.alreadyRunning) { try second.start() }
        second.stop()

        #expect(try CommandSocketClient(path: path).send(.tasks(nil)) == .tasks(scope))
    }

    @Test func stoppingLeavesASocketThatIsNotItsOwn() throws {
        let first = server(answer: .refused("first"))
        try first.start()
        // Its file gone (removed by hand, say) and another copy listening there.
        unlink(path)
        let second = server()
        try second.start()
        defer { second.stop() }

        first.stop()

        #expect(try CommandSocketClient(path: path).send(.tasks(nil)) == .tasks(scope))
    }

    @Test func connectionsBeyondTheCapAreTurnedAway() async throws {
        let gate = Gate()
        let server = CommandSocketServer(path: path, maxConnections: 2) { _ in
            await gate.wait()
            return .refused("released")
        }
        try server.start()
        defer { server.stop() }
        let path = path
        // Blocking clients run on dispatch threads, never on the concurrency
        // pool the server's handlers need.
        let held = (0..<2).map { _ in
            Task {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async { continuation.resume(returning: try? CommandSocketClient(path: path).send(.tasks(nil))) }
                }
            }
        }
        while server.openConnectionCount < 2 { try await Task.sleep(for: .milliseconds(20)) }

        let start = ContinuousClock.now
        #expect(throws: CommandSocketClient.Failure.noReply) { try CommandSocketClient(path: path).send(.tasks(nil)) }
        #expect(ContinuousClock.now - start < .seconds(2))

        await gate.open()
        for task in held { #expect(await task.value == .refused("released")) }
        #expect(try CommandSocketClient(path: path).send(.tasks(nil)) == .refused("released"))
    }

    @Test func stoppingRemovesTheSocket() throws {
        let server = server()
        try server.start()
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func aPathTooLongForASocketIsRejected() {
        let long = "/tmp/" + String(repeating: "x", count: 120)
        #expect(throws: CommandSocketServer.Failure.pathTooLong) { try CommandSocketServer(path: long) { _ in .refused("") }.start() }
        #expect(throws: CommandSocketClient.Failure.pathTooLong) { try CommandSocketClient(path: long).send(.tasks(nil)) }
    }
}

actor Received {
    var request: CommandRequest?
    func set(_ request: CommandRequest) { self.request = request }
}

/// A socket file nothing listens on, as a crashed app leaves behind.
func makeStaleSocket(at path: String) throws {
    var address = try #require(UnixSocket.address(path))
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(UnixSocket.withAddress(&address) { bind(descriptor, $0, $1) } == 0)
    close(descriptor)
}

/// Holds handlers until opened.
actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}
