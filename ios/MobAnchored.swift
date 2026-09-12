import SwiftUI

// ── Anchored (MOB-190) ───────────────────────────────────────────────────────
//
// `:anchored` takes exactly two children: [0] the ANCHOR (a popover's trigger),
// rendered in flow, and [1] the PANEL, rendered by `MobAnchoredPanelHost` at the
// root ZStack so that it OVERLAYS the page. That is the only arrangement no
// ancestor can defeat: a Box with corner_radius clips, a vertical Scroll clips
// its main axis, and an in-flow overlay inside either measures (0,0,0,0) —
// invisible AND untappable. Not `.popover(isPresented:)` either: it adapts to
// a sheet on iPhone, brings its own arrow and dimming, and dismisses itself,
// while the BEAM owns open/closed here.
//
// The anchor publishes its bounds through an anchorPreference; the host
// resolves them against the root and places the panel with
// `MobAnchoredPosition`, a verbatim port of the Android bridge's
// `MobAnchoredPositionProvider` (itself the web's positionPopup()): a
// main-axis flip when the requested side has no room AND the opposite one
// does, then a clamp to the window (edge_padding plus the safe area) while the
// anchor is on screen. `on_tap` on the node means DISMISS: with a handler, a
// tap outside the panel is reported and the screen flips its assign — the
// panel never closes itself, so its state cannot disagree with the screen's.

struct MobAnchoredEntry {
    let owner: MobNode
    let panel: MobNode
    let bounds: Anchor<CGRect>
}

struct MobAnchoredKey: PreferenceKey {
    static var defaultValue: [MobAnchoredEntry] = []

    static func reduce(value: inout [MobAnchoredEntry], nextValue: () -> [MobAnchoredEntry]) {
        value.append(contentsOf: nextValue())
    }
}

struct MobAnchoredView: View {
    let node: MobNode

    var body: some View {
        let children = node.childNodes
        let anchor = children.first
        let panel = children.count > 1 ? children[1] : nil

        Group {
            if let anchor, let panel {
                MobNodeView(node: anchor)
                    .anchorPreference(key: MobAnchoredKey.self, value: .bounds) { bounds in
                        [MobAnchoredEntry(owner: node, panel: panel, bounds: bounds)]
                    }
            } else if let only = anchor ?? panel {
                // Closed (anchor alone) and pinned-open-with-no-trigger both
                // degrade to a plain in-flow child, so the node keeps its id,
                // its frame and its identity either way.
                MobNodeView(node: only)
            }
        }
        .padding(node.paddingEdgeInsets)
    }
}

struct MobAnchoredPanelHost: View {
    let entries: [MobAnchoredEntry]
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        if !entries.isEmpty {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        if let dismiss = entry.owner.onTap {
                            // A tap anywhere outside the panel is a dismiss
                            // request. Reported, not acted on: the BEAM decides.
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { dismiss() }
                        }
                        MobAnchoredPanel(
                            entry: entry,
                            anchorRect: proxy[entry.bounds],
                            container: proxy.size,
                            safeArea: proxy.safeAreaInsets,
                            rightToLeft: layoutDirection == .rightToLeft
                        )
                    }
                }
            }
        }
    }
}

private struct MobAnchoredPanel: View {
    let entry: MobAnchoredEntry
    let anchorRect: CGRect
    let container: CGSize
    let safeArea: EdgeInsets
    let rightToLeft: Bool

    @State private var panelSize: CGSize = .zero

    var body: some View {
        let owner = entry.owner
        let edge = CGFloat(owner.anchoredEdgePadding)
        // The panel is measured against the whole window, so a fill_width
        // column inside it would be screen wide and a long paragraph would never
        // wrap short. Cap it here rather than making every component carry a
        // width — same defaults as the Android bridge.
        let maxWidth = owner.anchoredPanelMaxWidth > 0
            ? CGFloat(owner.anchoredPanelMaxWidth) : max(1, container.width - 2 * edge)
        let maxHeight = owner.anchoredPanelMaxHeight > 0
            ? CGFloat(owner.anchoredPanelMaxHeight) : max(1, container.height - 2 * edge)
        let origin = MobAnchoredPosition.origin(
            anchor: anchorRect,
            panel: panelSize,
            container: container,
            params: MobAnchoredPosition.Params(owner: owner, edge: edge, safeArea: safeArea),
            rightToLeft: rightToLeft
        )

        MobNodeView(node: entry.panel)
            .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .topLeading)
            .background(
                GeometryReader { geo in
                    Color.clear.onChange(of: geo.size, initial: true) { _, size in
                        panelSize = size
                    }
                }
            )
            // Hidden until measured: the first pass positions a zero-size
            // panel, and showing it would flash the content at the wrong spot.
            .opacity(panelSize == .zero ? 0 : 1)
            .offset(x: origin.x, y: origin.y)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// The web's positionPopup(), transliterated — byte-for-byte the same arithmetic
// as the Android bridge's MobAnchoredPositionProvider, so the two platforms
// cannot drift: a main-axis-only flip when BOTH halves hold, then an
// unconditional clamp on both axes while the anchor is on screen. `align` is
// never flipped, and there is no shift-along-align fallback.
enum MobAnchoredPosition {
    struct Params {
        let side: String
        let align: String
        let sideOffset: CGFloat
        let alignOffset: CGFloat
        let nudgeX: CGFloat
        let nudgeY: CGFloat
        let padLeft: CGFloat
        let padTop: CGFloat
        let padRight: CGFloat
        let padBottom: CGFloat
        let flip: Bool
        let clamp: Bool

