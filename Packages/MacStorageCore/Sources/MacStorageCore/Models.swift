import Foundation

public enum ScanStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case running
    case completed
    case failed
    case cancelled
    case crashed
}

public enum StorageCategory: String, Codable, Sendable, CaseIterable, Comparable {
    case applications
    case userFiles
    case documents
    case images
    case videos
    case audio
    case downloads
    case archives
    case logs
    case temporary
    case cache
    case browserCache
    case developerCache
    case buildArtifacts
    case sourceCode
    case virtualMachines
    case containers
    case databases
    case backups
    case hidden
    case system
    case unknown

    public var displayName: String {
        switch self {
        case .applications: return "Applications"
        case .userFiles: return "User Files"
        case .documents: return "Documents"
        case .images: return "Images"
        case .videos: return "Videos"
        case .audio: return "Audio"
        case .downloads: return "Downloads"
        case .archives: return "Archives"
        case .logs: return "Logs"
        case .temporary: return "Temporary Files"
        case .cache: return "Cache"
        case .browserCache: return "Browser Cache"
        case .developerCache: return "Developer Cache"
        case .buildArtifacts: return "Build Artifacts"
        case .sourceCode: return "Source Code"
        case .virtualMachines: return "Virtual Machines"
        case .containers: return "Containers"
        case .databases: return "Databases"
        case .backups: return "Backups"
        case .hidden: return "Hidden Files"
        case .system: return "System Files"
        case .unknown: return "Unknown"
        }
    }

    public static func < (lhs: StorageCategory, rhs: StorageCategory) -> Bool {
        lhs.displayName < rhs.displayName
    }
}

public enum RiskLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case safe
    case low
    case medium
    case high
    case critical

    public var displayName: String {
        rawValue.capitalized
    }

    private var rank: Int {
        switch self {
        case .safe: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .critical: return 4
        }
    }

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct ScanSession: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: ScanStatus
    public var roots: [String]
    public var filesScanned: Int
    public var bytesScanned: Int64
    public var errorMessage: String?
    public var checkpointPath: String?

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        status: ScanStatus = .pending,
        roots: [String],
        filesScanned: Int = 0,
        bytesScanned: Int64 = 0,
        errorMessage: String? = nil,
        checkpointPath: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.roots = roots
        self.filesScanned = filesScanned
        self.bytesScanned = bytesScanned
        self.errorMessage = errorMessage
        self.checkpointPath = checkpointPath
    }
}

public struct FileEntry: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var rowID: Int64?
    public var id: String { path }
    public var sessionID: UUID
    public var path: String
    public var parentPath: String?
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var allocatedSize: Int64
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var accessedAt: Date?
    public var ownerID: UInt32?
    public var permissions: UInt16?
    public var inode: UInt64?
    public var device: UInt64?
    public var linkCount: UInt16
    public var isSymbolicLink: Bool
    public var fileExtension: String?
    public var category: StorageCategory
    public var isPackage: Bool

    public init(
        rowID: Int64? = nil,
        sessionID: UUID,
        path: String,
        parentPath: String? = nil,
        name: String,
        isDirectory: Bool,
        size: Int64 = 0,
        allocatedSize: Int64 = 0,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        accessedAt: Date? = nil,
        ownerID: UInt32? = nil,
        permissions: UInt16? = nil,
        inode: UInt64? = nil,
        device: UInt64? = nil,
        linkCount: UInt16 = 1,
        isSymbolicLink: Bool = false,
        fileExtension: String? = nil,
        category: StorageCategory = .unknown,
        isPackage: Bool = false
    ) {
        self.rowID = rowID
        self.sessionID = sessionID
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
        self.category = category
        self.isPackage = isPackage
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
        hasher.combine(sessionID)
    }
}

public struct DirectoryAggregate: Identifiable, Codable, Sendable, Equatable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var totalSize: Int64
    public var totalAllocated: Int64
    public var fileCount: Int
    public var childCount: Int
    public var category: StorageCategory

    public init(
        path: String,
        name: String,
        totalSize: Int64,
        totalAllocated: Int64,
        fileCount: Int,
        childCount: Int,
        category: StorageCategory = .unknown
    ) {
        self.path = path
        self.name = name
        self.totalSize = totalSize
        self.totalAllocated = totalAllocated
        self.fileCount = fileCount
        self.childCount = childCount
        self.category = category
    }
}

public struct CleanupRecommendation: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var sessionID: UUID
    public var path: String
    public var title: String
    public var reason: String
    public var explanation: String
    public var confidence: Double
    public var reclaimableBytes: Int64
    public var owner: String?
    public var risk: RiskLevel
    public var regenerable: Bool
    public var category: StorageCategory
    public var dependencies: [String]

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        path: String,
        title: String,
        reason: String,
        explanation: String,
        confidence: Double,
        reclaimableBytes: Int64,
        owner: String? = nil,
        risk: RiskLevel,
        regenerable: Bool,
        category: StorageCategory,
        dependencies: [String] = []
    ) {
        self.id = id
        self.sessionID = sessionID
        self.path = path
        self.title = title
        self.reason = reason
        self.explanation = explanation
        self.confidence = confidence
        self.reclaimableBytes = reclaimableBytes
        self.owner = owner
        self.risk = risk
        self.regenerable = regenerable
        self.category = category
        self.dependencies = dependencies
    }
}

public struct VolumeInfo: Identifiable, Codable, Sendable, Equatable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var totalCapacity: Int64
    public var availableCapacity: Int64
    public var isInternal: Bool
    public var isEjectable: Bool

    public var usedCapacity: Int64 { max(0, totalCapacity - availableCapacity) }

    public init(
        name: String,
        path: String,
        totalCapacity: Int64,
        availableCapacity: Int64,
        isInternal: Bool,
        isEjectable: Bool
    ) {
        self.name = name
        self.path = path
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.isInternal = isInternal
        self.isEjectable = isEjectable
    }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = .useAll
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }
}
