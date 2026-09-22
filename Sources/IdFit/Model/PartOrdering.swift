/// One press of C either cycles on release or assigns slots through clicks.
/// Clicks on slots already assigned during this press leave the order alone.
struct PartOrdering {
    private(set) var isHeld = false
    private(set) var nextSlot = 0
    private var didClick = false

    mutating func begin() {
        guard !isHeld else { return }
        isHeld = true
        nextSlot = 0
        didClick = false
    }

    mutating func select(part: Int?, count: Int) -> Int? {
        guard isHeld else { return nil }
        didClick = true
        guard let part, part >= nextSlot, part < count, nextSlot < count else { return nil }
        defer { nextSlot += 1 }
        return nextSlot
    }

    mutating func end() -> Bool {
        let shouldCycle = isHeld && !didClick
        self = PartOrdering()
        return shouldCycle
    }
}
