import Foundation

/// Which task a newly reported agent belongs to (decision 0005), decided
/// once, when FocusPilot first hears from it and it has no task yet. A
/// guess is never made without a folder that says so: an agent nothing
/// matches stays unlinked until the owner links it by hand.
public enum AgentTaskMatch {
    /// A folder that points at a task.
    public struct FolderLink: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// The owner linked an agent in this folder to the task by hand.
            /// It holds that folder only, not the folders inside it: the
            /// owner chose one place, and a subfolder may be other work.
            case task
            /// The project's Herdr workspace folder; it points at the Now
            /// task, and only while Now is in that project.
            case project
        }

        public var folder: String
        public var taskID: Int64
        public var kind: Kind

        public init(folder: String, taskID: Int64, kind: Kind) {
            self.folder = folder
            self.taskID = taskID
            self.kind = kind
        }
    }

    /// The task for an agent in `folder`: the open task named with `--task`
    /// if any, else the one whose folder link holds `folder` most closely.
    /// On a tie the owner's own link wins over the project's, and the
    /// earlier in `links` (newest first) wins over the later. An owner's
    /// link made in `home` or above it holds nothing: one agent started
    /// there must not claim every later one.
    public static func task(explicit: Int64?, folder: String?, links: [FolderLink], openTasks: Set<Int64>,
                            home: String) -> Int64? {
        if let explicit, openTasks.contains(explicit) { return explicit }
        guard let folder else { return nil }
        var best: FolderLink?
        for link in links where openTasks.contains(link.taskID) && holds(link, folder, home: home) {
            guard let current = best else { best = link; continue }
            if link.folder.count > current.folder.count
                || (link.folder.count == current.folder.count && link.kind == .task && current.kind == .project) {
                best = link
            }
        }
        return best?.taskID
    }

    private static func holds(_ link: FolderLink, _ folder: String, home: String) -> Bool {
        switch link.kind {
        case .project: return contains(link.folder, folder)
        case .task:
            let root = trimmed(link.folder)
            return root == trimmed(folder) && root != "/" && !contains(root, trimmed(home))
        }
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Whether `folder` is `root` or inside it, by whole path components.
    /// The root folder alone is too broad to say anything.
    static func contains(_ root: String, _ folder: String) -> Bool {
        let root = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard !root.isEmpty else { return false }
        return folder == root || folder.hasPrefix(root + "/")
    }
}
