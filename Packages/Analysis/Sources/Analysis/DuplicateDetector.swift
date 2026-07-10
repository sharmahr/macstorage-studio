import Foundation
import CryptoKit
import MacStorageCore

public struct DuplicateDetector: Sendable {
    public var minimumFileBytes: Int64
    public var maxFilesToHash: Int
    public var sampleQuickFilter: Bool

    public init(minimumFileBytes: Int64 = 100_000, maxFilesToHash: Int = 5_000, sampleQuickFilter: Bool = true) {
        self.minimumFileBytes = minimumFileBytes
        self.maxFilesToHash = maxFilesToHash
        self.sampleQuickFilter = sampleQuickFilter
    }

    /// Two-phase detection: size buckets → content hash (SHA-256). Also groups same-name same-size.
    public func findDuplicates(files: [FileEntry]) async -> [DuplicateGroup] {
        let candidates = files.filter { !$0.isDirectory && $0.size >= minimumFileBytes && !$0.isSymbolicLink }
        guard !candidates.isEmpty else { return [] }

        // Phase 1: size buckets
        var bySize: [Int64: [FileEntry]] = [:]
        for f in candidates {
            bySize[f.size, default: []].append(f)
        }
        let sizeCollisions = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
        let limited = Array(sizeCollisions.prefix(maxFilesToHash))

        // Phase 2: hash
        var byHash: [String: [FileEntry]] = [:]
        for file in limited {
            if Task.isCancelled { break }
            if let hash = hashFile(at: file.path, expectedSize: file.size) {
                byHash[hash, default: []].append(file)
            }
        }

        var groups: [DuplicateGroup] = []
        for (hash, entries) in byHash where entries.count > 1 {
            let paths = entries.map(\.path).sorted()
            let total = entries.reduce(Int64(0)) { $0 + $1.size }
            let wasted = total - (entries.map(\.size).max() ?? 0)
            groups.append(DuplicateGroup(
                contentHash: hash,
                totalBytes: total,
                wastedBytes: wasted,
                paths: paths,
                fileName: entries[0].name,
                matchKind: .contentHash
            ))
        }

        // Filename+size groups that weren't content-hashed (e.g. too many files)
        var byNameSize: [String: [FileEntry]] = [:]
        for f in candidates {
            let key = "\(f.name.lowercased())|\(f.size)"
            byNameSize[key, default: []].append(f)
        }
        for (_, entries) in byNameSize where entries.count > 1 {
            let paths = Set(entries.map(\.path))
            // skip if already covered by content hash group
            let already = groups.contains { group in
                Set(group.paths).isSuperset(of: paths) || !Set(group.paths).isDisjoint(with: paths)
            }
            if already { continue }
            let total = entries.reduce(Int64(0)) { $0 + $1.size }
            let wasted = total - (entries.first?.size ?? 0)
            groups.append(DuplicateGroup(
                contentHash: "name-size:\(entries[0].name):\(entries[0].size)",
                totalBytes: total,
                wastedBytes: wasted,
                paths: entries.map(\.path).sorted(),
                fileName: entries[0].name,
                matchKind: .sizeAndName
            ))
        }

        return groups.sorted { $0.wastedBytes > $1.wastedBytes }
    }

    /// SHA-256 of full file. For very large files, still full-hash (correctness). Cap via maxFilesToHash upstream.
    public func hashFile(at path: String, expectedSize: Int64) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while true {
                let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        } catch {
            return nil
        }
    }
}
