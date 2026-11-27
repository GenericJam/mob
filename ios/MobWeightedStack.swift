import SwiftUI

// ── Weighted Row / Column (MOB-569) ──────────────────────────────────────────
//
// Compose's `weight()` divides a Row's or Column's leftover main-axis space by
// ratio. `MobLayoutWeight` alone only makes a child flexible, and an HStack
// splits its leftover evenly between equally flexible children, so weights of
// 0.35 and 0.65 came out 50/50. A Row or Column with a weighted child is laid
// out by `MobWeightedRowLayout` / `MobWeightedColumnLayout` instead; every
// other stack is still an HStack / VStack. The Row case and `MobEitherStack`
// (the Column's stack, at the end of this file) switch between the two through
// AnyLayout, so the children keep their identity (and their @State) when a
// weight comes or goes.
// See decisions/2026-11-27-ios-weighted-stack-layout.md.

struct MobStackWeightKey: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// The share a Row / Column child claims of its parent's leftover main-axis
/// space, 0 for none. A fixed size on the main axis beats weight, as in
/// `MobLayoutWeight` (MOB-181). A flexible Spacer counts as weight 1, which is
/// what Android gives it (`mobChildWeight`) and what an HStack effectively did.
func mobStackWeight(_ node: MobNode, axis: MobLayoutWeightAxis) -> CGFloat {
    let fixedMain = axis == .horizontal ? node.fixedWidth : node.fixedHeight
    if fixedMain > 0 { return 0 }
    if node.layoutWeight > 0 { return node.layoutWeight }
    if node.nodeType == .spacer && node.fixedSize <= 0 { return 1 }
    return 0
}

/// Whether a Row / Column needs the weighted layout: some child carries an
/// explicit, effective `weight`. A flexible Spacer alone does not count, so a
/// stack without weights stays a plain HStack / VStack.
func mobHasStackWeights(_ children: [MobNode], axis: MobLayoutWeightAxis) -> Bool {
    children.contains { child in
        child.layoutWeight > 0 && mobStackWeight(child, axis: axis) > 0
    }
}

/// The arithmetic shared by the row and column layouts. Given a finite
/// main-axis size it does what Compose's Row and Column do: unweighted children
/// first, then what is left after them and the gaps is divided between the
/// weighted children by ratio, each taking exactly its share. Unweighted
/// children are offered their ideal size capped at what is left, not all that
/// is left, so a child that merely fills (an iOS Column fills its parent's
/// width) cannot starve its weighted siblings.
///
/// An ideal (nil) or unbounded proposal has no leftover to divide; every child
/// is measured with that same proposal, as an HStack / VStack would do.
private struct MobWeightedStack {
    let axis: Axis
    let spacing: CGFloat
    /// The child's cross-axis alignment guide: a VerticalAlignment for a row,
    /// a HorizontalAlignment for a column.
    let crossGuide: (ViewDimensions) -> CGFloat

    private struct Arrangement {
        var main: [CGFloat]
        var proposals: [ProposedViewSize]
        var guides: [CGFloat]
        var crossLead: CGFloat
        var crossExtent: CGFloat
    }

    func sizeThatFits(_ proposal: ProposedViewSize, _ subviews: LayoutSubviews) -> CGSize {
        let arrangement = arrange(proposal, subviews)
        let main = arrangement.main.reduce(0, +) + gaps(subviews.count)
        return size(main: main, cross: arrangement.crossExtent)
    }

    func place(in bounds: CGRect, _ proposal: ProposedViewSize, _ subviews: LayoutSubviews) {
        // Divide the space actually granted along the main axis. An ideal
        // (nil) proposal is kept as it is: sizeThatFits answered with every
        // child's ideal size, and re-splitting that total by ratio would hand
        // a weighted child less than its own ideal and overlap its neighbour.
        let main = axis == .horizontal ? proposal.width : proposal.height
        let granted: ProposedViewSize
        if main == nil {
            granted = proposal
        } else if axis == .horizontal {
            granted = ProposedViewSize(width: bounds.width, height: proposal.height)
        } else {
            granted = ProposedViewSize(width: proposal.width, height: bounds.height)
        }
        let arrangement = arrange(granted, subviews)
        var offset: CGFloat = 0
        for index in subviews.indices {
            let crossOffset = arrangement.crossLead - arrangement.guides[index]
            let point = axis == .horizontal
                ? CGPoint(x: bounds.minX + offset, y: bounds.minY + crossOffset)
                : CGPoint(x: bounds.minX + crossOffset, y: bounds.minY + offset)
            subviews[index].place(at: point, anchor: .topLeading, proposal: arrangement.proposals[index])
            offset += arrangement.main[index] + spacing
        }
    }

