import SwiftUI
import MacStorageCore

struct GraphCanvasView: View {
    @EnvironmentObject private var model: AppModel
    @State private var offset: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var dragStart: CGSize = .zero
    @State private var selectedID: String?
    @State private var filter: GraphNodeKind?
    @State private var search = ""

    private var graph: DependencyGraph { model.dependencyGraph }

    private var filteredNodes: [GraphNode] {
        graph.nodes.filter { node in
            if let filter, node.kind != filter { return false }
            if !search.isEmpty {
                return node.label.localizedCaseInsensitiveContains(search)
                    || (node.path?.localizedCaseInsensitiveContains(search) ?? false)
            }
            return true
        }
    }

    private var layout: [String: CGPoint] {
        Self.layout(nodes: filteredNodes, size: CGSize(width: 880, height: 560))
    }

    private var visibleEdges: [GraphEdge] {
        let ids = Set(filteredNodes.map(\.id))
        return graph.edges.filter { ids.contains($0.sourceID) && ids.contains($0.targetID) }
    }

    private var selectedNode: GraphNode? {
        graph.nodes.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            ZStack {
                canvas
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(drag)
                    .gesture(magnify)

                if filteredNodes.isEmpty {
                    EmptyStateView(
                        systemImage: "point.3.connected.trianglepath.dotted",
                        title: "No Graph Data",
                        message: "Run a scan to map volumes, applications, caches, and relationships.",
                        actionTitle: model.isScanning ? nil : "Scan",
                        action: model.isScanning ? nil : { Task { await model.startScan() } }
                    )
                }
            }
            if let selectedNode {
                Divider()
                inspector(selectedNode)
            }
        }
        .navigationTitle("Graph")
    }

    private var controls: some View {
        HStack {
            Picker("Kind", selection: $filter) {
                Text("All").tag(GraphNodeKind?.none)
                ForEach(GraphNodeKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(Optional(kind))
                }
            }
            .labelsHidden()
            .frame(width: 140)

            TextField("Filter", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)

            Spacer()

            Text("\(filteredNodes.count) nodes")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Reset View") {
                offset = .zero
                scale = 1
            }
        }
        .padding(10)
    }

    private var canvas: some View {
        Canvas { context, size in
            let positions = layout
            for edge in visibleEdges {
                guard let a = positions[edge.sourceID], let b = positions[edge.targetID] else { continue }
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                let active = selectedID == nil || selectedID == edge.sourceID || selectedID == edge.targetID
                context.stroke(
                    path,
                    with: .color(.secondary.opacity(active ? 0.35 : 0.1)),
                    lineWidth: 1
                )
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            ZStack {
                ForEach(filteredNodes) { node in
                    if let p = layout[node.id] {
                        nodeView(node)
                            .position(p)
                            .onTapGesture { selectedID = node.id }
                    }
                }
            }
        }
        .frame(width: 880, height: 560)
    }

    private func nodeView(_ node: GraphNode) -> some View {
        let selected = selectedID == node.id
        return VStack(spacing: 4) {
            Image(systemName: node.kind.systemImage)
                .font(.body)
                .foregroundStyle(selected ? Color.accentColor : StudioTheme.color(for: node.kind))
                .frame(width: 36, height: 36)
                .background {
                    Circle()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.08), radius: selected ? 4 : 1, y: 1)
                }
                .overlay {
                    Circle()
                        .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1)
                }
            Text(node.label)
                .font(.caption2)
                .lineLimit(1)
                .frame(maxWidth: 88)
        }
    }

    private func inspector(_ node: GraphNode) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: node.kind.systemImage)
                .foregroundStyle(StudioTheme.color(for: node.kind))
            VStack(alignment: .leading, spacing: 2) {
                Text(node.label).font(.headline)
                Text(node.kind.displayName).font(.caption).foregroundStyle(.secondary)
                if let path = node.path {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(ByteFormat.string(node.bytes))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                selectedID = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.bar)
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: dragStart.width + value.translation.width,
                    height: dragStart.height + value.translation.height
                )
            }
            .onEnded { _ in dragStart = offset }
    }

    private var magnify: some Gesture {
        MagnificationGesture().onChanged { scale = min(2.2, max(0.5, $0)) }
    }

    static func layout(nodes: [GraphNode], size: CGSize) -> [String: CGPoint] {
        let cx = size.width / 2
        let cy = size.height / 2
        var result: [String: CGPoint] = [:]
        let rings: [(GraphNodeKind, CGFloat)] = [
            (.volume, 60), (.application, 140), (.directory, 220),
            (.package, 280), (.cache, 320), (.orphan, 360), (.file, 380),
        ]
        for (kind, radius) in rings {
            let subset = nodes.filter { $0.kind == kind }
            for (i, node) in subset.enumerated() {
                let angle = (Double(i) / Double(max(subset.count, 1))) * .pi * 2 - .pi / 2
                result[node.id] = CGPoint(
                    x: cx + CGFloat(cos(angle)) * radius,
                    y: cy + CGFloat(sin(angle)) * radius
                )
            }
        }
        for (i, node) in nodes.enumerated() where result[node.id] == nil {
            let angle = Double(i) * 0.7
            result[node.id] = CGPoint(x: cx + cos(angle) * 180, y: cy + sin(angle) * 180)
        }
        return result
    }
}
