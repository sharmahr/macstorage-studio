import Foundation
import MacStorageCore

public enum CleanupError: Error, LocalizedError {
    case notFound(String)
    case declined
    case trashFailed(String)
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let p): return "Path not found: \(p)"
        case .declined: return "User declined cleanup"
        case .trashFailed(let s): return "Failed to move to Trash: \(s)"
        case .unsafePath(let p): return "Blocked by system guardrail: \(p)"
        }
    }
}

public struct CleanupResult: Sendable, Equatable {
    public var path: String
    public var trashedURL: URL?
    public var bytesReclaimed: Int64

    public init(path: String, trashedURL: URL?, bytesReclaimed: Int64) {
        self.path = path
        self.trashedURL = trashedURL
        self.bytesReclaimed = bytesReclaimed
    }
}

/// Moves items to Trash only. Never touches OS / guardrail-protected paths.
public struct CleanupEngine: Sendable {
    public init() {}

    public func isProtected(_ path: String) -> Bool {
        SystemGuardrails.shared.isProtected(path)
    }

    public func protectionReason(_ path: String) -> String? {
        let eval = SystemGuardrails.shared.evaluation(for: path)
        guard eval.isProtected else { return nil }
        return eval.matchedTitles.joined(separator: ", ")
    }

    public func trash(path: String, reclaimableBytes: Int64) throws -> CleanupResult {
        if isProtected(path) {
            throw CleanupError.unsafePath(path)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw CleanupError.notFound(path)
        }
        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: path),
                resultingItemURL: &resultingURL
            )
        } catch {
            throw CleanupError.trashFailed(error.localizedDescription)
        }
        return CleanupResult(
            path: path,
            trashedURL: resultingURL as URL?,
            bytesReclaimed: reclaimableBytes
        )
    }

    public func trash(recommendation: CleanupRecommendation) throws -> CleanupResult {
        try trash(path: recommendation.path, reclaimableBytes: recommendation.reclaimableBytes)
    }
}
