import Darwin
import Foundation

/// Lets ssh ask the user for passwords, key passphrases, and two-factor codes.
///
/// ssh runs the program in SSH_ASKPASS for every prompt when SSH_ASKPASS_REQUIRE=force. The app
/// sets that program to its own executable. Started that way, the executable sends the prompt
/// to the running app over a Unix socket, prints the answer for ssh, and exits.
public enum Askpass {
    static let socketVariable = "S2V_ASKPASS_SOCKET"

    /// Call first thing at launch. Exits the process when it was started by ssh as askpass.
    public static func runHelperIfRequested() {
        guard let socket = ProcessInfo.processInfo.environment[socketVariable] else { return }
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
        guard let answer = request(prompt, socketPath: socket) else { exit(1) }
        FileHandle.standardOutput.write(Data((answer + "\n").utf8))
        exit(0)
    }

    /// Sends a prompt to the app and waits for the answer. Nil when the user cancels.
    static func request(_ prompt: String, socketPath: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_un.make(path: socketPath)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, writeAll(fd, Data((prompt + "\n").utf8)) else { return nil }
        let reply = readAll(fd)
        guard let text = String(data: reply, encoding: .utf8), text.hasSuffix("\n") else { return nil }
        return String(text.dropLast())
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    static func readAll(_ fd: Int32, until stop: UInt8? = nil) -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            data.append(byte)
            if let stop, byte == stop { break }
        }
        return data
    }
}

/// Receives prompts from the askpass helper for one ssh connection.
public final class AskpassServer: @unchecked Sendable {
    public let socketPath: String
    private let listener: Int32
    private let respond: @Sendable (String, @escaping @Sendable (String?) -> Void) -> Void

    /// `respond` gets each prompt and must call its completion once, with the answer or nil.
    public init(respond: @escaping @Sendable (String, @escaping @Sendable (String?) -> Void) -> Void) throws {
        self.respond = respond
        socketPath = "/tmp/s2v-\(UUID().uuidString.prefix(8)).sock"
        unlink(socketPath)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un.make(path: socketPath)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard listener >= 0, bound == 0, chmod(socketPath, 0o600) == 0, listen(listener, 4) == 0 else {
            close(listener)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not open the password prompt socket"])
        }
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    /// Environment variables that route ssh's prompts to this server.
    public func environment(askpass executable: URL) -> [String: String] {
        [
            "SSH_ASKPASS": executable.path,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ProcessInfo.processInfo.environment["DISPLAY"] ?? ":0",
            Askpass.socketVariable: socketPath,
        ]
    }

    public func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
        unlink(socketPath)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            let prompt = String(decoding: Askpass.readAll(client, until: UInt8(ascii: "\n")), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            respond(prompt) { answer in
                if let answer { _ = Askpass.writeAll(client, Data((answer + "\n").utf8)) }
                close(client)
            }
        }
    }
}

extension sockaddr_un {
    static func make(path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }
}
