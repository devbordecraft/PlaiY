import XCTest
@testable import PlaiY

@MainActor
final class PlayQueueTests: XCTestCase {

    private func makeQueue(count: Int, startIndex: Int = 0) -> PlayQueue {
        let queue = PlayQueue()
        let items = (0..<count).map {
            PlaybackItem.local(path: "/video\($0).mkv", displayName: "Video \($0)")
        }
        queue.setQueue(items, startIndex: startIndex)
        return queue
    }

    // MARK: - Sequential advance

    func testAdvanceSequential() {
        let queue = makeQueue(count: 3)
        XCTAssertEqual(queue.currentIndex, 0)

        let item1 = queue.advance()
        XCTAssertEqual(item1?.path, "/video1.mkv")
        XCTAssertEqual(queue.currentIndex, 1)

        let item2 = queue.advance()
        XCTAssertEqual(item2?.path, "/video2.mkv")
        XCTAssertEqual(queue.currentIndex, 2)
    }

    func testAdvanceAtEndNoRepeat() {
        let queue = makeQueue(count: 2)
        _ = queue.advance() // -> index 1
        let result = queue.advance() // past end
        XCTAssertNil(result)
        XCTAssertEqual(queue.currentIndex, 1) // stays at last
    }

    func testAdvanceRepeatAll() {
        let queue = makeQueue(count: 2)
        queue.repeatMode = .all
        _ = queue.advance() // -> index 1
        let wrapped = queue.advance() // wraps to 0
        XCTAssertEqual(wrapped?.path, "/video0.mkv")
        XCTAssertEqual(queue.currentIndex, 0)
    }

    func testAdvanceRepeatOne() {
        let queue = makeQueue(count: 3)
        queue.repeatMode = .one
        let same = queue.advance()
        XCTAssertEqual(same?.path, "/video0.mkv")
        XCTAssertEqual(queue.currentIndex, 0)

        let sameAgain = queue.advance()
        XCTAssertEqual(sameAgain?.path, "/video0.mkv")
    }

    // MARK: - Shuffle

    func testShuffleCoversAll() {
        let queue = makeQueue(count: 5)
        queue.toggleShuffle()

        var visited = Set<String>()
        visited.insert(queue.currentItem!.path)
        for _ in 0..<4 {
            guard let next = queue.advance() else {
                XCTFail("advance() returned nil before visiting all items")
                return
            }
            visited.insert(next.path)
        }
        XCTAssertEqual(visited.count, 5)
    }

    func testShufflePreservesCurrent() {
        let queue = makeQueue(count: 5, startIndex: 2)
        let currentPath = queue.currentItem!.path
        queue.toggleShuffle()
        // Current item should still be the same after enabling shuffle
        XCTAssertEqual(queue.currentItem?.path, currentPath)
    }

    // MARK: - Go back

    func testGoBack() {
        let queue = makeQueue(count: 3)
        _ = queue.advance() // -> 1
        _ = queue.advance() // -> 2

        let prev = queue.goBack()
        XCTAssertEqual(prev?.path, "/video1.mkv")
        XCTAssertEqual(queue.currentIndex, 1)

        let prev2 = queue.goBack()
        XCTAssertEqual(prev2?.path, "/video0.mkv")

        // At start, returns nil
        let atStart = queue.goBack()
        XCTAssertNil(atStart)
    }

    func testGoBackRepeatAll() {
        let queue = makeQueue(count: 3)
        queue.repeatMode = .all
        // At index 0, go back wraps to end
        let wrapped = queue.goBack()
        XCTAssertEqual(wrapped?.path, "/video2.mkv")
    }

    // MARK: - Move

    func testMoveUpdatesCurrentIndex() {
        let queue = makeQueue(count: 4)
        _ = queue.advance() // current = 1
        let currentPath = queue.currentItem!.path

        // Move item 3 to position 0 (before current)
        queue.move(from: IndexSet(integer: 3), to: 0)
        // Current item should still be the same
        XCTAssertEqual(queue.currentItem?.path, currentPath)
    }

