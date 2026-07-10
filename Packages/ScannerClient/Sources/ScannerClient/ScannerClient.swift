import Foundation
import MacStorageCore

public enum ScannerClientError: Error, LocalizedError, Sendable {
    case workerNotFound
    case invalidResponse
    case workerCrashed(exitCode: Int32)
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .workerNotFound:
            return "ScannerWorker executable not found. Build the ScannerWorker target and ensure it sits next to the app or in .build/debug."
        case .invalidResponse:
            return "Invalid response from scanner worker"
        case .workerCrashed(let code):
            return "Scanner worker crashed (exit \(code)). The app is still running — you can resume from the last checkpoint."
        case .cancelled:
            return "Scan cancelled"
        case .failed(let s):
            return s
        }
    }
}

public struct ScanProgress: Sendable, Equatable {
    public var scanned: Int
    public var bytes: Int64
    public var currentPath: String
    public var workerRestarts: Int
    public var skippedSystem: Int

    public init(scanned: Int = 0, bytes: Int64 = 0, currentPath: String = "", workerRestarts: Int = 0, skippedSystem: Int = 0) {
        self.scanned = scanned
        self.bytes = bytes
        self.currentPath = currentPath
        self.workerRestarts = workerRestarts
        self.skippedSystem = skippedSystem
    }
}

/// Mutable counters shared only on the cooperative pool while parsing worker output.
private final class ScanState: @unchecked Sendable {
    var scanned: Int
    var bytes: Int64
    var lastCheckpoint: String?
    var sawDone = false
    var workerError: String?

    init(scanned: Int, bytes: Int64, checkpoint: String?) {
        self.scanned = scanned
        self.bytes = bytes
        self.lastCheckpoint = checkpoint
    }
}

