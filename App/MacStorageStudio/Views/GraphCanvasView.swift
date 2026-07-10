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
    @State private var canvasSize: CGSize = CGSize(width: 800, height: 500)

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
        Self.layout(nodes: filteredNodes, size: canvasSize)
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
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)

            Divider()

            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    canvasContent(size: size)
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
                .frame(width: size.width, height: size.height)
                .clipped()
                .onAppear { canvasSize = size }
                .onChange(of: geo.size) { _, newSize in
                    canvasSize = newSize
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let selectedNode {
                Divider()
                inspector(selectedNode)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Graph")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Reset View") {
                    offset = .zero
                    scale = 1
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Kind", selection: $filter) {
                Text("All").tag(GraphNodeKind?.none)
                ForEach(GraphNodeKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(Optional(kind))
                }
            }
            .labelsHidden()
            .frame(minWidth: 120, idealWidth: 140, maxWidth: 180)

            TextField("Filter nodes", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)

            Spacer(minLength: 8)

            Text("\(filteredNodes.count) nodes")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private func canvasContent(size: CGSize) -> some View {
        let positions = Self.layout(nodes: filteredNodes, size: size)
        return Canvas { context, canvasSize in
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
        .background(Color(nsColor: .textBackgroundColor)) // adapts light/dark
        .overlay {
            ZStack {
                ForEach(filteredNodes) { node in
                    if let p = positions[node.id] {
                        nodeView(node)
                            .position(p)
                            .onTapGesture { selectedID = node.id }
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
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
        let cx = max(size.width / 2, 1)
        let cy = max(size.height / 2, 1)
        let scale = min(size.width, size.height) / 500
        var result: [String: CGPoint] = [:]
        let rings: [(GraphNodeKind, CGFloat)] = [
            (.volume, 60), (.application, 120), (.directory, 180),
            (.package, 230), (.cache, 270), (.orphan, 300), (.file, 320),
        ]
        for (kind, baseRadius) in rings {
            let subset = nodes.filter { $0.kind == kind }
            let radius = baseRadius * max(scale, 0.55)
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
            let radius: CGFloat = 160 * max(scale, 0.55)
            result[node.id] = CGPoint(x: cx + cos(angle) * radius, y: cy + sin(angle) * radius)
        }
        return result
    }
}
