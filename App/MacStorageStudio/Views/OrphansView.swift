import SwiftUI
import MacStorageCore

struct OrphansView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedOrphan: OrphanArtifact?
    @State private var confirm = false
    @State private var kindFilter: OrphanKind?
    @State private var query = ""

    private var report: OrphanReport { model.orphanReport }

    private var filtered: [OrphanArtifact] {
        report.orphans.filter { o in
            if let kindFilter, o.kind != kindFilter { return false }
            if !query.isEmpty {
                return o.name.localizedCaseInsensitiveContains(query)
                    || o.path.localizedCaseInsensitiveContains(query)
            }
            return true
        }
    }

    var body: some View {
        HSplitView {
            appsList
                .frame(minWidth: 240, idealWidth: 280)
            orphansList
                .frame(minWidth: 360)
        }
        .navigationTitle("Orphans")
        .toolbar {
            ToolbarItem {
                Picker("Kind", selection: $kindFilter) {
                    Text("All").tag(OrphanKind?.none)
                    ForEach(OrphanKind.allCases, id: \.self) { k in
                        Text(k.displayName).tag(Optional(k))
                    }
                }
                .frame(width: 140)
            }
            ToolbarItem {
                Button {
                    Task { await model.runOrphanAnalysis() }
                } label: {
                    if model.isAnalyzingOrphans {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Analyze", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isAnalyzingOrphans || model.session == nil)
            }
        }
        .searchable(text: $query, prompt: "Filter orphans")
        .confirmationDialog("Move to Trash?", isPresented: $confirm, presenting: selectedOrphan) { orphan in
            Button("Move to Trash", role: .destructive) {
                Task { await model.trashPath(orphan.path, bytes: orphan.bytes) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { orphan in
            Text("\(orphan.path)\n\(ByteFormat.string(orphan.bytes))")
        }
        .overlay {
            if report.applications.isEmpty && report.orphans.isEmpty {
                EmptyStateView(
                    systemImage: "app.badge.checkmark",
                    title: "No Analysis Yet",
                    message: "Map installed apps to Library support data and find leftovers.",
                    actionTitle: model.session == nil ? "Scan" : "Analyze",
                    action: {
                        Task {
                            if model.session == nil {
                                await model.startScan()
                            } else {
                                await model.runOrphanAnalysis()
                            }
                        }
                    }
                )
            }
        }
    }

    private var appsList: some View {
        List(report.applications) { app in
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                Text(app.bundleID ?? app.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if app.totalSupportBytes > 0 {
                    Text(ByteFormat.string(app.totalSupportBytes) + " support data")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var orphansList: some View {
        List(filtered) { orphan in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(orphan.name, systemImage: orphan.kind.systemImage)
                    Spacer()
                    Text("\(Int(orphan.confidence * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(ByteFormat.string(orphan.bytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(orphan.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(orphan.reason)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                HStack {
                    Text(orphan.kind.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Move to Trash…", role: .destructive) {
                        selectedOrphan = orphan
                        confirm = true
                    }
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 2)
        }
    }
}
