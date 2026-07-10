import SwiftUI
import MacStorageCore

struct CleanupView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selectedRecommendation: CleanupRecommendation?
    @Binding var confirmTrash: Bool

    private var filteredRecommendations: [CleanupRecommendation] {
        model.recommendations.filter { rec in
            // Lightweight reuse of path/name/size filters
            let entry = FileEntry(
                sessionID: rec.sessionID,
                path: rec.path,
                name: (rec.path as NSString).lastPathComponent,
                isDirectory: true,
                size: rec.reclaimableBytes,
                category: rec.category
            )
            return model.scanFilters.matches(entry)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterBarView(filters: $model.scanFilters) {}
            Group {
                if filteredRecommendations.isEmpty {
                    ContentUnavailableView(
                        model.recommendations.isEmpty ? "No Recommendations" : "No Matches",
                        systemImage: "trash",
                        description: Text(
                            model.recommendations.isEmpty
                                ? "Complete a scan to see safe cleanup suggestions."
                                : "No recommendations match the current filters."
                        )
                    )
                } else {
                    List {
                        ForEach(Array(filteredRecommendations), id: \.id) { rec in
                            recommendationRow(rec)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Cleanup")
    }

    @ViewBuilder
    private func recommendationRow(_ rec: CleanupRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(rec.title)
                    .font(.headline)
                Spacer()
                Text(ByteFormat.string(rec.reclaimableBytes))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(rec.reason)
                .foregroundStyle(.secondary)
            Text(rec.path)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .textSelection(.enabled)
            HStack {
                Text(rec.risk.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(Int(rec.confidence * 100))% confidence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if rec.regenerable {
                    Text("· Regenerable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Move to Trash…") {
                    selectedRecommendation = rec
                    confirmTrash = true
                }
            }
            DisclosureGroup("Explanation") {
                Text(rec.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }
}
