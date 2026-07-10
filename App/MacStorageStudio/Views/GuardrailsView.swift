import SwiftUI
import MacStorageCore

struct GuardrailsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var probePath = ""
    @State private var probeResult: SystemGuardrails.Evaluation?
    @State private var confirmDisable: GuardrailRule?

    private var guardrails: SystemGuardrails { SystemGuardrails.shared }

    var body: some View {
        List {
            Section {
                Text("macOS system and SIP-protected locations are never scanned or moved to Trash. Mandatory rules cannot be turned off.")
                    .foregroundStyle(.secondary)
                LabeledContent("Active rules") {
                    Text("\(model.guardrailRules.filter(\.enabled).count) of \(model.guardrailRules.count)")
                        .monospacedDigit()
                }
                LabeledContent("Excluded prefixes") {
                    Text("\(model.activeExcludePrefixes.count)")
                        .monospacedDigit()
                }
            } header: {
                Text("Overview")
            }

            Section("Check a Path") {
                HStack {
                    TextField("/path/to/check", text: $probePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Check") {
                        probeResult = guardrails.evaluation(for: probePath)
                    }
                    .disabled(probePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let probeResult {
                    if probeResult.isProtected {
                        Label(
                            "Protected — \(probeResult.matchedTitles.joined(separator: ", "))",
                            systemImage: "lock.shield.fill"
                        )
                        .foregroundStyle(probeResult.isMandatory ? .red : .orange)
                    } else {
                        Label("Allowed for scan and cleanup review", systemImage: "checkmark.shield")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Mandatory (always on)") {
                ForEach(model.guardrailRules.filter { $0.level == .mandatory }) { item in
                    ruleRow(item, interactive: false)
                }
            }

            Section {
                ForEach(model.guardrailRules.filter { $0.level == .recommended }) { item in
                    ruleRow(item, interactive: true)
                }
            } header: {
                Text("Recommended")
            } footer: {
                Text("Turn off only if you understand the risk. System Library is global /Library, not your personal ~/Library.")
            }

            Section("Optional extras") {
                ForEach(model.guardrailRules.filter { $0.level == .optional }) { item in
                    ruleRow(item, interactive: true)
                }
            }

            Section("Excluded Prefixes") {
                ForEach(model.activeExcludePrefixes, id: \.self) { prefix in
                    Text(prefix)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Guardrails")
        .confirmationDialog(
            "Disable this protection?",
            isPresented: Binding(
                get: { confirmDisable != nil },
                set: { if !$0 { confirmDisable = nil } }
            ),
            presenting: confirmDisable
        ) { rule in
            Button("Disable \(rule.title)", role: .destructive) {
                model.setGuardrail(rule, enabled: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: { rule in
            Text("\(rule.detail)\n\nPaths: \(rule.prefixes.joined(separator: ", "))")
        }
    }

    @ViewBuilder
    private func ruleRow(_ item: GuardrailRuleUI, interactive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.prefixes.prefix(4).joined(separator: ", ") + (item.prefixes.count > 4 ? "…" : ""))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                Spacer()
                if interactive {
                    Toggle(
                        "Enabled",
                        isOn: Binding(
                            get: { item.enabled },
                            set: { newValue in
                                if !newValue, item.level == .recommended {
                                    confirmDisable = item.rule
                                } else {
                                    model.setGuardrail(item.rule, enabled: newValue)
                                }
                            }
                        )
                    )
                    .labelsHidden()
                } else {
                    Text("Locked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct GuardrailRuleUI: Identifiable, Equatable {
    var id: String { rule.id }
    var rule: GuardrailRule
    var enabled: Bool
    var title: String { rule.title }
    var detail: String { rule.detail }
    var prefixes: [String] { rule.prefixes }
    var level: GuardrailLevel { rule.level }
}
