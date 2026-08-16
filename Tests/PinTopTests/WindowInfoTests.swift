import XCTest
@testable import PinTop

/// Regression tests for issue #5: a window's identity is its CGWindowID.
/// The old field-wise equality let a window that moved/resized/re-titled
/// between pins defeat `pinnedWindows.contains`, accepting a second pin and
/// stranding the first overlay on screen.
final class WindowInfoTests: XCTestCase {
    private func makeWindow(
        id: CGWindowID,
        name: String = "Window",
        owner: String = "App",
        pid: pid_t = 1000,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)
    ) -> WindowInfo {
        WindowInfo(id: id, name: name, ownerName: owner, pid: pid, bounds: bounds)
    }

    func testSameIDWithDifferentBoundsIsEqual() {
        let original = makeWindow(id: 42, bounds: CGRect(x: 417, y: 160, width: 525, height: 547))
        let moved = makeWindow(id: 42, bounds: CGRect(x: 682, y: 152, width: 525, height: 547))
        let nudgedOnePixel = makeWindow(id: 42, bounds: CGRect(x: 682, y: 151, width: 525, height: 547))
        let resized = makeWindow(id: 42, bounds: CGRect(x: 0, y: 30, width: 1920, height: 1050))

        XCTAssertEqual(original, moved)
        XCTAssertEqual(moved, nudgedOnePixel)
        XCTAssertEqual(original, resized)
    }

    func testSameIDWithDifferentTitleIsEqual() {
        let before = makeWindow(id: 7, name: "Untitled")
        let retitled = makeWindow(id: 7, name: "My Document — Edited")
        XCTAssertEqual(before, retitled)
    }

    func testDifferentIDsAreNotEqual() {
        XCTAssertNotEqual(makeWindow(id: 1), makeWindow(id: 2))
    }

    func testHashKeysOnID() {
        let a = makeWindow(id: 42, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let b = makeWindow(id: 42, bounds: CGRect(x: 999, y: 999, width: 525, height: 547))
        XCTAssertEqual(a.hashValue, b.hashValue)

        var set: Set<WindowInfo> = [a]
        set.insert(b) // moved copy of the same window must not duplicate
        XCTAssertEqual(set.count, 1)
    }

    func testSetContainsReSelectedWindowAfterMove() {
        // The exact shape of the bug-1 guard: pin, move the window (or have
        // macOS nudge it a pixel), select it again — contains must hold.
        var pinned: Set<WindowInfo> = [makeWindow(id: 5608, bounds: CGRect(x: 417, y: 160, width: 525, height: 547))]
        let reSelected = makeWindow(id: 5608, bounds: CGRect(x: 682, y: 151, width: 525, height: 547))
        XCTAssertTrue(pinned.contains(reSelected))
        pinned.insert(reSelected)
        XCTAssertEqual(pinned.count, 1)
    }
}