        init(owner: MobNode, edge: CGFloat, safeArea: EdgeInsets) {
            side = owner.anchoredSide ?? "bottom"
            // `align` lands in boxAlign for every node; anchored only knows
            // start / end, and anything else (including the box default
            // "top_leading") is the Android default, center.
            align = ["start", "end"].contains(owner.boxAlign) ? owner.boxAlign : "center"
            sideOffset = CGFloat(owner.anchoredSideOffset)
            alignOffset = CGFloat(owner.anchoredAlignOffset)
            nudgeX = CGFloat(owner.anchoredPanelOffsetX)
            nudgeY = CGFloat(owner.anchoredPanelOffsetY)
            // The safe area is added per edge; it is zero on edges without a bar.
            padLeft = edge + safeArea.leading
            padTop = edge + safeArea.top
            padRight = edge + safeArea.trailing
            padBottom = edge + safeArea.bottom
            flip = owner.anchoredFlip
            clamp = owner.anchoredClamp
        }
    }

    static func origin(
        anchor: CGRect, panel: CGSize, container: CGSize, params: Params, rightToLeft rtl: Bool
    ) -> CGPoint {
        let vw = container.width
        let vh = container.height
        let pw = panel.width
        let ph = panel.height

        // Mirror once, up front, the way the web does with isRTL; everything
        // after this is absolute arithmetic.
        var side = params.side
        if rtl {
            switch side {
            case "left": side = "right"
            case "right": side = "left"
            default: break
            }
        }
        let vertical = side == "top" || side == "bottom"
        var align = params.align
        if rtl && vertical {
            switch align {
            case "start": align = "end"
            case "end": align = "start"
            default: break
            }
        }
        let alignOffset = (rtl && vertical) ? -params.alignOffset : params.alignOffset

        if params.flip {
            switch side {
            case "bottom":
                if anchor.maxY + params.sideOffset + ph > vh - params.padBottom &&
                    anchor.minY - params.sideOffset - ph > params.padTop {
                    side = "top"
                }
            case "top":
                if anchor.minY - params.sideOffset - ph < params.padTop &&
                    anchor.maxY + params.sideOffset + ph < vh - params.padBottom {
                    side = "bottom"
                }
            case "right":
                if anchor.maxX + params.sideOffset + pw > vw - params.padRight &&
                    anchor.minX - params.sideOffset - pw > params.padLeft {
                    side = "left"
                }
            case "left":
                if anchor.minX - params.sideOffset - pw < params.padLeft &&
                    anchor.maxX + params.sideOffset + pw < vw - params.padRight {
                    side = "right"
                }
            default: break
            }
        }

        var x: CGFloat
        var y: CGFloat
        if side == "top" || side == "bottom" {
            y = side == "bottom" ? anchor.maxY + params.sideOffset : anchor.minY - ph - params.sideOffset
            // Note the sign asymmetry on "end": a positive align_offset pushes
            // the panel INWARD, exactly as the web engines do.
            switch align {
            case "start": x = anchor.minX + alignOffset
            case "end": x = anchor.maxX - pw - alignOffset
            default: x = anchor.minX + (anchor.width - pw) / 2 + alignOffset
            }
        } else {
            x = side == "right" ? anchor.maxX + params.sideOffset : anchor.minX - pw - params.sideOffset
            switch align {
            case "start": y = anchor.minY + alignOffset
            case "end": y = anchor.maxY - ph - alignOffset
            default: y = anchor.minY + (anchor.height - ph) / 2 + alignOffset
            }
        }

        x += params.nudgeX
        y += params.nudgeY

        // Clamp only while the ANCHOR is on screen. Clamping unconditionally is
        // what made an open panel park itself at the top of the window and
        // follow the user down the page after its trigger had scrolled away.
        let anchorOnScreen = anchor.maxY > 0 && anchor.minY < vh && anchor.maxX > 0 && anchor.minX < vw
        if params.clamp && anchorOnScreen {
            // If the panel is wider than the room, the upper bound collapses to
            // the lower one and it pins flush at the leading edge — the edge
            // carrying the title. Same as the web's Math.min(Math.max(...)).
            x = min(max(x, params.padLeft), max(params.padLeft, vw - pw - params.padRight))
            y = min(max(y, params.padTop), max(params.padTop, vh - ph - params.padBottom))
        }
        return CGPoint(x: x, y: y)
    }
}
