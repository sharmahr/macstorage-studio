import SwiftUI
import MacStorageCore

/// Thin helpers only — prefer system styles (`.primary`, `.secondary`, `.blue`) in views.
enum StudioTheme {
    static func color(for kind: GraphNodeKind) -> Color {
        switch kind {
        case .volume: return .blue
        case .application: return .indigo
        case .directory: return .blue
        case .package: return .teal
        case .cache: return .orange
        case .file: return .secondary
        case .orphan: return .red
        }
    }
}

struct ScanProgressBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.isScanning {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning…")
                        .font(.headline)
                    Spacer()
                    Text(ByteFormat.string(model.progress.bytes))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Cancel") {
                        Task { await model.cancelScan() }
                    }
                    .controlSize(.small)
                }

                // Indeterminate-feeling continuous bar with file count context
                ProgressView(value: progressFraction) {
                    EmptyView()
                } currentValueLabel: {
                    HStack {
                        Text("\(model.progress.scanned.formatted()) items")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.progress.workerRestarts > 0 {
                            Text("Recovered \(model.progress.workerRestarts)×")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .progressViewStyle(.linear)

                if !model.progress.currentPath.isEmpty {
                    Text(model.progress.currentPath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.progress.currentPath)
                }
            }
            .padding(12)
            .background(.bar)
            .overlay(alignment: .bottom) {
                Divider()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Scan in progress")
            .accessibilityValue("\(model.progress.scanned) items, \(ByteFormat.string(model.progress.bytes))")
        }
    }

    /// Smooth indeterminate-ish fraction from scanned count (asymptotic).
    private var progressFraction: Double {
        let n = Double(max(model.progress.scanned, 0))
        // Asymptotic curve so bar keeps moving without a known total
        return min(0.95, 1 - exp(-n / 8000))
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
