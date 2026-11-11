import Foundation

public enum WorkerError: LocalizedError {
    case notRunning
    case exited(status: Int32, log: String)
    case replyError(String)
    case malformedReply(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: "The TTS worker is not running"
        case .exited(let status, let log):
            log.isEmpty ? "The TTS worker exited with status \(status)" : "The TTS worker exited with status \(status):\n\(log)"
        case .replyError(let message): message
        case .malformedReply(let line): "Unexpected reply from the TTS worker: \(line.prefix(200))"
        }
    }
}

/// Runs one `slides-to-video-worker` process, local or through ssh, and exchanges JSON lines with it.
///
/// A connection is started once and never restarted on its own. When the process exits,
/// pending requests fail and `onExit` fires; reconnecting is left to the user.
public final class WorkerConnection: @unchecked Sendable {
    public typealias Reply = [String: Any]

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var errorBuffer = Data()
    private var recentLog: [String] = []
    private var pending: [Int: CheckedContinuation<Reply, Error>] = [:]
    private var nextID = 1
    private var exitError: WorkerError?

    public var onLog: (@Sendable (String) -> Void)?
    public var onExit: (@Sendable (WorkerError) -> Void)?

    public init(executable: URL, arguments: [String], environment: [String: String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    public var isRunning: Bool { process.isRunning }

    public func start() throws {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receiveLog(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            self?.finish(status: process.terminationStatus)
        }
        try process.run()
    }

    public func stop() {
        guard process.isRunning else { return }
        try? stdin.fileHandleForWriting.close()
        process.terminate()
    }

    public func request(_ command: String, _ parameters: [String: Any] = [:]) async throws -> Reply {
        let line: Data
        let id: Int
        lock.lock()
        if let exitError {
            lock.unlock()
            throw exitError
        }
        id = nextID
        nextID += 1
        lock.unlock()
        var message = parameters
        message["id"] = id
        message["cmd"] = command
        line = try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8)

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[id] = continuation
            lock.unlock()
            do {
                try stdin.fileHandleForWriting.write(contentsOf: line)
            } catch {
                lock.lock()
                let waiting = pending.removeValue(forKey: id)
                lock.unlock()
                waiting?.resume(throwing: WorkerError.notRunning)
            }
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines { deliver(line) }
    }

    private func deliver(_ line: Data) {
        guard let reply = try? JSONSerialization.jsonObject(with: line) as? Reply,
              let id = reply["id"] as? Int else {
            onLog?("unparsed worker output: \(String(decoding: line, as: UTF8.self))")
            return
        }
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        if reply["ok"] as? Bool == true {
            continuation?.resume(returning: reply)
        } else {
            continuation?.resume(throwing: WorkerError.replyError(reply["error"] as? String ?? "Unknown worker error"))
        }
    }

    private func receiveLog(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        errorBuffer.append(data)
        var lines: [String] = []
        while let newline = errorBuffer.firstIndex(where: { $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r") }) {
            let text = String(decoding: errorBuffer[errorBuffer.startIndex..<newline], as: UTF8.self)
            errorBuffer.removeSubrange(errorBuffer.startIndex...newline)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(text) }
        }
        recentLog = Array((recentLog + lines).suffix(20))
        lock.unlock()
        for line in lines { onLog?(line) }
    }

    private func finish(status: Int32) {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        let error = WorkerError.exited(status: status, log: recentLog.suffix(8).joined(separator: "\n"))
        exitError = error
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        for continuation in waiting.values { continuation.resume(throwing: error) }
        onExit?(error)
    }
}