/// Hosts the scanner in a **separate process**. Worker crashes do not terminate the app.
public actor ScannerClient {
    public typealias EntryHandler = @Sendable (WorkerFileRecord) async -> Void
    public typealias ProgressHandler = @Sendable (ScanProgress) async -> Void

    private let workerURL: URL
    private var process: Process?
    private var cancelled = false

    public init(workerURL: URL) {
        self.workerURL = workerURL
    }

    public static func locateWorker(bundle: Bundle = .main) -> URL? {
        if let builtIn = bundle.url(forAuxiliaryExecutable: "ScannerWorker") {
            return builtIn
        }
        if let exeDir = bundle.executableURL?.deletingLastPathComponent() {
            let sibling = exeDir.appendingPathComponent("ScannerWorker")
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
        }
        let env = ProcessInfo.processInfo.environment
        if let override = env["MACSTORAGE_SCANNER_WORKER"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let candidates = [
            bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("ScannerWorker"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/debug/ScannerWorker"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/release/ScannerWorker"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(".build/debug/ScannerWorker"),
        ]
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    public func cancel() {
        cancelled = true
        process?.terminate()
    }

    public func scan(
        roots: [String],
        excludePrefixes: [String] = SystemGuardrails.shared.excludePrefixes(),
        checkpoint: String? = nil,
        maxFileCount: Int? = nil,
        maxWorkerRestarts: Int = 3,
        onEntry: @escaping EntryHandler,
        onProgress: ProgressHandler? = nil
    ) async throws -> (scanned: Int, bytes: Int64, checkpoint: String?) {
        cancelled = false
        var resumeFrom = checkpoint
        let state = ScanState(scanned: 0, bytes: 0, checkpoint: checkpoint)
        var restarts = 0

        while true {
            if cancelled { throw ScannerClientError.cancelled }
            do {
                let remaining: Int?
                if let maxFileCount {
                    remaining = max(0, maxFileCount - state.scanned)
                } else {
                    remaining = nil
                }
                let result = try await runWorkerOnce(
                    roots: roots,
                    excludePrefixes: excludePrefixes,
                    checkpoint: resumeFrom,
                    maxFileCount: remaining,
                    baseScanned: state.scanned,
                    baseBytes: state.bytes,
                    restarts: restarts,
                    state: state,
                    onEntry: onEntry,
                    onProgress: onProgress
                )
                return (result.scanned, result.bytes, result.checkpoint)
            } catch let ScannerClientError.workerCrashed(code) {
                restarts += 1
                if restarts > maxWorkerRestarts {
                    throw ScannerClientError.workerCrashed(exitCode: code)
                }
                resumeFrom = state.lastCheckpoint
                if let onProgress {
                    await onProgress(ScanProgress(
                        scanned: state.scanned,
                        bytes: state.bytes,
                        currentPath: resumeFrom ?? "",
                        workerRestarts: restarts
                    ))
                }
                continue
            }
        }
    }

    public func runCrashTest() async throws {
        let result = try await execute(command: WorkerCommand(cmd: "crash"))
        if result.exitCode != 0 || result.terminationReason == .uncaughtSignal {
            throw ScannerClientError.workerCrashed(exitCode: result.exitCode == 0 ? 1 : result.exitCode)
        }
    }

    private func runWorkerOnce(
        roots: [String],
        excludePrefixes: [String],
        checkpoint: String?,
        maxFileCount: Int?,
        baseScanned: Int,
        baseBytes: Int64,
        restarts: Int,
        state: ScanState,
        onEntry: @escaping EntryHandler,
        onProgress: ProgressHandler?
    ) async throws -> (scanned: Int, bytes: Int64, checkpoint: String?) {
        state.sawDone = false
        state.workerError = nil

        let command = WorkerCommand.scan(
            roots: roots,
            excludePrefixes: excludePrefixes,
            checkpoint: checkpoint,
            maxFileCount: maxFileCount
        )

        let result = try await execute(command: command)
        let decoder = JSONDecoder()
        let text = String(data: result.stdout, encoding: .utf8) ?? ""

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let message = try? decoder.decode(WorkerMessage.self, from: lineData) else {
                continue
            }
            switch message {
            case .entry(let record):
                state.scanned += 1
                if !record.isDirectory {
                    state.bytes += record.allocatedSize > 0 ? record.allocatedSize : record.size
                }
                state.lastCheckpoint = record.path
                await onEntry(record)
            case .progress(let s, let b, let path, let skipped):
                state.scanned = baseScanned + s
                state.bytes = baseBytes + b
                state.lastCheckpoint = path
                if let onProgress {
                    await onProgress(ScanProgress(
                        scanned: state.scanned,
                        bytes: state.bytes,
                        currentPath: path,
                        workerRestarts: restarts,
                        skippedSystem: skipped
                    ))
                }
            case .done(let s, let b, _, let cp):
                state.scanned = baseScanned + s
                state.bytes = baseBytes + b
                if let cp { state.lastCheckpoint = cp }
                state.sawDone = true
            case .error(let message, _):
                state.workerError = message
            case .hello, .log:
                break
            }
        }

        if let workerError = state.workerError {
            throw ScannerClientError.failed(workerError)
        }
        if result.exitCode != 0 || result.terminationReason == .uncaughtSignal {
            throw ScannerClientError.workerCrashed(exitCode: result.exitCode)
        }
        if !state.sawDone {
            throw ScannerClientError.workerCrashed(exitCode: result.exitCode)
        }
        return (state.scanned, state.bytes, state.lastCheckpoint)
    }

    private struct ProcessResult: Sendable {
        var exitCode: Int32
        var terminationReason: Process.TerminationReason
        var stdout: Data
    }

    private func execute(command: WorkerCommand) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: workerURL.path) else {
            throw ScannerClientError.workerNotFound
        }

        let process = Process()
        process.executableURL = workerURL

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        self.process = process

        try process.run()

        let payload = try JSONEncoder().encode(command) + Data("\n".utf8)
        stdinPipe.fileHandleForWriting.write(payload)
        try? stdinPipe.fileHandleForWriting.close()

        let stdoutData: Data = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }

        process.waitUntilExit()
        self.process = nil

        return ProcessResult(
            exitCode: process.terminationStatus,
            terminationReason: process.terminationReason,
            stdout: stdoutData
        )
    }
}
