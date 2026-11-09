import Darwin
import Foundation
import Security
import Testing

/// Another process on the socket: `nc -U`, which is signed by Apple, so a
/// policy that takes Apple's signature and nc's path stands in for the helper.
private nonisolated final class NetcatPeer: @unchecked Sendable {
    static let path = "/usr/bin/nc"
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()

    init(socket: String) throws {
        // A write after the app closed must not end the test run.
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = URL(fileURLWithPath: Self.path)
        process.arguments = ["-U", socket]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
    }

    deinit { if process.isRunning { process.terminate() } }

    func send(_ object: [String: Any]) {
        var data = try! JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    /// The next line, or nil when nc ends or nothing comes within `timeout` milliseconds.
    func line(timeout: Int32 = 10_000) -> [String: Any]? {
        let fd = output.fileHandleForReading.fileDescriptor
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            }
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, timeout) > 0 else { return nil }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}

/// A plain connection from this test process.
private nonisolated func readOneLine(from path: String) -> [String: Any]? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return nil }
    var line = Data()
    var byte: UInt8 = 0
    while read(fd, &byte, 1) == 1 {
        if byte == 0x0A { return try? JSONSerialization.jsonObject(with: line) as? [String: Any] }
        line.append(byte)
    }
    return nil
}

@Suite @MainActor
struct AgentSocketTests {
    private static func socketPath() -> String {
        // sun_path holds 104 bytes; the temporary folder is short enough.
        FileManager.default.temporaryDirectory.appendingPathComponent("ag-\(UUID().uuidString.prefix(8)).sock").path
    }