    // MARK: - Remove

    func testRemoveBeforeCurrent() {
        let queue = makeQueue(count: 4)
        _ = queue.advance() // current = 1
        let currentPath = queue.currentItem!.path

        queue.remove(at: IndexSet(integer: 0)) // remove item before current
        XCTAssertEqual(queue.currentItem?.path, currentPath)
        XCTAssertEqual(queue.items.count, 3)
    }

    func testRemoveCurrentItem() {
        let queue = makeQueue(count: 3)
        _ = queue.advance() // current = 1

        queue.remove(at: IndexSet(integer: 1)) // remove current
        // Should clamp to valid index
        XCTAssertTrue(queue.currentIndex >= 0 && queue.currentIndex < queue.items.count)
    }

    func testRemoveAllItems() {
        let queue = makeQueue(count: 2)
        queue.remove(at: IndexSet(integersIn: 0..<2))
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.currentIndex, -1)
    }

    // MARK: - Clear

    func testClear() {
        let queue = makeQueue(count: 5)
        _ = queue.advance()
        queue.clear()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.currentIndex, -1)
        XCTAssertNil(queue.currentItem)
    }

    // MARK: - Jump to

    func testJumpTo() {
        let queue = makeQueue(count: 5)
        let jumped = queue.jumpTo(index: 3)
        XCTAssertEqual(jumped?.path, "/video3.mkv")
        XCTAssertEqual(queue.currentIndex, 3)
    }

    func testJumpToOutOfBounds() {
        let queue = makeQueue(count: 3)
        XCTAssertNil(queue.jumpTo(index: 10))
        XCTAssertNil(queue.jumpTo(index: -1))
    }

    // MARK: - Append items

    func testAppendItems() {
        let queue = makeQueue(count: 2)
        queue.appendItems([PlaybackItem.local(path: "/extra.mkv", displayName: "Extra")])
        XCTAssertEqual(queue.items.count, 3)
        XCTAssertEqual(queue.items.last?.path, "/extra.mkv")
    }

    func testAppendToEmptyQueue() {
        let queue = PlayQueue()
        queue.appendItems([PlaybackItem.local(path: "/first.mkv", displayName: "First")])
        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertEqual(queue.currentItem?.path, "/first.mkv")
    }

    // MARK: - Play next

    func testPlayNext() {
        let queue = makeQueue(count: 3)
        // current = 0
        queue.playNext(PlaybackItem.local(path: "/inserted.mkv", displayName: "Inserted"))
        XCTAssertEqual(queue.items.count, 4)
        XCTAssertEqual(queue.items[1].path, "/inserted.mkv")
        // Advance should go to inserted item
        let next = queue.advance()
        XCTAssertEqual(next?.path, "/inserted.mkv")
    }

    // MARK: - hasNext / hasPrevious

    func testHasNextAndPrevious() {
        let queue = makeQueue(count: 3)
        XCTAssertTrue(queue.hasNext)
        XCTAssertFalse(queue.hasPrevious) // at index 0

        _ = queue.advance() // -> 1
        XCTAssertTrue(queue.hasNext)
        XCTAssertTrue(queue.hasPrevious)

        _ = queue.advance() // -> 2
        XCTAssertFalse(queue.hasNext) // at end, no repeat
        XCTAssertTrue(queue.hasPrevious)

        queue.repeatMode = .all
        XCTAssertTrue(queue.hasNext) // repeat all means always has next
    }

    // MARK: - Cycle repeat mode

    func testCycleRepeatMode() {
        let queue = PlayQueue()
        XCTAssertEqual(queue.repeatMode, .off)
        queue.cycleRepeatMode()
        XCTAssertEqual(queue.repeatMode, .all)
        queue.cycleRepeatMode()
        XCTAssertEqual(queue.repeatMode, .one)
        queue.cycleRepeatMode()
        XCTAssertEqual(queue.repeatMode, .off)
    }
}
