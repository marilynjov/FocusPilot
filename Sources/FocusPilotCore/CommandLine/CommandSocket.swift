import Darwin
import Foundation

/// The app's end of the focuspilot CLI connection: a Unix domain socket that
/// only the owner can reach. Each connection carries one JSON request line
/// and gets one JSON response line.
///
/// Three things keep other users out: the socket's directory is 0700, the
/// socket itself is 0600, and each connection's peer must run as the same
/// user as the app.
public final class CommandSocketServer: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case pathTooLong
        case couldNotListen(errno: Int32)
        /// Another FocusPilot copy answers on the path; it keeps it.
        case alreadyRunning
    }

    private let path: String
    private let maxConnections: Int
    private let handler: @Sendable (CommandRequest, CommandPeer) async -> CommandResponse
    private let lock = NSLock()
    private var source: (any DispatchSourceRead)?
    /// The socket file this server bound, so `stop` removes only its own.
    private var boundFile: (device: dev_t, inode: ino_t)?
    private var openConnections = 0

    /// `maxConnections` bounds the connections handled at once; more are
    /// closed at once, so a runaway client cannot tie up the app.
    public convenience init(path: String, maxConnections: Int = 16,
                            handler: @escaping @Sendable (CommandRequest) async -> CommandResponse) {
        self.init(path: path, maxConnections: maxConnections) { request, _ in await handler(request) }
    }

    /// The handler also learns which process sent the request.
    public init(path: String, maxConnections: Int = 16,
                handler: @escaping @Sendable (CommandRequest, CommandPeer) async -> CommandResponse) {
        self.path = path
        self.maxConnections = maxConnections
        self.handler = handler
    }

    public func start() throws {
        guard var address = UnixSocket.address(path) else { throw Failure.pathTooLong }
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        // A socket file left by a crashed run refuses connections; replace it.
        // One another FocusPilot copy answers on is that copy's (#42).
        // Anything that is not a socket is left alone and bind fails.
        var info = stat()
        if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK {
            guard !CommandSocketClient(path: path).isListening() else { throw Failure.alreadyRunning }
            unlink(path)
        }

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failure.couldNotListen(errno: errno) }
        guard UnixSocket.withAddress(&address, { bind(listener, $0, $1) }) == 0,
              chmod(path, 0o600) == 0,
              listen(listener, 16) == 0
        else {
            let error = errno
            close(listener)
            throw Failure.couldNotListen(errno: error)
        }
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        var bound = stat()
        let file = lstat(path, &bound) == 0 ? (device: bound.st_dev, inode: bound.st_ino) : nil

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .global())
        source.setEventHandler { [weak self] in self?.acceptPending(on: listener) }
        source.setCancelHandler { close(listener) }
        lock.withLock {
            self.source = source
            boundFile = file
        }
        source.resume()
    }

    /// Stops listening and removes the socket file if it is still the one
    /// this server bound, not another copy's. The listener closes shortly
    /// after, without blocking the caller.
    public func stop() {
        let (source, file) = lock.withLock {
            defer {
                self.source = nil
                boundFile = nil
            }
            return (self.source, boundFile)
        }
        source?.cancel()
        var info = stat()
        if let file, lstat(path, &info) == 0, info.st_dev == file.device, info.st_ino == file.inode { unlink(path) }
    }

    private func acceptPending(on listener: Int32) {
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            var uid = uid_t()
            var gid = gid_t()
            guard getpeereid(connection, &uid, &gid) == 0, uid == getuid(), claimConnection() else {
                close(connection)
                continue
            }
            // Accepted sockets inherit the listener's O_NONBLOCK on Darwin;
            // the connection is read with blocking calls and a timeout.
            _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK)
            let peer = CommandPeer(connection: connection)
            DispatchQueue.global().async { [handler] in
                UnixSocket.prepare(connection)
                guard let line = UnixSocket.readLine(connection),
                      let request = try? JSONDecoder().decode(CommandRequest.self, from: line)
                else {
                    self.release(connection)
                    return
                }
                Task {
                    let response = await handler(request, peer)
                    if let data = try? JSONEncoder().encode(response) { UnixSocket.writeLine(data, to: connection) }
                    self.release(connection)
                }
            }
        }
    }
}

extension CommandSocketServer {
    var openConnectionCount: Int { lock.withLock { openConnections } }

    fileprivate func claimConnection() -> Bool {
        lock.withLock {
            guard openConnections < maxConnections else { return false }
            openConnections += 1
            return true
        }
    }

