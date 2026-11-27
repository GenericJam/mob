// Host test for ios/MobWeightedStack.swift (MOB-569): Row / Column `weight`
// divides the leftover main-axis space by ratio, as Compose's weight() does.
//
// Lays real SwiftUI views out in an NSHostingView on macOS and reads back the
// frames, so it exercises the Layout itself, not a copy of its arithmetic. The
// renderer's iOS-only types are stubbed below with the members
// MobWeightedStack.swift reads; everything else about it is the shipped file.
//
// Not covered: anything iOS-specific (UIKit text metrics, the renderer's
// modifier chain around each child). The simulator checks in the PR cover that.

import AppKit
import SwiftUI

// ── Stubs for the renderer types MobWeightedStack.swift reads ────────────────
enum MobLayoutWeightAxis { case horizontal, vertical }
enum MobNodeType { case box, spacer }
final class MobNode {
    var nodeType: MobNodeType = .box
    var layoutWeight: CGFloat = 0
    var fixedWidth: CGFloat = 0
    var fixedHeight: CGFloat = 0
    var fixedSize: CGFloat = 0
    init(_ type: MobNodeType = .box, weight: CGFloat = 0, width: CGFloat = 0, height: CGFloat = 0, size: CGFloat = 0) {
        nodeType = type
        layoutWeight = weight
        fixedWidth = width
        fixedHeight = height
        fixedSize = size
    }
}

// ── Harness ─────────────────────────────────────────────────────────────────
@MainActor var frames: [String: CGRect] = [:]
@MainActor var failures = 0

extension View {
    func probe(_ name: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.onAppear { frames[name] = geometry.frame(in: .global) }
        })
    }
    // What MobLayoutWeight gives a weighted child: a frame that accepts any
    // main-axis size the stack hands it.
    func rowWeight(_ weight: CGFloat) -> some View {
        frame(maxWidth: .infinity, alignment: .leading).layoutValue(key: MobStackWeightKey.self, value: weight)
    }
    func columnWeight(_ weight: CGFloat) -> some View {
        frame(maxHeight: .infinity, alignment: .top).layoutValue(key: MobStackWeightKey.self, value: weight)
    }
}

@MainActor func layOut(_ view: some View, width: CGFloat = 300, height: CGFloat = 300) {
    frames = [:]
    let size = CGSize(width: width, height: height)
    let host = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .topLeading))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
}

@MainActor func expect(_ name: String, _ actual: CGFloat?, _ expected: CGFloat, _ what: String) {
    guard let actual, abs(actual - expected) < 0.51 else {
        print("FAIL \(name): \(what) = \(actual.map { "\($0)" } ?? "missing"), expected \(expected)")
        failures += 1
        return
    }
}

@MainActor func expectTrue(_ name: String, _ condition: Bool, _ what: String) {
    if !condition {
        print("FAIL \(name): \(what)")
        failures += 1
    }
}

@main
enum WeightedStackTest {
    @MainActor static func main() {
        run()
    }
}

