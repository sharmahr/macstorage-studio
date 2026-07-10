import Foundation

public struct ScanFilters: Equatable, Sendable {
    public var query: String
    public var category: StorageCategory?
    public var minBytes: Int64
    public var onlyFiles: Bool
    public var onlyDirectories: Bool
    public var extensionsCSV: String

    public init(
        query: String = "",
        category: StorageCategory? = nil,
        minBytes: Int64 = 0,
        onlyFiles: Bool = false,
        onlyDirectories: Bool = false,
        extensionsCSV: String = ""
    ) {
        self.query = query
        self.category = category
        self.minBytes = minBytes
        self.onlyFiles = onlyFiles
        self.onlyDirectories = onlyDirectories
        self.extensionsCSV = extensionsCSV
    }

    public var isActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || category != nil
            || minBytes > 0
            || onlyFiles
            || onlyDirectories
            || !extensionList.isEmpty
    }

    public var extensionList: [String] {
        extensionsCSV
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
    }

    public func matches(_ entry: FileEntry) -> Bool {
        if onlyFiles && entry.isDirectory { return false }
        if onlyDirectories && !entry.isDirectory { return false }
        if entry.size < minBytes { return false }
        if let category, entry.category != category { return false }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let hay = (entry.name + " " + entry.path)
            if hay.range(of: q, options: .caseInsensitive) == nil {
                return false
            }
        }
        let exts = extensionList
        if !exts.isEmpty {
            let ext = (entry.fileExtension ?? "").lowercased()
            if !exts.contains(ext) { return false }
        }
        return true
    }

    public func apply(_ entries: [FileEntry]) -> [FileEntry] {
        guard isActive else { return entries }
        return entries.filter(matches)
    }
}
