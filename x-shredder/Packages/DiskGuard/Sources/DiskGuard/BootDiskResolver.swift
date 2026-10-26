import Foundation

/// One IOMedia object and the media objects directly above it.
public struct MediaNode: Codable, Equatable, Sendable {
    public var bsdName: String
    public var isWhole: Bool
    /// BSD names of the nearest IOMedia ancestors. Empty for a physical disk.
    public var parents: [String]

    public init(bsdName: String, isWhole: Bool, parents: [String]) {
        self.bsdName = bsdName
        self.isWhole = isWhole
        self.parents = parents
    }
}

public struct Mount: Codable, Equatable, Sendable {
    public var device: String
    public var mountPoint: String

    public init(device: String, mountPoint: String) {
        self.device = device
        self.mountPoint = mountPoint
    }
}

public enum BootDiskResolver {
    /// Walks from every system mount up to the whole disks that store it:
    /// snapshot, volume, synthesized container, physical store, whole disk.
    ///
    /// Returns `nil` when the root volume cannot be resolved, or when any
    /// system mount cannot be followed. Callers must treat `nil` as "refuse
    /// everything".
    public static func protectedWholeDisks(mounts: [Mount], nodes: [MediaNode]) -> Set<String>? {
        let byName = Dictionary(nodes.map { ($0.bsdName, $0) }, uniquingKeysWith: { first, _ in first })
        var protected = Set<String>()
        var sawRoot = false

        for mount in mounts where isSystemMount(mount.mountPoint) {
            guard mount.device.hasPrefix("/dev/") else { continue }
            let name = String(mount.device.dropFirst("/dev/".count))
            guard let wholeDisks = wholeDisks(above: name, in: byName), !wholeDisks.isEmpty else {
                return nil
            }
            protected.formUnion(wholeDisks)
            if mount.mountPoint == "/" { sawRoot = true }
        }
        return sawRoot ? protected : nil
    }

    /// Everything except user-visible volumes under /Volumes counts as a
    /// system mount. Over-protecting is harmless here.
    static func isSystemMount(_ mountPoint: String) -> Bool {
        mountPoint == "/" || !mountPoint.hasPrefix("/Volumes/")
    }

    static func wholeDisks(above name: String, in nodes: [String: MediaNode]) -> Set<String>? {
        var result = Set<String>()
        var visited = Set<String>()
        var pending = [name]
        while let current = pending.popLast() {
            guard visited.insert(current).inserted else { continue }
            guard let node = nodes[current] else { return nil }
            if node.isWhole { result.insert(node.bsdName) }
            pending.append(contentsOf: node.parents)
        }
        return result
    }
}
