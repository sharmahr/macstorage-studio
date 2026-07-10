import SwiftUI
import AppKit
import MacStorageCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedRecommendation: CleanupRecommendation?
    @State private var confirmTrash = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            NavigationStack {
                ZStack(alignment: .top) {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    VStack(spacing: 0) {
                        ScanProgressBanner()
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(model.isScanning || model.session != nil)
                }
                .toolbar { toolbar }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .preferredColorScheme(model.preferredColorScheme)
        .alert("Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            "Move to Trash?",
            isPresented: $confirmTrash,
            presenting: selectedRecommendation
        ) { rec in
            Button("Move to Trash", role: .destructive) {
                Task { await model.trash(recommendation: rec) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { rec in
            Text("\(rec.title)\n\(rec.path)\n\(ByteFormat.string(rec.reclaimableBytes))")
        }
        .sheet(isPresented: $model.showAccessSheet) {
            AccessPermissionView()
                .environmentObject(model)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAccessState()
            if model.allowAllAccess {
                model.roots = AccessController.shared.scanRoots()
            }
        }
    }

    private var sidebar: some View {
        List(selection: $model.destination) {
            Section("Browse") {
                ForEach([StudioDestination.overview, .hierarchy, .graph, .search], id: \.self) { dest in
                    Label(dest.title, systemImage: dest.systemImage)
                        .labelStyle(.titleAndIcon)
                        .tag(dest)
                }
            }

            Section("Intelligence") {
                ForEach([StudioDestination.history, .orphans, .duplicates, .cleanup], id: \.self) { dest in
                    Label(dest.title, systemImage: dest.systemImage)
                        .labelStyle(.titleAndIcon)
                        .tag(dest)
                }
            }

            Section("Safety") {
                Label(StudioDestination.guardrails.title, systemImage: StudioDestination.guardrails.systemImage)
                    .labelStyle(.titleAndIcon)
                    .tag(StudioDestination.guardrails)
            }

            Section("Access") {
                if model.allowAllAccess && model.hasFullDiskAccess {
                    Label("All apps allowed", systemImage: "checkmark.shield")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                } else if model.allowAllAccess {
                    Button {
                        model.showAccessSheet = true
                    } label: {
                        Label("Finish Full Disk Access…", systemImage: "exclamationmark.shield")
                            .labelStyle(.titleAndIcon)
                    }
                } else {
                    Button {
                        model.showAccessSheet = true
                    } label: {
                        Label("Allow All Access…", systemImage: "lock.shield")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }

            Section("Volumes") {
                ForEach(model.volumes) { vol in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(vol.name)
                            .lineLimit(1)
                        ProgressView(
                            value: Double(vol.usedCapacity),
                            total: Double(max(vol.totalCapacity, 1))
                        )
                        Text("\(ByteFormat.string(vol.usedCapacity)) of \(ByteFormat.string(vol.totalCapacity))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }

            if let note = model.lastCrashNote {
                Section("Scanner") {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.bar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.destination {
        case .overview:
            OverviewView()
        case .hierarchy:
            HierarchyView()
        case .graph:
            GraphCanvasView()
        case .history:
            HistoryTrendsView()
        case .orphans:
            OrphansView()
        case .duplicates:
            DuplicatesView()
        case .cleanup:
            CleanupView(selectedRecommendation: $selectedRecommendation, confirmTrash: $confirmTrash)
        case .search:
            SearchView()
        case .guardrails:
            GuardrailsView()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await model.startScan(resume: false) }
            } label: {
                Label("Scan", systemImage: "play.fill")
            }
            .disabled(model.isScanning)
            .help("Start a new filesystem scan")

            Button {
                Task { await model.resumeScan() }
            } label: {
                Label("Resume", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning || model.session?.checkpointPath == nil)
            .help("Resume from last checkpoint")

            Button {
                Task { await model.cancelScan() }
            } label: {
                Label("Cancel", systemImage: "stop.fill")
            }
            .disabled(!model.isScanning)

            Button {
                Task { await model.testWorkerCrashIsolation() }
            } label: {
                Label("Test Isolation", systemImage: "bolt.shield")
            }
            .help("Verify scanner crash isolation")
        }
    }
}

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            Section {
                LabeledContent("Status", value: model.session?.status.rawValue.capitalized ?? "No scan")
                LabeledContent("Items") {
                    Text("\(model.session?.filesScanned ?? 0)")
                        .monospacedDigit()
                }
                LabeledContent("Size") {
                    Text(ByteFormat.string(model.session?.bytesScanned ?? 0))
                        .monospacedDigit()
                }
                LabeledContent("Orphans") {
                    Text(ByteFormat.string(model.orphanReport.totalOrphanBytes))
                        .monospacedDigit()
                }
                LabeledContent("Duplicate waste") {
                    Text(ByteFormat.string(model.duplicateGroups.reduce(0) { $0 + $1.wastedBytes }))
                        .monospacedDigit()
                }
            } header: {
                Text("Summary")
            } footer: {
                Text("Scans stay on this Mac. Nothing is uploaded.")
            }

            if !model.categoryBreakdown.isEmpty {
                Section("Categories") {
                    ForEach(model.categoryBreakdown, id: \.0.rawValue) { item in
                        LabeledContent(item.0.displayName) {
                            HStack(spacing: 8) {
                                Text("\(item.2)")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                    .monospacedDigit()
                                Text(ByteFormat.string(item.1))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }

            if !model.largestFiles.isEmpty {
                Section("Largest Files") {
                    ForEach(model.largestFiles.prefix(15), id: \.path) { file in
                        LabeledContent(file.name) {
                            Text(ByteFormat.string(file.size))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .help(file.path)
                    }
                }
            }

            Section("Actions") {
                Button("Scan Storage") {
                    Task { await model.startScan() }
                }
                .disabled(model.isScanning)

                Button("Open Graph") { model.destination = .graph }
                Button("Find Orphans") {
                    model.destination = .orphans
                    Task { await model.runOrphanAnalysis() }
                }
                .disabled(model.session == nil)
                Button("Find Duplicates") {
                    model.destination = .duplicates
                    Task { await model.runDuplicateDetection() }
                }
                .disabled(model.session == nil)
                Button("View History") {
                    model.destination = .history
                    Task { await model.refreshHistory() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Overview")
    }
}

// MARK: - Hierarchy

struct HierarchyView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            FilterBarView(filters: $model.scanFilters) {
                model.applyFiltersToHierarchy()
            }
            List(model.hierarchy, id: \.path) { entry in
            Button {
                if entry.isDirectory {
                    Task { await model.loadChildren(of: entry.path) }
                }
            } label: {
                HStack {
                    Label {
                        VStack(alignment: .leading) {
                            Text(entry.name)
                                .foregroundStyle(.primary)
                            Text(entry.category.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: entry.isDirectory ? "folder" : "doc")
                            .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                    }
                    Spacer()
                    Text(ByteFormat.string(entry.size))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if entry.isDirectory {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Hierarchy")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if model.selectedPath != nil {
                    Button("Enclosing Folder") {
                        if let path = model.selectedPath {
                            let parent = (path as NSString).deletingLastPathComponent
                            Task { await model.loadChildren(of: parent.isEmpty ? nil : parent) }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if let path = model.selectedPath {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
        .overlay {
            if model.hierarchy.isEmpty {
                ContentUnavailableView(
                    model.scanFilters.isActive ? "No Matches" : "No Items",
                    systemImage: model.scanFilters.isActive ? "line.3.horizontal.decrease.circle" : "folder",
                    description: Text(
                        model.session == nil
                            ? "Run a scan to browse folders."
                            : (model.scanFilters.isActive
                               ? "Try clearing filters or broadening the query."
                               : "This folder has no scanned children.")
                    )
                )
            }
        }
    }
}

// MARK: - Search

struct SearchView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            FilterBarView(filters: $model.scanFilters) {
                Task { await model.runSearch() }
            }
            List(model.searchResults, id: \.path) { file in
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                Text(file.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(ByteFormat.string(file.size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Search")
        .searchable(text: $model.searchQuery, prompt: "File or folder name")
        .onSubmit(of: .search) {
            Task { await model.runSearch() }
        }
        .onChange(of: model.searchQuery) { _, newValue in
            if newValue.isEmpty { model.searchResults = [] }
        }
        .toolbar {
            ToolbarItem {
                Button("Search") {
                    Task { await model.runSearch() }
                }
                .disabled(model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .overlay {
            if model.searchResults.isEmpty {
                if model.searchQuery.isEmpty {
                    ContentUnavailableView(
                        "Search Files",
                        systemImage: "magnifyingglass",
                        description: Text("Search scanned file and folder names.")
                    )
                } else {
                    ContentUnavailableView.search(text: model.searchQuery)
                }
            }
        }
    }
}
