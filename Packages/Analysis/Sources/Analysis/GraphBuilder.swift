import Foundation
import MacStorageCore

public struct GraphBuilder: Sendable {
    public var maxNodes: Int

    public init(maxNodes: Int = 80) {
        self.maxNodes = maxNodes
    }

    public func build(
        volumes: [VolumeInfo],
        session: ScanSession?,
        topDirectories: [FileEntry],
        apps: [InstalledApplication],
        orphans: [OrphanArtifact],
        categoryBreakdown: [(StorageCategory, Int64, Int)]
    ) -> DependencyGraph {
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        var ids = Set<String>()

        func add(_ node: GraphNode) {
            guard nodes.count < maxNodes else { return }
            guard !ids.contains(node.id) else { return }
            ids.insert(node.id)
            nodes.append(node)
        }

        // Volumes
        for vol in volumes.prefix(6) {
            add(GraphNode(
                id: "vol:\(vol.path)",
                label: vol.name,
                kind: .volume,
                path: vol.path,
                bytes: vol.usedCapacity
            ))
        }

        // Root scan anchors
        if let session {
            for root in session.roots.prefix(4) {
                let id = "dir:\(root)"
                add(GraphNode(
                    id: id,
                    label: (root as NSString).lastPathComponent.isEmpty ? root : (root as NSString).lastPathComponent,
                    kind: .directory,
                    path: root,
                    bytes: session.bytesScanned / Int64(max(session.roots.count, 1))
                ))
                // attach to volume
                if let vol = volumes.first(where: { root == $0.path || root.hasPrefix($0.path + "/") || ($0.path == "/" && root.hasPrefix("/")) }) {
                    edges.append(GraphEdge(sourceID: "vol:\(vol.path)", targetID: id, kind: .owns))
                }
            }
        }

        // Top directories by size
        for dir in topDirectories.prefix(20) {
            let kind: GraphNodeKind
            if dir.category == .cache || dir.category == .browserCache || dir.category == .developerCache {
                kind = .cache
            } else if dir.isPackage || dir.name.hasSuffix(".app") {
                kind = .application
            } else {
                kind = .directory
            }
            let id = "dir:\(dir.path)"
            add(GraphNode(
                id: id,
                label: dir.name,
                kind: kind,
                path: dir.path,
                bytes: dir.size,
                category: dir.category
            ))
            // edge from parent root if any
            if let parent = dir.parentPath {
                let pid = "dir:\(parent)"
                if ids.contains(pid) {
                    edges.append(GraphEdge(sourceID: pid, targetID: id, kind: .owns))
                } else if let session, let root = session.roots.first(where: { dir.path.hasPrefix($0) }) {
                    edges.append(GraphEdge(sourceID: "dir:\(root)", targetID: id, kind: .owns))
                }
            }
        }

        // Applications
        for app in apps.prefix(12) {
            let id = "app:\(app.path)"
            add(GraphNode(
                id: id,
                label: app.name,
                kind: .application,
                path: app.path,
                bytes: app.totalSupportBytes
            ))
            for support in app.supportPaths.prefix(3) {
                let sid = "dir:\(support)"
                add(GraphNode(
                    id: sid,
                    label: (support as NSString).lastPathComponent,
                    kind: .package,
                    path: support,
                    bytes: 0
                ))
                edges.append(GraphEdge(sourceID: id, targetID: sid, kind: .owns))
                edges.append(GraphEdge(sourceID: sid, targetID: id, kind: .installedBy))
            }
            // cache relationship
            if app.totalSupportBytes > 0 {
                edges.append(GraphEdge(sourceID: id, targetID: id, kind: .generatedBy))
            }
        }

        // Orphans
        for orphan in orphans.prefix(10) {
            let id = "orphan:\(orphan.path)"
            add(GraphNode(
                id: id,
                label: orphan.name,
                kind: .orphan,
                path: orphan.path,
                bytes: orphan.bytes
            ))
            if let owner = orphan.suspectedOwner {
                let maybeApp = apps.first { $0.name.localizedCaseInsensitiveContains(owner) || ($0.bundleID?.localizedCaseInsensitiveContains(owner) ?? false) }
                if let app = maybeApp {
                    edges.append(GraphEdge(sourceID: "app:\(app.path)", targetID: id, kind: .dependsOn))
                }
            }
        }

        // Category summary nodes (virtual)
        for (cat, bytes, _) in categoryBreakdown.prefix(8) where bytes > 0 {
            let id = "cat:\(cat.rawValue)"
            add(GraphNode(
                id: id,
                label: cat.displayName,
                kind: cat == .cache || cat == .developerCache || cat == .browserCache ? .cache : .directory,
                bytes: bytes,
                category: cat
            ))
            if let session, let root = session.roots.first {
                edges.append(GraphEdge(sourceID: "dir:\(root)", targetID: id, kind: .owns))
            }
        }

        // Drop self-loops
        edges = edges.filter { $0.sourceID != $0.targetID }
        // Only keep edges with both ends present
        let nodeIDs = Set(nodes.map(\.id))
        edges = edges.filter { nodeIDs.contains($0.sourceID) && nodeIDs.contains($0.targetID) }

        return DependencyGraph(nodes: nodes, edges: edges)
    }
}
