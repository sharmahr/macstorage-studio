import SwiftUI
import MacStorageCore

struct CleanupView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selectedRecommendation: CleanupRecommendation?
    @Binding var confirmTrash: Bool

    var body: some View {
        Group {
            if model.recommendations.isEmpty {
                ContentUnavailableView(
                    "No Recommendations",
                    systemImage: "trash",
                    description: Text("Complete a scan to see safe cleanup suggestions.")
                )
            } else {
                List {
                    ForEach(Array(model.recommendations), id: \.id) { rec in
                        recommendationRow(rec)
                    }
                }
            }
        }
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
