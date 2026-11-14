import Foundation

/// A move of focus on Portable TV's screens.
nonisolated enum TVDirection: Sendable {
    case up, down, left, right
}

/// A row of items focus moves along, by its id and how many items it has now.
nonisolated struct TVRow: Equatable, Sendable {
    let id: String
    let count: Int
}

/// Where focus is among rows of items, as a remote's presses move it: up and down between rows,
/// left and right along one. Each row keeps the item it was left on, so coming back to it lands
/// there, and rows with nothing in them are passed over. Rows load and change under it, so it
/// keeps ids rather than places, and reads the rows as they are at each move.
nonisolated struct TVFocus: Equatable, Sendable {
    /// The focused row; nil until focus first lands on one.
    private(set) var row: String?
    /// Each row's focused item, as it was left.
    private var columns: [String: Int] = [:]

    /// The item focused in `row`, or that would be once focus comes back to it, kept within its `count`.
    func column(in row: TVRow) -> Int {
        min(columns[row.id] ?? 0, max(0, row.count - 1))
    }

    /// The focused row among `rows` and its focused item; nil while none of them has items.
    /// Focus on a row that's gone, or empty, goes to the first with items.
    func focused(in rows: [TVRow]) -> (row: TVRow, column: Int)? {
        let filled = rows.filter { $0.count > 0 }
        guard let current = filled.first(where: { $0.id == row }) ?? filled.first else { return nil }
        return (current, column(in: current))
    }

    /// Whether the item at `column` of row `rowId` has focus among `rows`.
    func isFocused(row rowId: String, column: Int, in rows: [TVRow]) -> Bool {
        guard let focused = focused(in: rows) else { return false }
        return focused.row.id == rowId && focused.column == column
    }

    /// Moves focus among `rows`, top to bottom. False when there's nowhere to go that way, as up
    /// from the top row or left from a row's first item, for the screen to do something else.
    mutating func move(_ direction: TVDirection, in rows: [TVRow]) -> Bool {
        let filled = rows.filter { $0.count > 0 }
        guard let (current, column) = focused(in: rows), let index = filled.firstIndex(of: current) else { return false }
        // From the row focus shows on, which is the first with items before focus has been on
        // one, or once its own has gone.
        row = current.id
        switch direction {
        case .up:
            guard index > 0 else { return false }
            row = filled[index - 1].id
        case .down:
            guard index < filled.count - 1 else { return false }
            row = filled[index + 1].id
        case .left:
            guard column > 0 else { return false }
            columns[current.id] = column - 1
        case .right:
            guard column < current.count - 1 else { return false }
            columns[current.id] = column + 1
        }
        return true
    }

    /// Puts focus on an item, as a page does on the episode that plays next.
    mutating func focus(row rowId: String, column: Int? = nil) {
        row = rowId
        if let column { columns[rowId] = max(0, column) }
    }

    /// Leaves where `rowId` was left; focus coming back to it starts at its first item.
    mutating func forget(row rowId: String) {
        columns[rowId] = nil
    }
}
