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
    public var skippedPermission: Int

    public init(
        scanned: Int = 0,
        bytes: Int64 = 0,
        currentPath: String = "",
        workerRestarts: Int = 0,
        skippedSystem: Int = 0,
        skippedPermission: Int = 0
    ) {
        self.scanned = scanned
        self.bytes = bytes
        self.currentPath = currentPath
        self.workerRestarts = workerRestarts
        self.skippedSystem = skippedSystem
        self.skippedPermission = skippedPermission
    }
}

private final class ScanState: @unchecked Sendable {
    var scanned: Int
    var bytes: Int64
    var lastCheckpoint: String?
    var skippedSystem: Int = 0
    var skippedPermission: Int = 0
    var sawDone = false
    var workerError: String?

    init(scanned: Int, bytes: Int64, checkpoint: String?) {
        self.scanned = scanned
        self.bytes = bytes
        self.lastCheckpoint = checkpoint
    }
}

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
            bundle.bundleURL
                .appendingPathComponent("Contents/MacOS/ScannerWorker"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/debug/ScannerWorker"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/release/ScannerWorker"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("dist/MacStorage Studio.app/Contents/MacOS/ScannerWorker"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("dist/MacStorageStudio.app/Contents/MacOS/ScannerWorker"),
            URL(fileURLWithPath: "/Applications/MacStorage Studio.app/Contents/MacOS/ScannerWorker"),
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

        // Immediate UI feedback before first file
        if let onProgress {
            await onProgress(ScanProgress(scanned: 0, bytes: 0, currentPath: roots.first ?? "Starting…", workerRestarts: 0))
        }

        while true {
            if cancelled { throw ScannerClientError.cancelled }
            do {
                let remaining: Int?
                if let maxFileCount {
                    remaining = max(0, maxFileCount - state.scanned)
                } else {
                    remaining = nil
                }
                return try await runWorkerOnce(
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
                        workerRestarts: restarts,
                        skippedSystem: state.skippedSystem,
                        skippedPermission: state.skippedPermission
                    ))
                }
                continue
            }
        }
    }

    public func runCrashTest() async throws {
        let outcome = try await executeStreaming(command: WorkerCommand(cmd: "crash")) { _ in }
        if outcome.exitCode != 0 || outcome.terminationReason == .uncaughtSignal {
            throw ScannerClientError.workerCrashed(exitCode: outcome.exitCode == 0 ? 1 : outcome.exitCode)
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

        let outcome = try await executeStreaming(command: command) { message in
            switch message {
            case .entry(let record):
                state.scanned += 1
                if !record.isDirectory {
                    state.bytes += record.allocatedSize > 0 ? record.allocatedSize : record.size
                }
                state.lastCheckpoint = record.path
                await onEntry(record)
                if state.scanned == 1 || state.scanned % 10 == 0, let onProgress {
                    await onProgress(ScanProgress(
                        scanned: state.scanned,
                        bytes: state.bytes,
                        currentPath: record.path,
                        workerRestarts: restarts,
                        skippedSystem: state.skippedSystem,
                        skippedPermission: state.skippedPermission
                    ))
                }
            case .progress(let s, let b, let path, let skippedSys, let skippedPerm):
                state.scanned = max(state.scanned, baseScanned + s)
                state.bytes = max(state.bytes, baseBytes + b)
                state.lastCheckpoint = path
                state.skippedSystem = skippedSys
                state.skippedPermission = skippedPerm
                if let onProgress {
                    await onProgress(ScanProgress(
                        scanned: state.scanned,
                        bytes: state.bytes,
                        currentPath: path,
                        workerRestarts: restarts,
                        skippedSystem: skippedSys,
                        skippedPermission: skippedPerm
                    ))
                }
            case .done(let s, let b, let errors, let cp):
                state.scanned = max(state.scanned, baseScanned + s)
                state.bytes = max(state.bytes, baseBytes + b)
                if let cp { state.lastCheckpoint = cp }
                if errors > state.skippedPermission { state.skippedPermission = errors }
                state.sawDone = true
                if let onProgress {
                    await onProgress(ScanProgress(
                        scanned: state.scanned,
                        bytes: state.bytes,
                        currentPath: state.lastCheckpoint ?? "",
                        workerRestarts: restarts,
                        skippedSystem: state.skippedSystem,
                        skippedPermission: state.skippedPermission
                    ))
                }
            case .error(let message, _):
                state.workerError = message
            case .hello, .log:
                break
            }
        }

        if let workerError = state.workerError {
            throw ScannerClientError.failed(workerError)
        }
        if outcome.exitCode != 0 || outcome.terminationReason == .uncaughtSignal {
            throw ScannerClientError.workerCrashed(exitCode: outcome.exitCode)
        }
        if !state.sawDone {
            throw ScannerClientError.workerCrashed(exitCode: outcome.exitCode)
        }
        return (state.scanned, state.bytes, state.lastCheckpoint)
    }

    private struct StreamOutcome: Sendable {
        var exitCode: Int32
        var terminationReason: Process.TerminationReason
    }

    /// Blocking pipe read on a background task — more reliable than readabilityHandler for Process.
    private func executeStreaming(
        command: WorkerCommand,
        onMessage: @escaping @Sendable (WorkerMessage) async -> Void
    ) async throws -> StreamOutcome {
        guard FileManager.default.isExecutableFile(atPath: workerURL.path) else {
            throw ScannerClientError.workerNotFound
        }

        let process = Process()
        process.executableURL = workerURL
        process.arguments = []
        // Inherit a clean environment; PATH not needed for absolute executable
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        self.process = process

        try process.run()

        let payload = try JSONEncoder().encode(command) + Data("\n".utf8)
        try stdinPipe.fileHandleForWriting.write(contentsOf: payload)
        try? stdinPipe.fileHandleForWriting.close()

        let readHandle = stdoutPipe.fileHandleForReading
        let decoder = JSONDecoder()

        // Read pipe concurrently with process execution
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var buffer = Data()
                while true {
                    // readData(ofLength:) blocks until data or EOF
                    let chunk = readHandle.readData(ofLength: 64 * 1024)
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let range = buffer.range(of: Data([UInt8(ascii: "\n")])) {
                        let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                        buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                        guard !line.isEmpty,
                              let message = try? decoder.decode(WorkerMessage.self, from: line) else {
                            continue
                        }
                        await onMessage(message)
                    }
                    if Task.isCancelled { break }
                }
                if !buffer.isEmpty, let message = try? decoder.decode(WorkerMessage.self, from: buffer) {
                    await onMessage(message)
                }
            }

            group.addTask { [weak process] in
                // Poll cancel
                while let process, process.isRunning {
                    if Task.isCancelled {
                        process.terminate()
                        break
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            }

            // Wait until reader finishes (EOF when process closes stdout)
            try await group.next()
            group.cancelAll()
        }

        if process.isRunning {
            process.waitUntilExit()
        }
        let status = process.terminationStatus
        let reason = process.terminationReason
        self.process = nil

        return StreamOutcome(exitCode: status, terminationReason: reason)
    }
}
