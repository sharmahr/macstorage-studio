import SwiftUI
import MacStorageCore

struct FilterBarView: View {
    @Binding var filters: ScanFilters
    var onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Filter name or path", text: $filters.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onChange)

                Picker("Category", selection: $filters.category) {
                    Text("All categories").tag(StorageCategory?.none)
                    ForEach(StorageCategory.allCases, id: \.self) { cat in
                        Text(cat.displayName).tag(Optional(cat))
                    }
                }
                .labelsHidden()
                .frame(minWidth: 140, idealWidth: 160)

                TextField("ext (png,pdf)", text: $filters.extensionsCSV)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .onSubmit(onChange)

                Button("Apply", action: onChange)
                    .keyboardShortcut(.defaultAction)

                if filters.isActive {
                    Button("Clear") {
                        filters = ScanFilters()
                        onChange()
                    }
                }
            }

            HStack(spacing: 16) {
                HStack {
                    Text("Min size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(filters.minBytes) },
                            set: { filters.minBytes = Int64($0) }
                        ),
                        in: 0...50_000_000,
                        step: 100_000
                    )
                    .frame(width: 120)
                    Text(filters.minBytes > 0 ? ByteFormat.string(filters.minBytes) : "Any")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                }

                Toggle("Files only", isOn: $filters.onlyFiles)
                    .toggleStyle(.checkbox)
                    .onChange(of: filters.onlyFiles) { _, on in
                        if on { filters.onlyDirectories = false }
                        onChange()
                    }

                Toggle("Folders only", isOn: $filters.onlyDirectories)
                    .toggleStyle(.checkbox)
                    .onChange(of: filters.onlyDirectories) { _, on in
                        if on { filters.onlyFiles = false }
                        onChange()
                    }

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: filters.category) { _, _ in onChange() }
        .onChange(of: filters.minBytes) { _, _ in onChange() }
    }
}