    private static func code(of pid: pid_t) -> SecCode? {
        var code: SecCode?
        SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code)
        return code
    }

    /// `/bin/sleep`, signed by Apple and running: the subject of the checks.
    private static func sleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        return process
    }

    private static let apple = "anchor apple"

    @Test func refusesAnotherUser() throws {
        let sleeper = try Self.sleeper()
        defer { sleeper.terminate() }
        let code = Self.code(of: sleeper.processIdentifier)
        let policy = AgentPeerPolicy(requirement: Self.apple, helperPath: "/bin/sleep")
        #expect(AgentPeerCheck.check(uid: getuid() + 1, code: code, policy: policy) == .wrongUser)
        #expect(AgentPeerCheck.check(uid: getuid(), code: code, policy: policy) == nil)
    }

    @Test func refusesEverythingWhenTheAppHasNoTeam() throws {
        let sleeper = try Self.sleeper()
        defer { sleeper.terminate() }
        let policy = AgentPeerPolicy(requirement: nil, helperPath: "/bin/sleep")
        #expect(AgentPeerCheck.check(uid: getuid(), code: Self.code(of: sleeper.processIdentifier), policy: policy) == .appNotTeamSigned)
    }

    @Test func refusesAProgramSignedByAnotherTeamOrNotTheHelper() throws {
        let sleeper = try Self.sleeper()
        defer { sleeper.terminate() }
        let code = Self.code(of: sleeper.processIdentifier)
        let team = AgentPeerPolicy(requirement: AgentPeerPolicy.teamRequirement("NMM3956F6W"), helperPath: "/bin/sleep")
        #expect(AgentPeerCheck.check(uid: getuid(), code: code, policy: team) == .notTeamSigned)
        let elsewhere = AgentPeerPolicy(requirement: Self.apple, helperPath: "/Applications/Sukusho.app/Contents/Helpers/sukusho-mcp")
        #expect(AgentPeerCheck.check(uid: getuid(), code: code, policy: elsewhere) == .notHelper)
        #expect(AgentPeerCheck.check(uid: getuid(), code: nil, policy: team) == .notTeamSigned)
    }

    @Test func refusesAnAdHocSignedHelper() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-adhoc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A helper built here gets only the linker's ad hoc signature, as an unsigned build would.
        let source = folder.appendingPathComponent("helper.c")
        try Data("#include <unistd.h>\nint main(void) { return sleep(5); }\n".utf8).write(to: source)
        let helper = folder.appendingPathComponent("sukusho-mcp")
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        build.arguments = ["clang", source.path, "-o", helper.path]
        try build.run()
        build.waitUntilExit()
        try #require(build.terminationStatus == 0)
        let running = Process()
        running.executableURL = helper
        try running.run()
        defer { running.terminate() }
        let policy = AgentPeerPolicy(requirement: AgentPeerPolicy.teamRequirement("NMM3956F6W"), helperPath: helper.resolvingSymlinksInPath().path)
        #expect(AgentPeerCheck.check(uid: getuid(), code: Self.code(of: running.processIdentifier), policy: policy) == .notTeamSigned)
        let info = AgentPeerCheck.signingInfo(pid: running.processIdentifier)
        #expect(info?.isAdHoc == true)
        // As an agent, an ad hoc program is known by its path, never by a name it could copy.
        #expect(AgentPeerCheck.signer(info, path: helper.path).signer == "path:" + helper.path)
    }

    @Test func theSocketIsPrivateAndRefusesAWrongHelperWithAReason() async throws {
        let path = Self.socketPath()
        let server = AgentAccessServer(toolbox: AgentHarness().toolbox)
        try server.start(path: path, policy: AgentPeerPolicy(requirement: AgentPeerPolicy.teamRequirement("NMM3956F6W"), helperPath: NetcatPeer.path))
        defer { server.stop() }
        var info = stat()
        #expect(stat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        let reply = await Task.detached { readOneLine(from: path) }.value
        #expect((reply?["refused"] as? String)?.contains("isn’t signed by Sukusho’s team") == true)
        server.stop()
        #expect(stat(path, &info) != 0)
    }

    @Test func helloThenToolsOverTheSocket() async throws {
        let path = Self.socketPath()
        let harness = AgentHarness()
        harness.addItem("a", title: "Receipt")
        harness.asker.reply = .deny
        let server = AgentAccessServer(toolbox: harness.toolbox)
        server.signer = { _ in ("team:TEAMID1234:com.example.agent", "com.example.agent (TEAMID1234)") }
        try server.start(path: path, policy: AgentPeerPolicy(requirement: Self.apple, helperPath: NetcatPeer.path))
        defer { server.stop() }
        let peer = try NetcatPeer(socket: path)
        let replies = await Task.detached { () -> [[String: Any]] in
            peer.send(["hello": ["name": "example-agent", "version": "1.0"]])
            var replies = [peer.line() ?? [:]]
            peer.send(["id": 1, "method": "tools/list", "params": [:]])
            replies.append(peer.line() ?? [:])
            peer.send(["id": 2, "method": "tools/call", "params": ["name": "library_search", "arguments": ["query": "receipt"]]])
            replies.append(peer.line() ?? [:])
            peer.send(["id": 3, "method": "tools/call", "params": ["name": "share", "arguments": ["ids": ["a"]]]])
            replies.append(peer.line() ?? [:])
            peer.send(["id": 4, "method": "nope", "params": [:]])
            replies.append(peer.line() ?? [:])
            return replies
        }.value
        try #require(replies.count == 5)
        #expect(replies[0]["welcome"] as? Bool == true)
        #expect(replies[1]["id"] as? Int == 1)
        #expect(((replies[1]["result"] as? [String: Any])?["tools"] as? [Any])?.count == 17)
        let search = try #require((replies[2]["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
        #expect(search["count"] as? Int == 1)
        let share = try #require(replies[3]["result"] as? [String: Any])
        #expect(share["isError"] as? Bool == true)
        #expect((share["structuredContent"] as? [String: Any])?["status"] as? String == "denied")
        #expect(replies[4]["error"] as? String == "Unknown method nope.")
        #expect(server.sessions.first?.agent.clientName == "example-agent")
        #expect(server.sessions.first?.agent.signer == "team:TEAMID1234:com.example.agent")
    }

    @Test func turningAccessOffEndsOpenSessions() async throws {
        let path = Self.socketPath()
        let server = AgentAccessServer(toolbox: AgentHarness().toolbox)
        server.signer = { _ in ("team:TEAMID1234:com.example.agent", "com.example.agent (TEAMID1234)") }
        try server.start(path: path, policy: AgentPeerPolicy(requirement: Self.apple, helperPath: NetcatPeer.path))
        defer { server.stop() }
        let peer = try NetcatPeer(socket: path)
        let welcome = await Task.detached { () -> [String: Any]? in
            peer.send(["hello": ["name": "example-agent"]])
            return peer.line()
        }.value
        #expect(welcome?["welcome"] as? Bool == true)
        #expect(server.sessions.count == 1)
        server.stop()
        #expect(server.sessions.isEmpty)
        // An open session answers in milliseconds; this one is gone.
        let after = await Task.detached { () -> [String: Any]? in
            peer.send(["id": 1, "method": "tools/list", "params": [:]])
            return peer.line(timeout: 2000)
        }.value
        #expect(after == nil)
    }

    @Test func aRequestBeforeHelloIsRefused() async throws {
        let path = Self.socketPath()
        let server = AgentAccessServer(toolbox: AgentHarness().toolbox)
        try server.start(path: path, policy: AgentPeerPolicy(requirement: Self.apple, helperPath: NetcatPeer.path))
        defer { server.stop() }
        let peer = try NetcatPeer(socket: path)
        let reply = await Task.detached { () -> [String: Any]? in
            peer.send(["id": 1, "method": "tools/list"])
            return peer.line()
        }.value
        #expect(reply?["refused"] as? String == "Say hello first.")
    }
}
