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
    /// case are one, as in Obsidian; the spelling with more notes wins. A
    /// note under two tags of one branch counts twice here; `tree(notes:)`
    /// counts it once.
    public static func tree(_ counts: [String: Int]) -> [TagNode] {
        let root = Box()
        for (tag, count) in counts {
            for (box, part) in root.path(tag) {
                box.spelled[part, default: 0] += count
                box.count += count
            }
        }
        return root.build(prefix: "")
    }

    /// The tree from each note's tags: a note counts once under a tag, however
    /// many of the tags under it it has, as Obsidian counts.
    public static func tree(notes: some Sequence<[String]>) -> [TagNode] {
        let root = Box()
        for tags in notes {
            var counted = Set<ObjectIdentifier>()
            for tag in tags {
                for (box, part) in root.path(tag) {
                    box.spelled[part, default: 0] += 1
                    if counted.insert(ObjectIdentifier(box)).inserted { box.count += 1 }
                }
            }
        }
        return root.build(prefix: "")
    }

    private final class Box {
        /// Notes with the tag or one under it.
        var count = 0
        var spelled: [String: Int] = [:]
        var children: [String: Box] = [:]

        /// The boxes from the top down to [tag], made as needed, each with
        /// the part of the tag it is for.
        func path(_ tag: String) -> [(Box, String)] {
            var box = self
            var out: [(Box, String)] = []
            for part in tag.split(separator: "/").map(String.init) where !part.isEmpty {
                let key = Slugs.fold(part)
                if box.children[key] == nil { box.children[key] = Box() }
                box = box.children[key]!
                out.append((box, part))
            }
            return out
        }

        func build(prefix: String) -> [TagNode] {
            children.values.map { child -> TagNode in
                let name = child.spelled.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key ?? ""
                let tag = prefix.isEmpty ? name : prefix + "/" + name
                let kids = child.build(prefix: tag)
                return TagNode(name: name, tag: tag, count: child.count, children: kids.isEmpty ? nil : kids)
            }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}
