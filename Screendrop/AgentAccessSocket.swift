//
//  AgentAccessSocket.swift
//  Screendrop
//
//  The Unix socket the MCP helper connects to, mode 0600, and the checks on
//  each connection: the same user, and this app's own helper signed by this
//  app's team. Messages are one line of JSON each.
//

import Darwin
import Foundation
import Security

/// Who may connect.
nonisolated struct AgentPeerPolicy: Sendable {
    var uid: uid_t = getuid()
    /// What the helper's signature must meet; nil when this app isn't signed with a
    /// team, and then no helper may connect.
    var requirement: String?
    /// The helper's path inside this app.
    var helperPath: String

    static let helperName = "sukusho-mcp"

    /// This app's team and its own helper.
    static func current() -> AgentPeerPolicy {
        let team = AgentPeerCheck.signingInfo(of: selfStaticCode())?.team
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/" + helperName).resolvingSymlinksInPath().path
        return AgentPeerPolicy(requirement: team.map(teamRequirement), helperPath: helper)
    }

    static func teamRequirement(_ team: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    private static func selfStaticCode() -> SecStaticCode? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else { return nil }
        return staticCode
    }
}

nonisolated enum AgentPeerCheck {
    enum Refusal: Error, Equatable {
        case wrongUser
        /// This app has no team, so it can't tell its helper from anything else.
        case appNotTeamSigned
        /// The peer isn't signed by this app's team.
        case notTeamSigned
        /// Signed by the team, but not this app's helper.
        case notHelper
    }

    struct SigningInfo: Equatable {
        var team: String?
        var identifier: String?
        var path: String?
        var isPlatform = false
        var isAdHoc = false
    }

    /// The checks on a connection, given its peer's uid and code.
    static func check(uid: uid_t, code: SecCode?, policy: AgentPeerPolicy) -> Refusal? {
        guard uid == policy.uid else { return .wrongUser }
        guard let requirementText = policy.requirement else { return .appNotTeamSigned }
        var requirement: SecRequirement?
        guard let code, SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return .notTeamSigned }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              signingInfo(of: staticCode)?.path.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) == policy.helperPath
        else { return .notHelper }
        return nil
    }

    /// The connected process: its uid, pid and code, from the socket.
    static func peer(of fd: Int32) -> (uid: uid_t, pid: pid_t, code: SecCode?)? {
        var uid = uid_t(), gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        var pid = pid_t()
        var pidLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLength) == 0 else { return nil }
        var token = audit_token_t()
        var tokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLength) == 0 else { return (uid, pid, nil) }
        // The audit token names this process, not whatever reuses its pid later.
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code)
        return (uid, pid, code)
    }

    static func signingInfo(of staticCode: SecStaticCode?) -> SigningInfo? {
        guard let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        let flags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        var path: CFURL?
        SecCodeCopyPath(staticCode, [], &path)
        return SigningInfo(team: info[kSecCodeInfoTeamIdentifier as String] as? String,
                           identifier: info[kSecCodeInfoIdentifier as String] as? String,
                           path: (path as URL?)?.path,
                           isPlatform: ((info[kSecCodeInfoPlatformIdentifier as String] as? Int) ?? 0) != 0,
                           isAdHoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0)
    }

    static func signingInfo(pid: pid_t) -> SigningInfo? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else { return nil }
        return signingInfo(of: staticCode)
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid > 1 else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The program that started the helper, skipping macOS's own shells and
    /// `env` in between, as the signer half of an `AgentIdentity`.
    static func agentSigner(helperPID: pid_t) -> (signer: String, name: String) {
        var pid = parent(of: helperPID)
        for _ in 0..<4 {
            guard let current = pid else { break }
            let info = signingInfo(pid: current)
            if info?.isPlatform == true, let next = parent(of: current) {
                pid = next
                continue
            }
            return signer(info, path: info?.path ?? path(of: current))
        }
        return ("unknown", "Unknown program")
    }

    static func signer(_ info: SigningInfo?, path: String?) -> (signer: String, name: String) {
        if let info, !info.isAdHoc, let team = info.team, let identifier = info.identifier {
            return ("team:\(team):\(identifier)", "\(identifier) (\(team))")
        }
        let path = path ?? "unknown"
        return ("path:" + path, URL(fileURLWithPath: path).lastPathComponent + ", unsigned")
    }
}