    private func arrange(_ proposal: ProposedViewSize, _ subviews: LayoutSubviews) -> Arrangement {
        let available = axis == .horizontal ? proposal.width : proposal.height
        let cross = axis == .horizontal ? proposal.height : proposal.width
        let weights = subviews.map { max(0, $0[MobStackWeightKey.self]) }
        let totalWeight = weights.reduce(0, +)
        var proposals = [ProposedViewSize](
            repeating: propose(main: available, cross: cross),
            count: subviews.count
        )
        var shares = [CGFloat?](repeating: nil, count: subviews.count)

        if let available, available.isFinite, totalWeight > 0 {
            var left = max(0, available - gaps(subviews.count))
            for index in subviews.indices where weights[index] == 0 {
                let ideal = mainSize(subviews[index].sizeThatFits(propose(main: nil, cross: cross)))
                let offered = propose(main: min(ideal, left), cross: cross)
                proposals[index] = offered
                left = max(0, left - mainSize(subviews[index].sizeThatFits(offered)))
            }
            for index in subviews.indices where weights[index] > 0 {
                let share = left * weights[index] / totalWeight
                shares[index] = share
                proposals[index] = propose(main: share, cross: cross)
            }
        }

        var main: [CGFloat] = []
        var guides: [CGFloat] = []
        var crossLead: CGFloat = 0
        var crossTrail: CGFloat = 0
        for index in subviews.indices {
            let dimensions = subviews[index].dimensions(in: proposals[index])
            // A weighted child takes its share, as Compose's weight(fill =
            // true) does; MobLayoutWeight's flexible frame lets it accept that
            // size. One that cannot shrink to its share (or gets a share of 0)
            // still draws at its own size, so the next sibling starts after it
            // rather than on top of it.
            let measured = axis == .horizontal ? dimensions.width : dimensions.height
            main.append(shares[index].map { max($0, measured) } ?? measured)
            let guide = crossGuide(dimensions)
            let extent = axis == .horizontal ? dimensions.height : dimensions.width
            guides.append(guide)
            crossLead = max(crossLead, guide)
            crossTrail = max(crossTrail, extent - guide)
        }
        return Arrangement(
            main: main,
            proposals: proposals,
            guides: guides,
            crossLead: crossLead,
            crossExtent: crossLead + crossTrail
        )
    }

    private func gaps(_ count: Int) -> CGFloat {
        spacing * CGFloat(max(0, count - 1))
    }

    private func propose(main: CGFloat?, cross: CGFloat?) -> ProposedViewSize {
        axis == .horizontal
            ? ProposedViewSize(width: main, height: cross)
            : ProposedViewSize(width: cross, height: main)
    }

    private func mainSize(_ size: CGSize) -> CGFloat {
        axis == .horizontal ? size.width : size.height
    }

    private func size(main: CGFloat, cross: CGFloat) -> CGSize {
        axis == .horizontal ? CGSize(width: main, height: cross) : CGSize(width: cross, height: main)
    }
}

/// A Row with a weighted child. `stackOrientation` makes a Spacer inside it
/// flexible along the row only, as it is in an HStack.
struct MobWeightedRowLayout: Layout {
    let alignment: VerticalAlignment
    let spacing: CGFloat

    static var layoutProperties: LayoutProperties {
        var properties = LayoutProperties()
        properties.stackOrientation = .horizontal
        return properties
    }

    private var stack: MobWeightedStack {
        MobWeightedStack(axis: .horizontal, spacing: spacing) { [alignment] in $0[alignment] }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        stack.sizeThatFits(proposal, subviews)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        stack.place(in: bounds, proposal, subviews)
    }
}

/// A Column with a weighted child; see `MobWeightedRowLayout`.
struct MobWeightedColumnLayout: Layout {
    let alignment: HorizontalAlignment
    let spacing: CGFloat

    static var layoutProperties: LayoutProperties {
        var properties = LayoutProperties()
        properties.stackOrientation = .vertical
        return properties
    }

    private var stack: MobWeightedStack {
        MobWeightedStack(axis: .vertical, spacing: spacing) { [alignment] in $0[alignment] }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        stack.sizeThatFits(proposal, subviews)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        stack.place(in: bounds, proposal, subviews)
    }
}

// A VStack that can be lazy without duplicating the call site. SwiftUI has no
// way to pick between VStack and LazyVStack at runtime inside one expression,
// and @ViewBuilder's `if` produces two different view identities — which is
// fine here because `lazy` is fixed for a given node's position in the tree.
// `weighted`: MobWeightedColumnLayout via AnyLayout (MOB-569). A lazy stack
// ignores it; inside a vertical scroll there is no leftover height to split.
struct MobEitherStack<Content: View>: View {
    let lazy: Bool
    let alignment: HorizontalAlignment
    let spacing: CGFloat
    let weighted: Bool
    @ViewBuilder let content: Content

    init(
        lazy: Bool,
        alignment: HorizontalAlignment,
        spacing: CGFloat,
        weighted: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.lazy = lazy
        self.alignment = alignment
        self.spacing = spacing
        self.weighted = weighted
        self.content = content()
    }

    var body: some View {
        if lazy {
            LazyVStack(alignment: alignment, spacing: spacing) { content }
        } else {
            let layout = weighted
                ? AnyLayout(MobWeightedColumnLayout(alignment: alignment, spacing: spacing))
                : AnyLayout(VStackLayout(alignment: alignment, spacing: spacing))
            layout { content }
        }
    }
}
