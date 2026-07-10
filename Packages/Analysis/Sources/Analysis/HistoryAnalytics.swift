import Foundation
import MacStorageCore

public struct HistoryAnalytics: Sendable {
    public init() {}

    public func buildReport(
        sessions: [ScanSession],
        categoryBySession: [UUID: [(StorageCategory, Int64, Int)]]
    ) -> HistoryReport {
        let completed = sessions
            .filter { $0.status == .completed || $0.status == .crashed || $0.filesScanned > 0 }
            .sorted { $0.startedAt < $1.startedAt }

        var snapshots: [ScanSnapshot] = []
        var trend: [TrendPoint] = []

        for s in completed {
            var totals: [String: Int64] = [:]
            if let cats = categoryBySession[s.id] {
                for (cat, bytes, _) in cats {
                    totals[cat.rawValue] = bytes
                }
            }
            snapshots.append(ScanSnapshot(
                id: s.id,
                startedAt: s.startedAt,
                finishedAt: s.finishedAt,
                status: s.status,
                filesScanned: s.filesScanned,
                bytesScanned: s.bytesScanned,
                categoryTotals: totals
            ))
            trend.append(TrendPoint(
                sessionID: s.id,
                date: s.finishedAt ?? s.startedAt,
                totalBytes: s.bytesScanned,
                fileCount: s.filesScanned
            ))
        }

        var deltas: [CategoryDelta] = []
        if snapshots.count >= 2 {
            let prev = snapshots[snapshots.count - 2]
            let curr = snapshots[snapshots.count - 1]
            let keys = Set(prev.categoryTotals.keys).union(curr.categoryTotals.keys)
            for key in keys {
                let cat = StorageCategory(rawValue: key) ?? .unknown
                deltas.append(CategoryDelta(
                    category: cat,
                    previousBytes: prev.categoryTotals[key] ?? 0,
                    currentBytes: curr.categoryTotals[key] ?? 0
                ))
            }
        }

        let growth = deltas.filter { $0.deltaBytes > 0 }.sorted { $0.deltaBytes > $1.deltaBytes }
        let shrink = deltas.filter { $0.deltaBytes < 0 }.sorted { $0.deltaBytes < $1.deltaBytes }

        return HistoryReport(
            snapshots: snapshots.reversed(),
            trend: trend,
            categoryDeltas: deltas.sorted { abs($0.deltaBytes) > abs($1.deltaBytes) },
            largestGrowth: Array(growth.prefix(8)),
            largestShrink: Array(shrink.prefix(8))
        )
    }
}