/// The listening socket. Accepts on its own queue; each connection that passes
/// the checks goes to `onConnection` there.
nonisolated final class AgentSocketServer: @unchecked Sendable {
    let path: String
    private let policy: AgentPeerPolicy
    private let queue = DispatchQueue(label: "Sukusho agent socket")
    private let onConnection: @Sendable (AgentSocketConnection, pid_t) -> Void
    private let onRefusal: @Sendable (AgentPeerCheck.Refusal) -> Void
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, policy: AgentPeerPolicy,
         onRefusal: @escaping @Sendable (AgentPeerCheck.Refusal) -> Void = { _ in },
         onConnection: @escaping @Sendable (AgentSocketConnection, pid_t) -> Void) {
        self.path = path
        self.policy = policy
        self.onRefusal = onRefusal
        self.onConnection = onConnection
    }

    enum StartError: LocalizedError {
        case pathTooLong, system(String, Int32)
        var errorDescription: String? {
            switch self {
            case .pathTooLong: "The socket path is too long."
            case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw StartError.pathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.system("socket", errno) }
        // A socket left by a crash would make bind fail; only a socket is removed.
        var existing = stat()
        if lstat(path, &existing) == 0, existing.st_mode & S_IFMT == S_IFSOCK { unlink(path) }
        // Created 0600, never briefly open to others.
        let mask = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(mask)
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw StartError.system("bind", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw StartError.system("listen", code)
        }
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            if listener >= 0 { unlink(path) }
            listener = -1
        }
    }

    private func acceptOne() {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        guard let peer = AgentPeerCheck.peer(of: fd) else {
            close(fd)
            return
        }
        if let refusal = AgentPeerCheck.check(uid: peer.uid, code: peer.code, policy: policy) {
            let connection = AgentSocketConnection(fd: fd)
            connection.send(["refused": AgentSocketServer.message(for: refusal)])
            connection.close()
            onRefusal(refusal)
            return
        }
        onConnection(AgentSocketConnection(fd: fd), peer.pid)
    }

    static func message(for refusal: AgentPeerCheck.Refusal) -> String {
        switch refusal {
        case .wrongUser: "Sukusho only answers its own user."
        case .appNotTeamSigned: "This Sukusho build isn’t signed with a team, so it can’t check its helper."
        case .notTeamSigned: "Sukusho only answers its own helper, and this one isn’t signed by Sukusho’s team."
        case .notHelper: "Sukusho only answers the helper inside its own app."
        }
    }
}

/// One connection: reads lines of JSON, writes lines of JSON.
nonisolated final class AgentSocketConnection: @unchecked Sendable {
    /// Longer lines close the connection; tool calls are far smaller.
    static let maxLine = 4 * 1024 * 1024
    let fd: Int32
    private let queue = DispatchQueue(label: "Sukusho agent connection")
    private var buffer = Data()
    private var source: DispatchSourceRead?
    private var closed = false

    init(fd: Int32) { self.fd = fd }

    /// Starts reading; `onLine` hears each line, `onClose` once at the end.
    func start(onLine: @escaping @Sendable ([String: Any]?) -> Void, onClose: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(onLine: onLine) }
            source.setCancelHandler { [fd] in
                Darwin.close(fd)
                onClose()
            }
            self.source = source
            source.resume()
        }
    }

    private func read(onLine: @Sendable ([String: Any]?) -> Void) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(fd, &chunk, chunk.count)
        guard count > 0 else { return finish() }
        buffer.append(contentsOf: chunk[0..<count])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            onLine(try? JSONSerialization.jsonObject(with: line) as? [String: Any])
        }
        if buffer.count > Self.maxLine { finish() }
    }

    func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        queue.async { [self] in
            guard !closed else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }
    }

    func close() {
        queue.async { [self] in finish() }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        if let source { source.cancel() } else { Darwin.close(fd) }
        source = nil
    }
}
