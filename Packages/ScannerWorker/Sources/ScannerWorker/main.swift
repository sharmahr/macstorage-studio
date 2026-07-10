import Foundation
import MacStorageCore
import ScannerEngine

/// Isolated scanner process. Communicates via newline-delimited JSON on stdin/stdout.
/// Crashes here cannot take down the host app.

final class StdoutEmitter: ScannerEventHandler, @unchecked Sendable {
    private let lock = NSLock()
    private let encoder = JSONEncoder()

    func emit(_ message: WorkerMessage) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? encoder.encode(message),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    func scannerDidEmit(_ record: WorkerFileRecord) async {
        emit(.entry(record))
    }

    func scannerDidProgress(scanned: Int, bytes: Int64, path: String, skippedSystem: Int) async {
        emit(.progress(scanned: scanned, bytes: bytes, path: path, skippedSystem: skippedSystem))
    }
}

@main
struct ScannerWorkerMain {
    static func main() async {
        let emitter = StdoutEmitter()
        emitter.emit(.hello(version: ScanDefaults.protocolVersion))

        let decoder = JSONDecoder()
        let scanner = FilesystemScanner()

        // Read a single command line from stdin (one JSON object)
        guard let inputData = readStdinLine(),
              let command = try? decoder.decode(WorkerCommand.self, from: inputData) else {
            emitter.emit(.error(message: "Invalid or missing command on stdin", recoverable: false))
            exit(2)
        }

        switch command.cmd {
        case "scan":
            let roots = command.roots ?? []
            guard !roots.isEmpty else {
                emitter.emit(.error(message: "scan requires roots", recoverable: false))
                exit(2)
            }
            let config = ScannerConfiguration(
                roots: roots,
                excludePrefixes: command.excludePrefixes ?? SystemGuardrails.shared.excludePrefixes(),
                checkpoint: command.checkpoint,
                maxFileCount: command.maxFileCount
            )
            do {
                let result = try await scanner.scan(configuration: config, handler: emitter)
                emitter.emit(.done(
                    scanned: result.scanned,
                    bytes: result.bytes,
                    errors: result.errors,
                    checkpoint: result.checkpoint
                ))
                exit(0)
            } catch {
                emitter.emit(.error(message: error.localizedDescription, recoverable: true))
                exit(1)
            }
        case "cancel":
            await scanner.cancel()
            emitter.emit(.done(scanned: 0, bytes: 0, errors: 0, checkpoint: nil))
            exit(0)
        case "crash":
            // Intentional hard crash for isolation testing — must not kill the host app.
            fputs("ScannerWorker simulating crash\n", stderr)
            abort()
        default:
            emitter.emit(.error(message: "Unknown command \(command.cmd)", recoverable: false))
            exit(2)
        }
    }

    private static func readStdinLine() -> Data? {
        var line = Data()
        let handle = FileHandle.standardInput
        while true {
            let chunk = handle.readData(ofLength: 1)
            if chunk.isEmpty { break }
            if chunk[0] == UInt8(ascii: "\n") { break }
            line.append(chunk)
        }
        return line.isEmpty ? nil : line
    }
}
