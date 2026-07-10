import Foundation

/// Line-delimited JSON protocol between the app and the isolated ScannerWorker process.
public enum WorkerMessage: Codable, Sendable, Equatable {
    case hello(version: Int)
    case progress(scanned: Int, bytes: Int64, path: String, skippedSystem: Int)
    case entry(WorkerFileRecord)
    case done(scanned: Int, bytes: Int64, errors: Int, checkpoint: String?)
    case error(message: String, recoverable: Bool)
    case log(String)

    private enum CodingKeys: String, CodingKey {
        case type, version, scanned, bytes, path, entry, errors, checkpoint, message, recoverable, text, skippedSystem
    }

    private enum Kind: String, Codable {
        case hello, progress, entry, done, error, log
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let version):
            try container.encode(Kind.hello.rawValue, forKey: .type)
            try container.encode(version, forKey: .version)
        case .progress(let scanned, let bytes, let path, let skippedSystem):
            try container.encode(Kind.progress.rawValue, forKey: .type)
            try container.encode(scanned, forKey: .scanned)
            try container.encode(bytes, forKey: .bytes)
            try container.encode(path, forKey: .path)
            try container.encode(skippedSystem, forKey: .skippedSystem)
        case .entry(let record):
            try container.encode(Kind.entry.rawValue, forKey: .type)
            try container.encode(record, forKey: .entry)
        case .done(let scanned, let bytes, let errors, let checkpoint):
            try container.encode(Kind.done.rawValue, forKey: .type)
            try container.encode(scanned, forKey: .scanned)
            try container.encode(bytes, forKey: .bytes)
            try container.encode(errors, forKey: .errors)
            try container.encodeIfPresent(checkpoint, forKey: .checkpoint)
        case .error(let message, let recoverable):
            try container.encode(Kind.error.rawValue, forKey: .type)
            try container.encode(message, forKey: .message)
            try container.encode(recoverable, forKey: .recoverable)
        case .log(let text):
            try container.encode(Kind.log.rawValue, forKey: .type)
            try container.encode(text, forKey: .text)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch Kind(rawValue: type) {
        case .hello:
            self = .hello(version: try container.decode(Int.self, forKey: .version))
        case .progress:
            self = .progress(
                scanned: try container.decode(Int.self, forKey: .scanned),
                bytes: try container.decode(Int64.self, forKey: .bytes),
                path: try container.decode(String.self, forKey: .path),
                skippedSystem: try container.decodeIfPresent(Int.self, forKey: .skippedSystem) ?? 0
            )
        case .entry:
            self = .entry(try container.decode(WorkerFileRecord.self, forKey: .entry))
        case .done:
            self = .done(
                scanned: try container.decode(Int.self, forKey: .scanned),
                bytes: try container.decode(Int64.self, forKey: .bytes),
                errors: try container.decode(Int.self, forKey: .errors),
                checkpoint: try container.decodeIfPresent(String.self, forKey: .checkpoint)
            )
        case .error:
            self = .error(
                message: try container.decode(String.self, forKey: .message),
                recoverable: try container.decode(Bool.self, forKey: .recoverable)
            )
        case .log:
            self = .log(try container.decode(String.self, forKey: .text))
        case .none:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown message type \(type)")
        }
    }
}

public struct WorkerFileRecord: Codable, Sendable, Equatable {
    public var path: String
    public var parentPath: String?
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var allocatedSize: Int64
    public var createdAt: TimeInterval?
    public var modifiedAt: TimeInterval?
    public var accessedAt: TimeInterval?
    public var ownerID: UInt32?
    public var permissions: UInt16?
    public var inode: UInt64?
    public var device: UInt64?
    public var linkCount: UInt16
    public var isSymbolicLink: Bool
    public var fileExtension: String?
    public var isPackage: Bool

    public init(
        path: String,
        parentPath: String? = nil,
        name: String,
        isDirectory: Bool,
        size: Int64,
        allocatedSize: Int64,
        createdAt: TimeInterval? = nil,
        modifiedAt: TimeInterval? = nil,
        accessedAt: TimeInterval? = nil,
        ownerID: UInt32? = nil,
        permissions: UInt16? = nil,
        inode: UInt64? = nil,
        device: UInt64? = nil,
        linkCount: UInt16 = 1,
        isSymbolicLink: Bool = false,
        fileExtension: String? = nil,
        isPackage: Bool = false
    ) {
        self.path = path
        self.parentPath = parentPath
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.allocatedSize = allocatedSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.accessedAt = accessedAt
        self.ownerID = ownerID
        self.permissions = permissions
        self.inode = inode
        self.device = device
        self.linkCount = linkCount
        self.isSymbolicLink = isSymbolicLink
        self.fileExtension = fileExtension
        self.isPackage = isPackage
    }
}

public struct WorkerCommand: Codable, Sendable, Equatable {
    public var cmd: String
    public var roots: [String]?
    public var excludePrefixes: [String]?
    public var checkpoint: String?
    public var maxFileCount: Int?

    public init(
        cmd: String,
        roots: [String]? = nil,
        excludePrefixes: [String]? = nil,
        checkpoint: String? = nil,
        maxFileCount: Int? = nil
    ) {
        self.cmd = cmd
        self.roots = roots
        self.excludePrefixes = excludePrefixes
        self.checkpoint = checkpoint
        self.maxFileCount = maxFileCount
    }

    public static func scan(
        roots: [String],
        excludePrefixes: [String] = ScanDefaults.protectedPrefixes,
        checkpoint: String? = nil,
        maxFileCount: Int? = nil
    ) -> WorkerCommand {
        WorkerCommand(
            cmd: "scan",
            roots: roots,
            excludePrefixes: excludePrefixes,
            checkpoint: checkpoint,
            maxFileCount: maxFileCount
        )
    }

    public static var cancel: WorkerCommand { WorkerCommand(cmd: "cancel") }
}

public enum ScanDefaults {
    /// Resolved from interactive SystemGuardrails (mandatory OS paths always included).
    public static var protectedPrefixes: [String] {
        SystemGuardrails.shared.excludePrefixes()
    }

    public static let protocolVersion = 1
}
