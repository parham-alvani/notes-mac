import Foundation

/// The vault's tags as a tree, as Obsidian's tag pane shows them: `#a/b`
/// is under `#a`, and a tag counts the notes of the tags under it too.
public struct TagNode: Sendable, Hashable, Identifiable {
    /// The last part: `b` of `a/b`.
    public var name: String
    /// The whole tag, `a/b`, which a search uses.
    public var tag: String
    /// Notes with the tag or a tag under it.
    public var count: Int
    public var children: [TagNode]?
    public var id: String { tag }

    /// [counts] is the index's notes per tag. Tags that differ only in
    /// case are one, as in Obsidian; the spelling with more notes wins.
    public static func tree(_ counts: [String: Int]) -> [TagNode] {
        final class Box {
            var name = ""
            var tag = ""
            var own = 0
            var spelled: [String: Int] = [:]
            var children: [String: Box] = [:]
        }
        let root = Box()
        for (tag, count) in counts {
            var box = root
            var path: [String] = []
            for part in tag.split(separator: "/").map(String.init) where !part.isEmpty {
                path.append(part)
                let key = Slugs.fold(part)
                if box.children[key] == nil { box.children[key] = Box() }
                box = box.children[key]!
                box.spelled[part, default: 0] += count
            }
            box.own += count
        }
        func build(_ box: Box, prefix: String) -> [TagNode] {
            box.children.values.map { child -> TagNode in
                let name = child.spelled.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key ?? ""
                let tag = prefix.isEmpty ? name : prefix + "/" + name
                let kids = build(child, prefix: tag)
                return TagNode(name: name, tag: tag, count: child.own + kids.reduce(0) { $0 + $1.count }, children: kids.isEmpty ? nil : kids)
            }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return build(root, prefix: "")
    }
}
