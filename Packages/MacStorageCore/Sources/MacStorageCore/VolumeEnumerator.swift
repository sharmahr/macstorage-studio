import Foundation

public enum VolumeEnumerator {
    public static func mountedVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsInternalKey,
            .volumeIsEjectableKey,
            .volumeIsRemovableKey,
        ]

        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = values?.volumeName ?? url.lastPathComponent
            let total = Int64(values?.volumeTotalCapacity ?? 0)
            let available = Int64(values?.volumeAvailableCapacity ?? 0)
            let isInternal = values?.volumeIsInternal ?? false
            let isEjectable = (values?.volumeIsEjectable ?? false) || (values?.volumeIsRemovable ?? false)
            return VolumeInfo(
                name: name,
                path: url.path,
                totalCapacity: total,
                availableCapacity: available,
                isInternal: isInternal,
                isEjectable: isEjectable
            )
        }
        .sorted { $0.path < $1.path }
    }

    /// Default MVP roots: home directory + non-root mounted volumes.
    public static func defaultScanRoots(home: String = NSHomeDirectory()) -> [String] {
        var roots = [home]
        for volume in mountedVolumes() {
            if volume.path == "/" { continue }
            if volume.path.hasPrefix("/System") { continue }
            if !roots.contains(volume.path) {
                roots.append(volume.path)
            }
        }
        return roots
    }
}