@MainActor func run() {
    _ = NSApplication.shared

    // MishkaSkeleton's last line: a bar and a weighted Spacer. Before MOB-569
    // every weight was an even split, so both of these came out 150 wide.
    for (bar, rest) in [(0.35, 0.65), (0.6, 0.4)] as [(CGFloat, CGFloat)] {
        let name = "row \(bar)/\(rest)"
        layOut(MobWeightedRowLayout(alignment: .center, spacing: 0) {
            Color.red.frame(height: 8).probe("bar").rowWeight(bar)
            Spacer().probe("spacer").rowWeight(rest)
        }.probe("row"))
        expect(name, frames["bar"]?.width, 300 * bar, "bar width")
        expect(name, frames["spacer"]?.width, 300 * rest, "spacer width")
        // stackOrientation keeps a Spacer flat across the row, as in an HStack.
        expect(name, frames["spacer"]?.height, 0, "spacer height")
        expect(name, frames["row"]?.height, 8, "row height")
    }

    // Unweighted children are measured first at their ideal size; the rest,
    // after the gaps, is split 1:2.
    layOut(MobWeightedRowLayout(alignment: .center, spacing: 10) {
        Text("Hello").fixedSize().frame(width: 40).probe("text")
        Color.red.frame(height: 20).probe("one").rowWeight(1)
        Color.blue.frame(height: 30).probe("two").rowWeight(2)
    }.probe("row"))
    expect("row 1:2", frames["text"]?.width, 40, "unweighted width")
    expect("row 1:2", frames["one"]?.width, 80, "weight 1 width")
    expect("row 1:2", frames["two"]?.width, 160, "weight 2 width")
    expect("row 1:2", frames["one"]?.minX, 50, "weight 1 x")
    expect("row 1:2", frames["two"]?.minX, 140, "weight 2 x")
    expect("row 1:2", frames["row"]?.height, 30, "row height (tallest child)")
    expect("row 1:2", frames["one"]?.minY, 5, "centre alignment")

    // An unweighted child that would fill (an iOS Column fills its parent's
    // width) gets its ideal width, not all of it.
    layOut(MobWeightedRowLayout(alignment: .top, spacing: 0) {
        Color.green.frame(idealWidth: 60, maxWidth: .infinity).frame(height: 10).probe("fill")
        Color.red.frame(height: 10).probe("weighted").rowWeight(1)
    })
    expect("row fill sibling", frames["fill"]?.width, 60, "unweighted filler width")
    expect("row fill sibling", frames["weighted"]?.width, 240, "weighted width")

    // A weighted child that cannot shrink to its share keeps its own width, and
    // its neighbour starts after it instead of on top of it.
    layOut(MobWeightedRowLayout(alignment: .top, spacing: 0) {
        Color.green.frame(width: 200, height: 10).probe("wide").rowWeight(1)
        Color.red.frame(height: 10).probe("next").rowWeight(1)
    })
    expect("row overflow", frames["wide"]?.width, 200, "unshrinkable child width")
    expect("row overflow", frames["next"]?.minX, 200, "neighbour x")

    // Column: same split on the vertical axis.
    layOut(MobWeightedColumnLayout(alignment: .leading, spacing: 0) {
        Color.gray.frame(width: 20, height: 30).probe("header")
        Color.red.probe("one").columnWeight(1)
        Color.blue.probe("two").columnWeight(2)
    })
    expect("column 1:2", frames["one"]?.height, 90, "weight 1 height")
    expect("column 1:2", frames["two"]?.height, 180, "weight 2 height")
    expect("column 1:2", frames["two"]?.minY, 120, "weight 2 y")

    // An ideal-size proposal (a column in a vertical scroll, a fixedSize row)
    // has nothing to divide: every child keeps its ideal size, no overlap.
    layOut(ScrollView {
        MobWeightedColumnLayout(alignment: .leading, spacing: 0) {
            Color.gray.frame(width: 20, height: 16).probe("header")
            Color.red.frame(width: 20, height: 16).probe("one").columnWeight(1)
            Color.blue.frame(width: 20, height: 16).probe("two").columnWeight(2)
        }.probe("column")
    })
    expect("column ideal", frames["column"]?.height, 48, "column height")
    expect("column ideal", frames["one"]?.minY, 16, "weight 1 y")
    expect("column ideal", frames["two"]?.minY, 32, "weight 2 y")

    // Right-to-left: SwiftUI mirrors a custom Layout's placement as it does an
    // HStack's, so the first child sits at the trailing (right) edge.
    layOut(MobWeightedRowLayout(alignment: .center, spacing: 0) {
        Color.red.frame(height: 8).probe("first").rowWeight(1)
        Color.blue.frame(height: 8).probe("second").rowWeight(3)
    }.environment(\.layoutDirection, .rightToLeft))
    expect("row rtl", frames["first"]?.minX, 225, "first child x")
    expect("row rtl", frames["first"]?.width, 75, "first child width")
    expect("row rtl", frames["second"]?.minX, 0, "second child x")

    // The node helpers: a fixed main-axis size beats weight (MOB-181), a
    // flexible Spacer is weight 1, and only an explicit weight makes a stack
    // weighted.
    expectTrue("weights", mobStackWeight(MobNode(weight: 0.35), axis: .horizontal) == 0.35, "explicit weight")
    expectTrue("weights", mobStackWeight(MobNode(weight: 1, width: 40), axis: .horizontal) == 0, "fixed width beats weight")
    expectTrue("weights", mobStackWeight(MobNode(weight: 1, width: 40), axis: .vertical) == 1, "width is off-axis in a column")
    expectTrue("weights", mobStackWeight(MobNode(.spacer), axis: .horizontal) == 1, "flexible spacer")
    expectTrue("weights", mobStackWeight(MobNode(.spacer, size: 12), axis: .horizontal) == 0, "sized spacer")
    expectTrue("weights", !mobHasStackWeights([MobNode(.spacer), MobNode()], axis: .horizontal), "spacer alone")
    expectTrue("weights", mobHasStackWeights([MobNode(.spacer), MobNode(weight: 2)], axis: .horizontal), "explicit weight")
    expectTrue("weights", !mobHasStackWeights([MobNode(weight: 1, height: 30)], axis: .vertical), "pinned height")

    if failures > 0 {
        print("weighted_stack_test: \(failures) failure(s)")
        exit(1)
    }
    print("weighted_stack_test: ok")
}