    fileprivate func release(_ connection: Int32) {
        close(connection)
        lock.withLock { openConnections -= 1 }
    }
}

/// The process at the other end of a connection, read from the kernel when
/// it connects (`LOCAL_PEERPID`), not from anything it sends.
public struct CommandPeer: Equatable, Sendable {
    public var processID: Int32
    /// Nil when the process is gone or its path can't be read. For display
    /// and logs only; identity checks use `auditToken`.
    public var executablePath: String?
    /// The connection's audit token (`LOCAL_PEERTOKEN`): names the process,
    /// pid version included, so it can't be confused with a later process
    /// that reuses the pid. `ExceptionCallerCheck` verifies code with it.
    public var auditToken: [UInt32]?

    public init(processID: Int32, executablePath: String?, auditToken: [UInt32]? = nil) {
        self.processID = processID
        self.executablePath = executablePath
        self.auditToken = auditToken
    }

    init(connection: Int32) {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        // LOCAL_PEERTOKEN in <sys/un.h>.
        guard getsockopt(connection, SOL_LOCAL, 0x006, &token, &size) == 0 else {
            self.init(processID: -1, executablePath: nil)
            return
        }
        let values = withUnsafeBytes(of: token) { Array($0.bindMemory(to: UInt32.self)) }
        let pid = Self.processID(of: values)
        self.init(processID: pid, executablePath: Self.executablePath(of: pid), auditToken: values)
    }

    /// The pid an audit token names (its sixth value, as audit_token_to_pid reads it).
    static func processID(of token: [UInt32]) -> pid_t {
        pid_t(bitPattern: token[5])
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// The CLI's end: sends one request and waits for the answer.
public struct CommandSocketClient: Sendable {
    public enum Failure: Error, Equatable {
        case pathTooLong
        /// No app is listening: the socket is missing or refuses connections.
        case notRunning
        /// The app accepted the request but no readable answer came back, so
        /// it may or may not have been carried out.
        case noReply
    }

    private let path: String

    public init(path: String) {
        self.path = path
    }

    /// True when the app accepts connections, without sending a request.
    public func isListening() -> Bool {
        guard var address = UnixSocket.address(path) else { return false }
        let connection = socket(AF_UNIX, SOCK_STREAM, 0)
        guard connection >= 0 else { return false }
        defer { close(connection) }
        return UnixSocket.withAddress(&address, { connect(connection, $0, $1) }) == 0
    }

    public func send(_ request: CommandRequest) throws(Failure) -> CommandResponse {
        guard var address = UnixSocket.address(path) else { throw .pathTooLong }
        let connection = socket(AF_UNIX, SOCK_STREAM, 0)
        guard connection >= 0 else { throw .notRunning }
        defer { close(connection) }
        guard UnixSocket.withAddress(&address, { connect(connection, $0, $1) }) == 0 else { throw .notRunning }
        UnixSocket.prepare(connection)
        guard let data = try? JSONEncoder().encode(request), UnixSocket.writeLine(data, to: connection),
              let line = UnixSocket.readLine(connection),
              let response = try? JSONDecoder().decode(CommandResponse.self, from: line)
        else { throw .noReply }
        return response
    }
}

/// Blocking line I/O on Unix domain sockets, with timeouts so neither end
/// can be held forever.
enum UnixSocket {
    static let lineLimit = 256 * 1024
    static let timeout = timeval(tv_sec: 5, tv_usec: 0)

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        // One byte stays zero to end the path.
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func withAddress(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func prepare(_ connection: Int32) {
        var timeout = timeout
        var on: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // A peer that hangs up must not kill the process with SIGPIPE.
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// The bytes before the first newline, or nil on timeout, hang-up or a
    /// line over `lineLimit`.
    static func readLine(_ connection: Int32) -> Data? {
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { return nil }
            if let newline = buffer[..<count].firstIndex(of: UInt8(ascii: "\n")) {
                line.append(contentsOf: buffer[..<newline])
                return line
            }
            line.append(contentsOf: buffer[..<count])
            guard line.count <= lineLimit else { return nil }
        }
    }

    @discardableResult
    static func writeLine(_ data: Data, to connection: Int32) -> Bool {
        let bytes = [UInt8](data) + [UInt8(ascii: "\n")]
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
            guard count > 0 else { return false }
            sent += count
        }
        return true
    }
}
