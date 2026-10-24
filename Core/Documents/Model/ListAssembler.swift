import Foundation

/// Many formats (DOCX, RTF, PDF heuristics) store lists as flat paragraphs tagged with a level.
/// This folds those back into nested `Block.list` trees.
enum FlatBlock: Hashable {
    case block(Block)
    case listItem(level: Int, ordered: Bool, content: [Block])
}

enum ListAssembler {
    static func assemble(_ flat: [FlatBlock]) -> [Block] {
        var result: [Block] = []
        var index = 0
        while index < flat.count {
            switch flat[index] {
            case .block(let block):
                result.append(block)
                index += 1
            case .listItem(let level, _, _):
                let (list, next) = buildList(flat, start: index, level: level)
                result.append(list)
                index = next
            }
        }
        return result
    }

    private static func buildList(_ flat: [FlatBlock], start: Int, level: Int) -> (Block, Int) {
        guard case .listItem(_, let ordered, _) = flat[start] else { return (.list(ordered: false, items: []), start + 1) }
        var items: [[Block]] = []
        var index = start
        while index < flat.count, case .listItem(let itemLevel, let itemOrdered, let content) = flat[index] {
            if itemLevel < level { break }
            if itemLevel == level {
                if itemOrdered != ordered, !items.isEmpty { break }
                items.append(content)
                index += 1
            } else {
                let (nested, next) = buildList(flat, start: index, level: itemLevel)
                if items.isEmpty { items.append([]) }
                items[items.count - 1].append(nested)
                index = next
            }
        }
        return (.list(ordered: ordered, items: items), index)
    }
}
