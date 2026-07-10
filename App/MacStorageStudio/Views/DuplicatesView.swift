import SwiftUI
import MacStorageCore

struct DuplicatesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: DuplicateGroup?
    @State private var confirmPath: String?
    @State private var minSizeMB: Double = 0.1

    private var groups: [DuplicateGroup] { model.duplicateGroups }
    private var totalWasted: Int64 { groups.reduce(0) { $0 + $1.wastedBytes } }

    var body: some View {
        HSplitView {
            groupList
                .frame(minWidth: 240, idealWidth: 300, maxWidth: .infinity)
                .frame(maxHeight: .infinity)
            detail
                .frame(minWidth: 320, idealWidth: 420, maxWidth: .infinity)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Duplicates")
        .toolbar {
            ToolbarItem {
                HStack {
                    Text("Min \(String(format: "%.1f", minSizeMB)) MB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $minSizeMB, in: 0.1...50)
                        .frame(width: 100)
                }
            }
            ToolbarItem {
                Button {
                    Task { await model.runDuplicateDetection(minimumBytes: Int64(minSizeMB * 1_000_000)) }
                } label: {
                    if model.isFindingDuplicates {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Find Duplicates", systemImage: "doc.on.doc")
                    }
                }
                .disabled(model.isFindingDuplicates || model.session == nil)
            }
        }
        .confirmationDialog(
            "Move to Trash?",
            isPresented: Binding(
                get: { confirmPath != nil },
                set: { if !$0 { confirmPath = nil } }
            ),
            presenting: confirmPath
        ) { path in
            Button("Move to Trash", role: .destructive) {
                Task { await model.trashPath(path, bytes: 0) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { path in
            Text(path)
        }
        .overlay {
            if groups.isEmpty && !model.isFindingDuplicates {
                EmptyStateView(
                    systemImage: "doc.on.doc",
                    title: "No Duplicates",
                    message: "Detect identical content using SHA-256 hashing after a scan.",
                    actionTitle: model.session == nil ? "Scan" : "Find Duplicates",
                    action: {
                        Task {
                            if model.session == nil {
                                await model.startScan()
                            } else {
                                await model.runDuplicateDetection(minimumBytes: Int64(minSizeMB * 1_000_000))
                            }
                        }
                    }
                )
            } else if model.isFindingDuplicates && groups.isEmpty {
                ProgressView("Hashing files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var groupList: some View {
        List(groups, selection: $selected) { group in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.fileName)
                    Text(group.matchKind == .contentHash ? "Content match" : "Name & size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("×\(group.paths.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(ByteFormat.string(group.wastedBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .tag(group)
        }
        .safeAreaInset(edge: .top) {
            if !groups.isEmpty {
                Text("\(groups.count) groups · \(ByteFormat.string(totalWasted)) potentially wasted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.bar)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selected {
            List {
                Section {
                    LabeledContent("File", value: selected.fileName)
                    LabeledContent("Copies", value: "\(selected.paths.count)")
                    LabeledContent("Wasted") {
                        Text(ByteFormat.string(selected.wastedBytes)).monospacedDigit()
                    }
                    LabeledContent("Match") {
                        Text(selected.matchKind == .contentHash ? "SHA-256" : "Name + size")
                    }
                    if selected.matchKind == .contentHash {
                        Text(selected.contentHash)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Group")
                }

                Section("Paths") {
                    ForEach(Array(selected.paths.enumerated()), id: \.element) { index, path in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(index == 0 ? "Keep" : "Duplicate")
                                    .font(.caption)
                                    .foregroundStyle(index == 0 ? .secondary : .primary)
                                Text(path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            if index > 0 {
                                Button("Trash", role: .destructive) {
                                    confirmPath = path
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        } else if !groups.isEmpty {
            ContentUnavailableView(
                "Select a Group",
                systemImage: "sidebar.left",
                description: Text("Choose a duplicate group to inspect paths.")
            )
        } else {
            Color.clear
        }
    }
}
