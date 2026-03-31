import SwiftUI

enum RepeatMode: Int, CaseIterable {
    case off, all, one
}

@MainActor
class PlayQueue: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let playbackItem: PlaybackItem

        var path: String { playbackItem.path }
        var displayName: String { playbackItem.displayName }

        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.id == rhs.id
        }
    }

    @Published var items: [Item] = []
    @Published var currentIndex: Int = -1
    @Published var repeatMode: RepeatMode = .off
    @Published var shuffleEnabled: Bool = false

    private var shuffleOrder: [Int] = []
    private var shufflePosition: Int = 0

    var currentItem: Item? {
        guard currentIndex >= 0, currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    var hasNext: Bool {
        guard !items.isEmpty, currentIndex >= 0 else { return false }
        if repeatMode == .one || repeatMode == .all { return true }
        if shuffleEnabled {
            return shufflePosition < shuffleOrder.count - 1
        }
        return currentIndex < items.count - 1
    }

    var hasPrevious: Bool {
        guard !items.isEmpty, currentIndex >= 0 else { return false }
        if repeatMode == .one { return true }
        if shuffleEnabled {
            return shufflePosition > 0
        }
        return currentIndex > 0
    }

    var isEmpty: Bool { items.isEmpty }

    // MARK: - Queue population

    func setQueue(_ playbackItems: [PlaybackItem], startIndex: Int) {
        items = playbackItems.map { Item(playbackItem: $0) }
        currentIndex = max(0, min(startIndex, items.count - 1))
        if shuffleEnabled {
            rebuildShuffleOrder()
        }
    }

    func appendItems(_ playbackItems: [PlaybackItem]) {
        let newItems = playbackItems.map { Item(playbackItem: $0) }
        items.append(contentsOf: newItems)
        if items.count == newItems.count {
            currentIndex = 0
        }
        if shuffleEnabled {
            rebuildShuffleOrder()
        }
    }

    func playNext(_ playbackItem: PlaybackItem) {
        let item = Item(playbackItem: playbackItem)
        let insertAt = currentIndex >= 0 ? currentIndex + 1 : items.count
        items.insert(item, at: insertAt)
        if shuffleEnabled {
            rebuildShuffleOrder()
        }
    }

    // MARK: - Navigation

    func advance() -> Item? {
        guard !items.isEmpty, currentIndex >= 0 else { return nil }

        if repeatMode == .one {
            return currentItem
        }

        if shuffleEnabled {
            return advanceShuffle()
        }

        let nextIndex = currentIndex + 1
        if nextIndex < items.count {
            currentIndex = nextIndex
            return currentItem
        }

        if repeatMode == .all {
            currentIndex = 0
            return currentItem
        }

        return nil
    }

    func goBack() -> Item? {
        guard !items.isEmpty, currentIndex >= 0 else { return nil }

        if repeatMode == .one {
            return currentItem
        }

        if shuffleEnabled {
            return goBackShuffle()
        }

        if currentIndex > 0 {
            currentIndex -= 1
            return currentItem
        }

        if repeatMode == .all {
            currentIndex = items.count - 1
            return currentItem
        }

        return nil
    }

    func jumpTo(index: Int) -> Item? {
        guard index >= 0, index < items.count else { return nil }
        currentIndex = index
        if shuffleEnabled {
            if let pos = shuffleOrder.firstIndex(of: index) {
                shufflePosition = pos
            }
        }
        return currentItem
    }

    // MARK: - Queue management

    func move(from source: IndexSet, to destination: Int) {
        let oldCurrent = currentItem
        items.move(fromOffsets: source, toOffset: destination)
        if let oldCurrent, let newIndex = items.firstIndex(where: { $0.id == oldCurrent.id }) {
            currentIndex = newIndex
        }
        if shuffleEnabled {
            rebuildShuffleOrder()
        }
    }

    func remove(at offsets: IndexSet) {
        let oldCurrent = currentItem
        items.remove(atOffsets: offsets)

        if items.isEmpty {
            currentIndex = -1
            shuffleOrder = []
            shufflePosition = 0
            return
        }

        if let oldCurrent, let newIndex = items.firstIndex(where: { $0.id == oldCurrent.id }) {
            currentIndex = newIndex
        } else {
            currentIndex = min(currentIndex, items.count - 1)
        }

        if shuffleEnabled {
            rebuildShuffleOrder()
        }
    }

    func clear() {
        items = []
        currentIndex = -1
        shuffleOrder = []
        shufflePosition = 0
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
        if shuffleEnabled {
            rebuildShuffleOrder()
        } else {
            shuffleOrder = []
            shufflePosition = 0
        }
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: - Shuffle internals

    private func rebuildShuffleOrder() {
        guard !items.isEmpty else {
            shuffleOrder = []
            shufflePosition = 0
            return
        }

        var indices = Array(items.indices)

        // Remove current index and place it first
        if currentIndex >= 0, currentIndex < items.count {
            indices.removeAll { $0 == currentIndex }
        }

        // Fisher-Yates shuffle
        for i in stride(from: indices.count - 1, through: 1, by: -1) {
            let j = Int.random(in: 0...i)
            indices.swapAt(i, j)
        }

        if currentIndex >= 0, currentIndex < items.count {
            indices.insert(currentIndex, at: 0)
        }

        shuffleOrder = indices
        shufflePosition = 0
    }

    private func advanceShuffle() -> Item? {
        let nextPos = shufflePosition + 1
        if nextPos < shuffleOrder.count {
            shufflePosition = nextPos
            currentIndex = shuffleOrder[nextPos]
            return currentItem
        }

        if repeatMode == .all {
            rebuildShuffleOrder()
            // After reshuffle, position 0 is current item; advance to 1
            if shuffleOrder.count > 1 {
                shufflePosition = 1
                currentIndex = shuffleOrder[1]
            }
            return currentItem
        }

        return nil
    }

    private func goBackShuffle() -> Item? {
        if shufflePosition > 0 {
            shufflePosition -= 1
            currentIndex = shuffleOrder[shufflePosition]
            return currentItem
        }
        return nil
    }
}
