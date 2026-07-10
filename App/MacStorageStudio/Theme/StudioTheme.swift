import SwiftUI
import MacStorageCore

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
        Group {
            if model.isScanning {
                scanningBody
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let session = model.session,
                      session.status == .completed || session.status == .crashed || session.status == .cancelled {
                completedBody(session)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isScanning)
        .animation(.easeInOut(duration: 0.15), value: model.progress.scanned)
    }

    private var scanningBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning…")
                    .font(.headline)
                Text("\(model.progress.scanned.formatted())")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.primary)
                Text("items")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormat.string(model.progress.bytes))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) {
                    Task { await model.cancelScan() }
                }
                .controlSize(.small)
            }

            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
                .tint(.accentColor)

            HStack(spacing: 6) {
                if model.progress.skippedSystem > 0 {
                    Text("\(model.progress.skippedSystem.formatted()) system skipped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.progress.skippedPermission > 0 {
                    Text("· \(model.progress.skippedPermission.formatted()) no access")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if model.progress.workerRestarts > 0 {
                    Text("· recovered \(model.progress.workerRestarts)×")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }

            if !model.progress.currentPath.isEmpty {
                Text(model.progress.currentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scan in progress, \(model.progress.scanned) items")
    }

    private func completedBody(_ session: ScanSession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: session.status == .completed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(session.status == .completed ? Color.green : Color.orange)
            Text("\(session.filesScanned.formatted()) items · \(ByteFormat.string(session.bytesScanned))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.lastSkippedPermission > 0 {
                Text("· \(model.lastSkippedPermission.formatted()) no access")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !model.hasFullDiskAccess {
                Button("Full Disk Access…") {
                    model.showAccessSheet = true
                }
                .font(.caption)
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var progressFraction: Double {
        let n = Double(max(model.progress.scanned, 0))
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
