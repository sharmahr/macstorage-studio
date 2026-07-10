import Foundation
import MacStorageCore

public struct ScannerConfiguration: Sendable {
    public var roots: [String]
    public var excludePrefixes: [String]
    public var checkpoint: String?
    public var maxFileCount: Int?
    public var followSymlinks: Bool
    public var progressEvery: Int

    public init(
        roots: [String],
        excludePrefixes: [String] = ScanDefaults.protectedPrefixes,
        checkpoint: String? = nil,
        maxFileCount: Int? = nil,
        followSymlinks: Bool = false,
        progressEvery: Int = 50
    ) {
        self.roots = roots
        self.excludePrefixes = excludePrefixes
        self.checkpoint = checkpoint
        self.maxFileCount = maxFileCount
        self.followSymlinks = followSymlinks
        self.progressEvery = progressEvery
    }
}

public protocol ScannerEventHandler: AnyObject, Sendable {
    func scannerDidEmit(_ record: WorkerFileRecord) async
    func scannerDidProgress(scanned: Int, bytes: Int64, path: String, skippedSystem: Int, skippedPermission: Int) async
}

public actor FilesystemScanner {
    private var cancelled = false

    public init() {}

    public func cancel() {
        cancelled = true
    }

    public func scan(configuration: ScannerConfiguration, handler: any ScannerEventHandler) async throws -> (scanned: Int, bytes: Int64, errors: Int, checkpoint: String?) {
        cancelled = false

        // Parallelize independent roots when not resuming mid-tree (checkpoint makes order matter).
        if configuration.checkpoint == nil && configuration.roots.count > 1 {
            return try await scanRootsInParallel(configuration: configuration, handler: handler)
        }
        return try await scanRootsSequentially(configuration: configuration, handler: handler)
    }

    private func scanRootsInParallel(
        configuration: ScannerConfiguration,
        handler: any ScannerEventHandler
    ) async throws -> (scanned: Int, bytes: Int64, errors: Int, checkpoint: String?) {
        let roots = configuration.roots
        return try await withThrowingTaskGroup(
            of: (Int, Int64, Int, String?).self
        ) { group in
            for root in roots {
                let rootConfig = ScannerConfiguration(
                    roots: [root],
                    excludePrefixes: configuration.excludePrefixes,
                    checkpoint: nil,
                    maxFileCount: configuration.maxFileCount,
                    followSymlinks: configuration.followSymlinks,
                    progressEvery: configuration.progressEvery
                )
                group.addTask {
                    try await self.scanRootsSequentially(configuration: rootConfig, handler: handler)
                }
            }
            var scanned = 0
            var bytes: Int64 = 0
            var errors = 0
            var last: String?
            for try await part in group {
                scanned += part.0
                bytes += part.1
                errors += part.2
                if let p = part.3 { last = p }
            }
            return (scanned, bytes, errors, last)
        }
    }

    private func scanRootsSequentially(
        configuration: ScannerConfiguration,
        handler: any ScannerEventHandler
    ) async throws -> (scanned: Int, bytes: Int64, errors: Int, checkpoint: String?) {
        var scanned = 0
        var bytes: Int64 = 0
        var errors = 0
        var skipped = 0
        var lastPath: String?
        let fm = FileManager.default
        var resumePassed = configuration.checkpoint == nil
        final class PermCounter: @unchecked Sendable { var value = 0 }
        let permissionSkips = PermCounter()

        for root in configuration.roots {
            if Self.shouldSkip(path: root, excludes: configuration.excludePrefixes) {
                skipped += 1
                continue
            }
            if cancelled { break }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDir) else {
                errors += 1
                continue
            }

            if let record = Self.record(for: root, parentPath: nil) {
                await handler.scannerDidEmit(record)
                scanned += 1
                if !record.isDirectory {
                    bytes += record.allocatedSize > 0 ? record.allocatedSize : record.size
                }
                lastPath = root
            }

            guard isDir.boolValue else { continue }

            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: Self.resourceKeys,
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in
                    permissionSkips.value += 1
                    return true
                }
            ) else {
                errors += 1
                continue
            }

            while let next = enumerator.nextObject() as? URL {
                if cancelled { break }
                if let max = configuration.maxFileCount, scanned >= max { break }

                let path = next.path

                if !resumePassed {
                    if path == configuration.checkpoint {
                        resumePassed = true
                        continue
                    }
                    if let checkpoint = configuration.checkpoint, path <= checkpoint {
                        continue
                    }
                    resumePassed = true
                }

                if Self.shouldSkip(path: path, excludes: configuration.excludePrefixes) {
                    skipped += 1
                    enumerator.skipDescendants()
                    continue
                }

                if !configuration.followSymlinks {
                    if let values = try? next.resourceValues(forKeys: [.isSymbolicLinkKey]),
                       values.isSymbolicLink == true {
                        if let record = Self.record(for: path, parentPath: next.deletingLastPathComponent().path) {
                            await handler.scannerDidEmit(record)
                            scanned += 1
                            lastPath = path
                        }
                        enumerator.skipDescendants()
                        continue
                    }
                }

                guard let record = Self.record(forPathURL: next) else {
                    errors += 1
                    continue
                }

                await handler.scannerDidEmit(record)
                scanned += 1
                lastPath = path
                if !record.isDirectory {
                    bytes += record.allocatedSize > 0 ? record.allocatedSize : record.size
                }

                if scanned % configuration.progressEvery == 0 {
                    await handler.scannerDidProgress(scanned: scanned, bytes: bytes, path: path, skippedSystem: skipped, skippedPermission: permissionSkips.value)
                }
            }
        }

        await handler.scannerDidProgress(scanned: scanned, bytes: bytes, path: lastPath ?? "", skippedSystem: skipped, skippedPermission: permissionSkips.value)
        return (scanned, bytes, errors, lastPath)
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .fileSizeKey,
        .totalFileAllocatedSizeKey,
        .totalFileSizeKey,
        .creationDateKey,
        .contentModificationDateKey,
        .contentAccessDateKey,
        .fileResourceIdentifierKey,
        .fileSecurityKey,
        .linkCountKey,
        .parentDirectoryURLKey,
    ]

    public static func shouldSkip(path: String, excludes: [String]) -> Bool {
        // Scan exclusions only — do not use delete-protection (that blocks $HOME)
        if SystemGuardrails.shared.isScanExcluded(path) {
            return true
        }
        let standardized = (path as NSString).standardizingPath
        for prefix in excludes {
            if standardized == prefix || standardized.hasPrefix(prefix + "/") {
                return true
            }
        }
        return false
    }

    public static func record(for path: String, parentPath: String?) -> WorkerFileRecord? {
        record(forPathURL: URL(fileURLWithPath: path), parentOverride: parentPath)
    }

    public static func record(forPathURL url: URL, parentOverride: String? = nil) -> WorkerFileRecord? {
        let values = try? url.resourceValues(forKeys: Set(resourceKeys))
        let isSymlink = values?.isSymbolicLink ?? false
        let isDir = values?.isDirectory ?? false
        let isPackage = values?.isPackage ?? false
        let sizeNum = values?.totalFileSize ?? values?.fileSize ?? 0
        let size = Int64(sizeNum)
        let allocatedNum = values?.totalFileAllocatedSize ?? sizeNum
        let allocated = Int64(allocatedNum)
        let name = url.lastPathComponent
        let parent = parentOverride ?? url.deletingLastPathComponent().path
        let ext = url.pathExtension.isEmpty ? nil : url.pathExtension.lowercased()

        var ownerID: UInt32?
        var permissions: UInt16?
        var inode: UInt64?
        var device: UInt64?
        var linkCount: UInt16 = 1

        var st = stat()
        if stat(url.path, &st) == 0 {
            ownerID = st.st_uid
            permissions = UInt16(st.st_mode & 0o7777)
            inode = UInt64(st.st_ino)
            device = UInt64(st.st_dev)
            linkCount = UInt16(min(Int(st.st_nlink), Int(UInt16.max)))
        }

        return WorkerFileRecord(
            path: url.path,
            parentPath: parent == url.path ? nil : parent,
            name: name,
            isDirectory: isDir && !isSymlink,
            size: isDir ? 0 : size,
            allocatedSize: isDir ? 0 : allocated,
            createdAt: values?.creationDate?.timeIntervalSince1970,
            modifiedAt: values?.contentModificationDate?.timeIntervalSince1970,
            accessedAt: values?.contentAccessDate?.timeIntervalSince1970,
            ownerID: ownerID,
            permissions: permissions,
            inode: inode,
            device: device,
            linkCount: linkCount,
            isSymbolicLink: isSymlink,
            fileExtension: ext,
            isPackage: isPackage
        )
    }
}
