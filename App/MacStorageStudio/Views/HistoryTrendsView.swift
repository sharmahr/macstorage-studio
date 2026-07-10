import SwiftUI
import MacStorageCore
import Charts

struct HistoryTrendsView: View {
    @EnvironmentObject private var model: AppModel
    private var report: HistoryReport { model.historyReport }

    var body: some View {
        List {
            if report.snapshots.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Completed scans appear here. Run two or more scans to compare growth.")
                )
                .listRowSeparator(.hidden)
            } else {
                Section {
                    LabeledContent("Scans", value: "\(report.snapshots.count)")
                    LabeledContent("Latest size") {
                        Text(ByteFormat.string(report.trend.last?.totalBytes ?? 0)).monospacedDigit()
                    }
                    let delta = (report.trend.last?.totalBytes ?? 0)
                        - (report.trend.dropLast().last?.totalBytes ?? report.trend.last?.totalBytes ?? 0)
                    LabeledContent("Change") {
                        Text((delta >= 0 ? "+" : "") + ByteFormat.string(delta))
                            .monospacedDigit()
                            .foregroundStyle(delta > 0 ? .primary : .secondary)
                    }
                } header: {
                    Text("Summary")
                }

                if report.trend.count >= 1 {
                    Section("Storage Over Time") {
                        Chart(report.trend) { point in
                            LineMark(
                                x: .value("Date", point.date),
                                y: .value("Bytes", point.totalBytes)
                            )
                            .interpolationMethod(.catmullRom)
                            PointMark(
                                x: .value("Date", point.date),
                                y: .value("Bytes", point.totalBytes)
                            )
                        }
                        .frame(height: 180)
                        .chartYAxis {
                            AxisMarks { value in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let v = value.as(Int64.self) {
                                        Text(ByteFormat.string(v)).font(.caption2)
                                    }
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    }
                }

                if !report.largestGrowth.isEmpty {
                    Section("Largest Growth") {
                        ForEach(report.largestGrowth) { d in
                            LabeledContent(d.category.displayName) {
                                Text("+" + ByteFormat.string(d.deltaBytes))
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                if !report.largestShrink.isEmpty {
                    Section("Largest Shrink") {
                        ForEach(report.largestShrink) { d in
                            LabeledContent(d.category.displayName) {
                                Text(ByteFormat.string(d.deltaBytes))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Timeline") {
                    ForEach(report.snapshots) { snap in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snap.startedAt.formatted(date: .abbreviated, time: .shortened))
                                Text("\(snap.filesScanned) files · \(snap.status.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ByteFormat.string(snap.bytesScanned))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Button("Open") {
                                Task { await model.loadSession(id: snap.id) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("History")
        .toolbar {
            ToolbarItem {
                Button("Refresh") {
                    Task { await model.refreshHistory() }
                }
            }
        }
    }
}
