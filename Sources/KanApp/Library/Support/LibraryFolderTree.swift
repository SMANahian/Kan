import Foundation
import KanCore

/// One library folder in the sidebar tree.
struct LibraryFolderNode: Identifiable, Hashable {
    var id: String { path }
    /// Full folder name, "/"-separated ("Research/Thesis").
    let path: String
    /// Last component ("Thesis").
    let name: String
    /// Calls directly in this folder.
    let count: Int
    /// Calls in this folder and all of its subfolders (what selecting it lists).
    let totalCount: Int
    /// nil for a leaf, so `OutlineGroup` shows no disclosure triangle.
    let children: [LibraryFolderNode]?
}

/// A folder in a flat, indented menu ("Move to Folder ▸").
struct LibraryFolderMenuItem: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let depth: Int
}

/// Builds the sidebar's folder tree from `LibraryStore.folders()`. Pure and thread-safe.
enum LibraryFolderTree {
    /// Tree of every folder except the Inbox (""). Missing parents are added (count 0); siblings are
    /// sorted like Finder ("Week 2" before "Week 10").
    static func build(_ folders: [FolderInfo]) -> [LibraryFolderNode] {
        var counts: [String: Int] = [:]
        for folder in folders where !folder.name.isEmpty {
            counts[folder.name, default: 0] += folder.count
            var parent = self.parent(of: folder.name)
            while let p = parent {
                if counts[p] == nil { counts[p] = 0 }
                parent = self.parent(of: p)
            }
        }
        var childrenByParent: [String: [String]] = [:]
        for path in counts.keys {
            childrenByParent[parent(of: path) ?? "", default: []].append(path)
        }
        func node(_ path: String) -> LibraryFolderNode {
            let children = sortedChildren(childrenByParent[path] ?? []).map(node)
            let own = counts[path] ?? 0
            return LibraryFolderNode(path: path, name: name(of: path), count: own,
                              totalCount: own + children.reduce(0) { $0 + $1.totalCount },
                              children: children.isEmpty ? nil : children)
        }
        return sortedChildren(childrenByParent[""] ?? []).map(node)
    }

    /// Depth-first (parents before children) list for menus.
    static func flatten(_ nodes: [LibraryFolderNode]) -> [LibraryFolderMenuItem] {
        var out: [LibraryFolderMenuItem] = []
        func visit(_ node: LibraryFolderNode, depth: Int) {
            out.append(LibraryFolderMenuItem(path: node.path, name: node.name, depth: depth))
            for child in node.children ?? [] { visit(child, depth: depth + 1) }
        }
        for node in nodes { visit(node, depth: 0) }
        return out
    }

    /// "A/B/C" → "A/B"; "A" → nil.
    static func parent(of path: String) -> String? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        let parent = String(path[..<slash])
        return parent.isEmpty ? nil : parent
    }

    /// "A/B/C" → "C".
    static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// `name` inside `parent` (nil or "" = top level). The result still needs
    /// `LibraryStore.sanitizeFolder` before use.
    static func join(_ parent: String?, _ name: String) -> String {
        guard let parent, !parent.isEmpty else { return name }
        return parent + "/" + name
    }

    /// True when `folder` is `ancestor` or inside it (case-insensitive, like the library).
    static func folder(_ folder: String, isInside ancestor: String) -> Bool {
        let f = folder.lowercased(), a = ancestor.lowercased()
        return f == a || f.hasPrefix(a + "/")
    }

    /// `folder` after `from` was renamed to `to` (unchanged when it isn't inside `from`).
    static func renamed(_ folder: String, from: String, to: String) -> String {
        guard self.folder(folder, isInside: from) else { return folder }
        return to + folder.dropFirst(from.count)
    }

    private static func sortedChildren(_ paths: [String]) -> [String] {
        paths.sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
    }
}
