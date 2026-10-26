import Foundation

enum WorkspaceLayout: Int, CaseIterable {
    case single = 1, dual = 2, quad = 4
    var title: String { switch self { case .single: "单屏"; case .dual: "双屏"; case .quad: "四屏" } }
}

struct WorkspaceArrangement {
    private(set) var layout = WorkspaceLayout.single
    private(set) var slots: [UUID?] = Array(repeating: nil, count: 4)
    private(set) var activeSlot = 0
    var expandedSessionID: UUID?
    var columnFraction = 0.5
    var rowFraction = 0.5

    mutating func focus(_ index: Int) {
        guard (0..<layout.rawValue).contains(index) else { return }
        activeSlot = index
    }

    mutating func activate(_ id: UUID) {
        if let index = slots.prefix(layout.rawValue).firstIndex(of: id) { activeSlot = index }
        else {
            let index = slots.prefix(layout.rawValue).firstIndex(of: nil) ?? activeSlot
            slots[index] = id; activeSlot = index
        }
        if expandedSessionID != nil { expandedSessionID = id }
    }

    mutating func setLayout(_ next: WorkspaceLayout, tabs: [UUID]) {
        if activeSlot >= next.rawValue { slots.swapAt(0, activeSlot); activeSlot = 0 }
        layout = next; expandedSessionID = nil
        for index in next.rawValue..<4 { slots[index] = nil }
        for index in 0..<next.rawValue where slots[index] == nil {
            slots[index] = tabs.first { !slots.contains($0) }
        }
    }

    mutating func place(_ id: UUID, at index: Int) {
        guard (0..<layout.rawValue).contains(index) else { return }
        if let old = slots.firstIndex(of: id) { slots.swapAt(old, index) }
        else { slots[index] = id }
        activeSlot = index
        if expandedSessionID != nil { expandedSessionID = id }
    }

    mutating func remove(_ id: UUID) {
        for index in slots.indices where slots[index] == id { slots[index] = nil }
        if expandedSessionID == id { expandedSessionID = nil }
    }
}
