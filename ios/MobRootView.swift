// MobRootView.swift — SwiftUI entry point. Observes MobViewModel and renders the
// node tree pushed by BEAM NIFs via MobViewModel.setRoot().

import SwiftUI
import AVKit
import WebKit

// ── Native view component registry ───────────────────────────────────────────
// Register platform-native views by name at app startup. The name is the
// Elixir module with "Elixir." stripped and "." replaced with "_":
//   MyApp.ChartComponent → "MyApp_ChartComponent"
//
//   MobNativeViewRegistry.shared.register("MyApp_ChartComponent") { props, send in
//       AnyView(ChartView(data: props["data"]) { index in
//           send("tapped", ["index": index])
//       })
//   }

public typealias MobNativeSend = (_ event: String, _ payload: [String: Any]) -> Void
public typealias MobNativeViewFactory = (_ props: [String: Any], _ send: @escaping MobNativeSend) -> AnyView

public final class MobNativeViewRegistry {
    public static let shared = MobNativeViewRegistry()
    private var factories: [String: MobNativeViewFactory] = [:]

    public func register(_ name: String, factory: @escaping MobNativeViewFactory) {
        factories[name] = factory
    }

    func view(for node: MobNode) -> AnyView? {
        guard let name = node.nativeViewModule,
              let factory = factories[name],
              let props = node.nativeViewProps as? [String: Any] else { return nil }
        let handle = node.nativeViewHandle
        // -1 means the BEAM couldn't get a native component slot (pool
        // exhausted — MOB-100). Render nothing rather than a view whose
        // events would go nowhere; matches Android's MobNativeViewRegistry
        // early-return for the same case.
        guard handle >= 0 else { return nil }
        let send: MobNativeSend = { event, payload in
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                mob_send_component_event(handle, event, json)
            }
        }
        return factory(props, send)
    }
}

enum MobLayoutWeightAxis {
    case horizontal
    case vertical
}

extension View {
    @ViewBuilder
    func ifLet<T>(_ value: T?, transform: (Self, T) -> some View) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }

    /// Apply Mob gesture handlers from a node — long press, double tap, swipe.
    /// Each is opt-in (nil callbacks become no-ops). Per-widget; most widgets
    /// won't have any of these set, so the cost is one nil check per gesture.
    /// Drag gesture is only attached if at least one swipe handler is set
    /// (otherwise it would interfere with ScrollView and tap behaviors).
    @ViewBuilder
    func mobGestures(_ node: MobNode) -> some View {
        let hasSwipe =
            node.onSwipe != nil ||
            node.onSwipeLeft != nil ||
            node.onSwipeRight != nil ||
            node.onSwipeUp != nil ||
            node.onSwipeDown != nil

        self
            .ifLet(node.onLongPress) { view, cb in
                view.onLongPressGesture(minimumDuration: 0.5) { cb() }
            }
            .ifLet(node.onDoubleTap) { view, cb in
                view.onTapGesture(count: 2) { cb() }
            }
            .ifLet(hasSwipe ? node : nil) { view, n in
                view.gesture(
                    DragGesture(minimumDistance: 30)
                        .onEnded { value in
                            let dx = value.translation.width
                            let dy = value.translation.height
                            let direction: String
                            if abs(dx) > abs(dy) {
                                direction = dx > 0 ? "right" : "left"
                            } else {
                                direction = dy > 0 ? "down" : "up"
                            }
                            n.onSwipe?(direction)
                            switch direction {
                            case "left":  n.onSwipeLeft?()
                            case "right": n.onSwipeRight?()
                            case "up":    n.onSwipeUp?()
                            case "down":  n.onSwipeDown?()
                            default:      break
                            }
                        }
                )
            }
    }
}

// Allow MobNode to be used as ForEach identity (NSObject provides hash/isEqual).
extension MobNode: Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}

// Logical icon name → SF Symbol. Logical names are platform-agnostic so the
// same Elixir tree renders an Apple-styled icon on iOS and a Material-styled
// icon on Android. Unknown logical names pass through verbatim, letting
// power users use raw SF Symbol identifiers (e.g. "globe.americas.fill").
private func sfSymbolName(_ logical: String) -> String {
    switch logical {
    case "settings":      return "gear"
    case "back":          return "chevron.left"
    case "forward":       return "chevron.right"
    case "close":         return "xmark"
    case "add":           return "plus"
    case "remove":        return "minus"
    case "edit":          return "pencil"
    case "check":         return "checkmark"
    case "chevron_right": return "chevron.right"
    case "chevron_left":  return "chevron.left"
    case "chevron_up":    return "chevron.up"
    case "chevron_down":  return "chevron.down"
    case "info":          return "info.circle"
    case "warning":       return "exclamationmark.triangle"
    case "error":         return "xmark.circle"
    case "search":        return "magnifyingglass"
    case "trash":         return "trash"
    case "share":         return "square.and.arrow.up"
    case "more":          return "ellipsis"
    case "menu":          return "line.3.horizontal"
    case "refresh":       return "arrow.clockwise"
    case "favorite":      return "heart"
    case "favorite_filled": return "heart.fill"
    case "star":          return "star"
    case "star_filled":   return "star.fill"
    case "user":          return "person"
    case "home":          return "house"
    case "history":       return "clock.arrow.circlepath"
    case "list":          return "list.bullet"
    case "qr_code":       return "qrcode"
    case "link":          return "link"
    case "snowflake":     return "snowflake"
    default:              return logical  // raw SF Symbol pass-through
    }
}

extension MobNode {
    var childNodes: [MobNode] {
        children.compactMap { $0 as? MobNode }
    }

    /// EdgeInsets that honour per-edge padding props (padding_top etc.).
    /// Falls back to the uniform `padding` value for any unset edge.
    var paddingEdgeInsets: EdgeInsets {
        let top    = paddingTop    >= 0 ? paddingTop    : padding
        let right  = paddingRight  >= 0 ? paddingRight  : padding
        let bottom = paddingBottom >= 0 ? paddingBottom : padding
        let left   = paddingLeft   >= 0 ? paddingLeft   : padding
        return EdgeInsets(top: top, leading: left, bottom: bottom, trailing: right)
    }

    /// Resolved SwiftUI Font respecting font family, size, weight, and italic.
    var resolvedFont: Font {
        let size: CGFloat = textSize > 0 ? textSize : 16.0
        let weight: Font.Weight = {
            switch fontWeight {
            case "bold":     return .bold
            case "semibold": return .semibold
            case "medium":   return .medium
            case "light":    return .light
            case "thin":     return .thin
            default:         return .regular
            }
        }()
        var font: Font
        if let resolvedName = MobNode.resolveFontName(primary: fontFamily) {
            font = Font.custom(resolvedName, size: size)
        } else {
            font = .system(size: size)
        }
        font = font.weight(weight)
        if italic { font = font.italic() }
        return font
    }

    /// Walks `[primary, ...fallback]` (fallback from the last `Mob.Theme.set/1`
    /// via `mob_font_fallback()`) and returns the first name `UIFont` can
    /// actually load. `Font.custom` itself has no "did this resolve?" signal —
    /// it silently substitutes the system font — so this uses `UIFont(name:)`
    /// purely as a resolvability probe. `nil` means "use the system font",
    /// same as today's no-font-set behavior. Logs when the primary choice
    /// misses so a missing/misnamed font is diagnosable instead of just
    /// looking like the wrong font. See MOB_FONTS.md.
    static func resolveFontName(primary: String?) -> String? {
        let candidates = ([primary].compactMap { $0 } + mob_font_fallback()).filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }

        for (index, name) in candidates.enumerated() where UIFont(name: name, size: 12) != nil {
            if index > 0 {
                NSLog("[mob/font] \"%@\" not found — fell back to \"%@\"", candidates[0], name)
            }
            return name
        }

        NSLog("[mob/font] none of %@ resolved — using system font", candidates)
        return nil
    }

    var textAlignEnum: TextAlignment {
        switch textAlign {
        case "center": return .center
        case "right":  return .trailing
        default:       return .leading
        }
    }

    var frameTextAlignment: Alignment {
        switch textAlign {
        case "center": return .center
        case "right":  return .trailing
        default:       return .leading
        }
    }

    /// Extra inter-line spacing derived from the lineHeight multiplier.
    var computedLineSpacing: CGFloat {
        guard lineHeight > 0 else { return 0 }
        let size: CGFloat = textSize > 0 ? textSize : 16.0
        return (lineHeight - 1.0) * size
    }
}

// ── Recursive node renderer ────────────────────────────────────────────────

struct MobNodeView: View {
    let node: MobNode
    private let layoutWeightAxis: MobLayoutWeightAxis?
    // Set only for the direct children of a VERTICAL `scroll` that opted in with
    // `lazy: true`. Everywhere else the stacks stay eager.
    //
    // Opt-in because laziness has observable consequences beyond speed: rows
    // below the fold are never built, so they never register a frame and
    // `Mob.Test.element_frames` / `tap_id` cannot address them, and a
    // `LazyVStack`'s `contentSize` only reflects built rows — so
    // `scroll_to(:bottom)` under-scrolls and `screenshot_tour` truncates.
    // `lazy_list` already makes that trade explicitly; silently applying it to
    // every scroll would change harness behaviour under apps that never asked.
    private let lazyContainer: Bool

    init(
        node: MobNode,
        layoutWeightAxis: MobLayoutWeightAxis? = nil,
        lazyContainer: Bool = false
    ) {
        self.node = node
        self.layoutWeightAxis = layoutWeightAxis
        self.lazyContainer = lazyContainer
    }

    var body: some View {
        Group {
            switch node.nodeType {
            case .column:
                // Mob screens are written scroll > column > rows, so the column
                // inside a scroll is where the rows actually live. Making the
                // scroll's own stack lazy would buy nothing — this is the stack
                // that has 200 children. Rendering the column itself lazily keeps
                // every one of its modifiers below intact, which flattening the
                // column away would not.
                MobEitherStack(lazy: lazyContainer, alignment: .leading) {
                    ForEach(mobIdentifiedChildren(node.childNodes)) { item in
                        MobNodeView(node: item.node, layoutWeightAxis: .vertical)
                    }
                }
                // fill_height: true lets a column flex to fill its parent so children
                // with Spacer() or fill_height of their own can pin to the bottom.
                // Without maxHeight the VStack hugs its content vertically and a
                // trailing footer sits directly below the last child instead of the
                // parent's bottom edge.
                .frame(maxWidth: .infinity, maxHeight: node.fillHeight ? .infinity : nil, alignment: .topLeading)
                .padding(node.paddingEdgeInsets)
                .background(node.backgroundColor.map { Color($0) } ?? Color.clear)
                .ifLet(node.onTap) { view, tap in
                    view.contentShape(Rectangle()).onTapGesture { tap() }
                }
                .mobGestures(node)

            case .row:
                let alignment: VerticalAlignment = {
                    switch node.rowAlign {
                    case "top":      return .top
                    case "bottom":   return .bottom
                    case "baseline": return .lastTextBaseline
                    default:         return .center
                    }
                }()
                HStack(alignment: alignment, spacing: 0) {
                    ForEach(mobIdentifiedChildren(node.childNodes)) { item in
                        MobNodeView(node: item.node, layoutWeightAxis: .horizontal)
                    }
                }
                // Without maxWidth: .infinity an HStack hugs its content.
                // Flex Spacers inside then have nothing to expand into and
                // centering tricks (spacer / content / spacer) collapse.
                // Honors `fill_width: true` to match Android's row behaviour.
                //
                // `alignment: .leading` is load-bearing: .frame defaults to
                // .center, so a fill_width row whose children don't span the
                // full width floated to the middle on iOS while Compose's
                // Row (horizontalArrangement = Start) left-aligned it. Every
                // row-based component drifted — headers, checkbox and radio
                // rows each centred independently and read as ragged. The
                // column case above already passes .topLeading for the same
                // reason.
                .ifLet(node.fillWidth ? () : nil) { view, _ in
                    view.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(node.paddingEdgeInsets)
                .background(node.backgroundColor.map { Color($0) } ?? Color.clear)
                .ifLet(node.onTap) { view, tap in
                    view.contentShape(Rectangle()).onTapGesture { tap() }
                }
                .mobGestures(node)

            case .box:
                MobBox(node: node)

            case .label:
                // Only span the parent's full width when the caller explicitly
                // asks (via `fill_width: true` or a non-leading `text_align`).
                // Defaulting to .frame(maxWidth: .infinity) made every Text
                // greedily fill its container, which broke centering when a
                // Text sat inside a row meant to size to its content (the row
                // would inflate to full width and the box's centering had
                // nothing to position).
                let textShouldFill = node.fillWidth || node.textAlign == "center" || node.textAlign == "right"
                Text(node.text ?? "")
                    .font(node.resolvedFont)
                    .foregroundColor(node.textColor.map { Color($0) } ?? Color.primary)
                    .multilineTextAlignment(node.textAlignEnum)
                    .lineSpacing(node.computedLineSpacing)
                    .kerning(node.letterSpacing)
                    .ifLet(textShouldFill ? () : nil) { view, _ in
                        view.frame(maxWidth: .infinity, alignment: node.frameTextAlignment)
                    }
                    .padding(node.paddingEdgeInsets)
                    .background(node.backgroundColor.map { Color($0) } ?? Color.clear)
                    .ifLet(node.onTap) { view, tap in
                        view.contentShape(Rectangle()).onTapGesture { tap() }
                    }
                    .mobGestures(node)

            case .icon:
                // Resolve logical icon name (e.g. "settings") to the matching
                // SF Symbol. textSize controls glyph size; textColor controls tint.
                // node.text serves as accessibility label when set.
                Image(systemName: sfSymbolName(node.iconName ?? "questionmark"))
                    .font(.system(size: node.textSize > 0 ? node.textSize : 20))
                    .foregroundColor(node.textColor.map { Color($0) } ?? Color.primary)
                    .padding(node.paddingEdgeInsets)
                    .background(node.backgroundColor.map { Color($0) } ?? Color.clear)
                    .ifLet(node.onTap) { view, tap in
                        view.contentShape(Rectangle()).onTapGesture { tap() }
                    }
                    .ifLet(node.text) { view, label in view.accessibilityLabel(label) }
                    .ifLet(node.accessibilityId) { view, id in view.accessibilityIdentifier(id) }
                    .mobGestures(node)

            case .button:
                // Padding + background INSIDE the Button's label, not outside.
                // SwiftUI's Button only registers taps on its content view's
                // bounds — applying `.padding()` to the Button itself leaves
                // the padded area visually present but not tappable, so users
                // tap the visible edge of the button and nothing happens.
                // contentShape(Rectangle()) ensures the full padded area is
                // hit-testable even when the background is .clear.
                Button(action: { node.onTap?() }) {
                    Text(node.text ?? "")
                        .font(node.resolvedFont)
                        .foregroundColor(node.textColor.map { Color($0) } ?? Color.clear)
                        .lineLimit(1)
                        .frame(maxWidth: node.fillWidth ? .infinity : nil)
                        .padding(node.paddingEdgeInsets)
                        .background(node.backgroundColor.map { Color($0) } ?? Color.clear)
                        .contentShape(Rectangle())
                }
                .clipShape(RoundedRectangle(cornerRadius: node.cornerRadius))
                .ifLet(node.accessibilityId) { view, id in
                    view.accessibilityIdentifier(id)
                }

            case .scroll:
                let isHorizontal = node.axis == "horizontal"
                let axes: Axis.Set = isHorizontal ? .horizontal : .vertical
                ScrollView(axes, showsIndicators: node.showIndicator) {
                    if isHorizontal {
                        HStack(alignment: .top, spacing: 0) {
                            // Never lazy here. A LazyVStack under a HORIZONTAL
                            // ScrollView would be lazy on the wrong axis: the
                            // vertical axis is bounded and never scrolls, so
                            // anything below the fold would never be built at
                            // all rather than built on demand.
                            ForEach(mobIdentifiedChildren(node.childNodes)) { item in
                                MobNodeView(node: item.node)
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(mobIdentifiedChildren(node.childNodes)) { item in
                                MobNodeView(node: item.node, lazyContainer: node.lazyContent)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .padding(node.paddingEdgeInsets)
                .background(node.backgroundColor.map { Color($0) } ?? Color.clear)
                // Expose the node :id on the backing UIScrollView so the test
                // harness (Mob.Test.scroll_info/scroll_to) can address it by id.
                .ifLet(node.nativeViewId) { view, id in view.accessibilityIdentifier(id) }
                // ── Batch 5 Tier 1: scroll position observation ──
                // SwiftUI's onScrollGeometryChange is iOS 18+. On older iOS
                // there's no clean SwiftUI API for raw offset; UIKit-backed
                // alternative pending. Until then, scroll events are silently
                // unavailable on iOS 17 (renderer still accepts on_scroll
                // props — they just won't fire).
                .modifier(MobScrollObserverGate(node: node, isHorizontal: isHorizontal))

            case .textField:
                let placeholder = node.placeholder ?? ""
                let initialText = node.text ?? ""
                MobTextField(node: node, placeholder: placeholder, initialText: initialText)
                    .padding(node.paddingEdgeInsets)

            case .toggle:
                MobToggle(node: node)
                    .padding(node.paddingEdgeInsets)

            case .slider:
                MobSlider(node: node)
                    .padding(node.paddingEdgeInsets)

            case .divider:
                Divider()
                    .frame(height: node.thickness)
                    .overlay(
                        node.color.map { Color($0) } ?? Color(UIColor.separator)
                    )
                    .padding(node.paddingEdgeInsets)

            case .spacer:
                if node.fixedSize > 0 {
                    // Constrain both axes so a sized Spacer works as a fixed
                    // gap in both VStack (column) and HStack (row). Without
                    // the width constraint, an HStack treats it as flexible
                    // alongside other Spacers and the layout collapses.
                    Spacer().frame(width: node.fixedSize, height: node.fixedSize)
                } else {
                    Spacer()
                }

            case .image:
                MobImage(node: node)
                    .padding(node.paddingEdgeInsets)

            case .lazyList:
                MobLazyList(node: node)

            case .progress:
                let trackColor = node.color.map { Color($0) } ?? Color.accentColor
                if node.value.isNaN {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(trackColor)
                        .frame(maxWidth: .infinity)
                        .padding(node.paddingEdgeInsets)
                } else {
                    ProgressView(value: node.value, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(trackColor)
                        .frame(maxWidth: .infinity)
                        .padding(node.paddingEdgeInsets)
                }

            case .tabBar:
                let tabs = node.tabDefs as? [[String: Any]] ?? []
                MobTabView(node: node, tabs: tabs)

            case .video:
                if let src = node.src {
                    MobVideoPlayer(src: src, autoplay: node.videoAutoplay,
                                   loop: node.videoLoop, controls: node.videoControls)
                        .ifLet(node.fixedWidth  > 0 ? node.fixedWidth  : nil) { v, w in v.frame(width: CGFloat(w)) }
                        .ifLet(node.fixedHeight > 0 ? node.fixedHeight : nil) { v, h in v.frame(height: CGFloat(h)) }
                        .padding(node.paddingEdgeInsets)
                }

            case .cameraPreview:
                MobCameraPreviewView(facing: node.cameraFacing)
                    .ifLet(node.fixedWidth  > 0 ? node.fixedWidth  : nil) { v, w in v.frame(width: CGFloat(w)) }
                    .ifLet(node.fixedHeight > 0 ? node.fixedHeight : nil) { v, h in v.frame(height: CGFloat(h)) }
                    .padding(node.paddingEdgeInsets)

            case .webView:
                MobWebView(node: node)
                    .ifLet(node.fixedWidth  > 0 ? node.fixedWidth  : nil) { v, w in v.frame(width: CGFloat(w)) }
                    .ifLet(node.fixedHeight > 0 ? node.fixedHeight : nil) { v, h in v.frame(height: CGFloat(h)) }
                    .padding(node.paddingEdgeInsets)

            case .nativeView:
                if let view = MobNativeViewRegistry.shared.view(for: node) {
                    view.padding(node.paddingEdgeInsets)
                }

            case .canvas:
                MobCanvasView(node: node)
                    .padding(node.paddingEdgeInsets)

            case .gpuView:
                MobGpuView(node: node)
                    .ifLet(node.fixedWidth  > 0 ? node.fixedWidth  : nil) { v, w in v.frame(width: CGFloat(w)) }
                    .ifLet(node.fixedHeight > 0 ? node.fixedHeight : nil) { v, h in v.frame(height: CGFloat(h)) }
                    .padding(node.paddingEdgeInsets)

            case .sheet:
                MobSheetView(node: node)

            @unknown default:
                EmptyView()
            }
        }
        // Weight sizing must wrap the node's own visual decoration. Applying
        // the frame from the parent after MobNodeView has painted its
        // background leaves an expanded transparent region around a
        // content-sized fill. Repaint that decoration on the weighted frame
        // so iOS matches Compose's weight-before-nodeModifier ordering.
        .modifier(MobLayoutWeight(node: node, axis: layoutWeightAxis))
        // Per-node offset — applied uniformly to every node type. Default is
        // (0, 0) which is a no-op. Used by SquareTriangle's hexagonal
        // snowflake to position rings absolutely within a center-aligned box.
        .offset(x: CGFloat(node.offsetX), y: CGFloat(node.offsetY))
        // Record on-screen frame + set accessibilityIdentifier for any node
        // carrying an :id, so the agent can read positions via the
        // element_frames NIF without a screenshot.
        .modifier(MobFrameTracker(node: node))
    }
}

private struct MobLayoutWeight: ViewModifier {
    let node: MobNode
    let axis: MobLayoutWeightAxis?

    @ViewBuilder
    func body(content: Content) -> some View {
        if node.layoutWeight > 0, let axis {
            switch axis {
            case .horizontal:
                decorate(content.frame(maxWidth: .infinity, alignment: .leading))
            case .vertical:
                decorate(content.frame(maxHeight: .infinity, alignment: .top))
            }
        } else {
            content
        }
    }

    private func decorate(_ content: some View) -> some View {
        content
            .mobBoxBackground(node: node)
            .overlay(
                RoundedRectangle(cornerRadius: node.cornerRadius)
                    .stroke(node.borderColor.map { Color($0) } ?? Color.clear,
                            lineWidth: node.borderWidth)
                    .allowsHitTesting(false)
            )
    }
}

// MobFrameTracker — for any node with an :id, set it as the accessibility
// identifier and report the element's global frame (logical points) to the C
// registry as it lays out / moves. Untagged nodes pass through untouched, so
// there's no cost unless a dev opts an element in by giving it an :id.
// Per-tracker bookkeeping, deliberately a reference type held by @State rather
// than @State scalars. Two reasons: mutating it never invalidates the view (the
// writes happen inside a GeometryReader's layout-driven callback, once per
// display frame per element during a transition — the classic "modifying state
// during view update" shape), and the values stay readable during the same
// transaction that tears the view down, which is exactly when .onDisappear
// needs the seq.
private final class MobFrameBox {
    var seq: UInt64 = 0
    var generation: UInt64 = 0
}

private struct MobFrameTracker: ViewModifier {
    let node: MobNode

    @State private var box = MobFrameBox()

    func body(content: Content) -> some View {
        // A sheet's own switch-case view is a zero-size anchor used only to
        // attach `.sheet(isPresented:)` — its real, visible content is
        // presented in a detached overlay that this GeometryReader can't
        // see. Reporting the anchor's frame would silently report 0x0
        // instead of the sheet's actual on-screen bounds, so tracking is
        // skipped entirely rather than publishing a frame known to be wrong.
        if let id = node.nativeViewId, node.nodeType != .sheet {
            content
                .accessibilityIdentifier(id)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            // Registration must not depend on onChange alone.
                            // onChange fires on frame *value* changes, so an
                            // element that reappears at the position it left
                            // (a tab switched back to, a row scrolled back into
                            // range) would never re-register after the
                            // .onDisappear below removed it — and `initial:` is
                            // not guaranteed to re-run when SwiftUI preserved
                            // the view identity across that disappearance.
                            // Registering on appear makes every
                            // disappear/reappear cycle self-healing.
                            .onAppear {
                                box.generation = mob_frame_generation()
                                record(id, geo.frame(in: .global))
                            }
                            .onChange(of: geo.frame(in: .global), initial: true) { _, frame in
                                record(id, frame)
                            }
                            // Kept after MOB-127, but not for the reason the
                            // original comment gave. A tracker only exists when
                            // the node HAS an id (the `if let` above), so the
                            // "unnamed nodes still shift" rationale was wrong in
                            // both directions. Two cases remain. A tracked node
                            // nested inside an UNNAMED repeated row still shifts
                            // wholesale, because the row itself keys by
                            // position — the documented mis-use, where `:id` is
                            // put on something inside the repeated element
                            // rather than on it. And the duplicate-id fallback:
                            // those keys embed a position, so they genuinely do
                            // move between nodes when a duplicated id's list
                            // shrinks. The hazard is the same — a frame value
                            // may be unchanged (equal-height rows), so nothing
                            // else here fires, and the id just taken over keeps
                            // the previous occupant's entry, or loses it to the
                            // departing tracker's .onDisappear.
                            .onChange(of: id) { _, newId in
                                record(newId, geo.frame(in: .global))
                            }
                            // Being in the BEAM tree isn't the same as being on
                            // screen: a LazyVStack row scrolled out of range, an
                            // inactive tab's subtree, or a dismissed sheet's
                            // content all stay in the tree (so nif_set_root's
                            // purge keeps them) while SwiftUI stops laying them
                            // out — and onChange won't fire for them again.
                            // Without this their last frame is reported forever
                            // and Mob.Test.tap_id taps whatever is there now.
                            .onDisappear { mob_unregister_frame(id, box.seq) }
                    }
                )
        } else {
            content
        }
    }

    private func record(_ id: String, _ frame: CGRect) {
        // Capture lazily as well as in onAppear: the ordering of onAppear
        // against onChange(initial: true) isn't contractual, and a write
        // stamped 0 is accepted rather than refused as stale.
        if box.generation == 0 {
            box.generation = mob_frame_generation()
        }
        let written = mob_register_frame(
            id, box.generation, Double(frame.minX), Double(frame.minY),
            Double(frame.width), Double(frame.height))

        // Keep the last SUCCESSFUL seq. A refused write returns 0, and
        // overwriting the token with 0 would make this tracker's .onDisappear
        // a permanent no-op (mob_unregister_frame ignores seq 0) — it could
        // then never clean up the entry it still owns. That bites when an
        // outgoing screen's `.move` writes are refused by the generation gate
        // and the incoming screen's element with the same :id isn't laid out
        // (a lazy row below the fold): the id stays in the tree so the purge
        // keeps it, nothing deletes it, and tap_id taps the old screen's
        // coordinates. Retaining the token is strictly safe — the
        // compare-and-delete still refuses to delete whenever an incoming
        // tracker has claimed the id since.
        if written != 0 {
            box.seq = written
        }
    }
}

// ── Box ──────────────────────────────────────────────────────────────────────
// Extracted from MobNodeView so the conditional sizing chain doesn't blow
// past SwiftUI's type-inference budget. When fixedWidth is set the box
// uses that exact width; otherwise it stretches to fill maxWidth (the
// original behavior). Same logic for fixedHeight (otherwise content-sized).
//
// The fixed-width path is what makes circular ring cells possible without
// a dedicated primitive — set width: N, height: N, corner_radius: N/2,
// border_color + border_width and the box renders as a ring.
// Tap wiring and accessibility semantics for a composite Box, kept out of
// MobBox's main modifier chain so the Swift type checker can cope.
private struct MobBoxSemantics: ViewModifier {
    let node: MobNode

    /// True when the box stands in for a control rather than plain layout —
    /// it carries a label, or the caller asked for a button role. Only then
    /// is it right to collapse the subtree into one accessibility element; a
    /// passive box with labelled children must keep them visible to VoiceOver.
    private var isAccessibilityControl: Bool {
        node.accessibilityLabel != nil || node.accessibilityRole == "button"
    }

    // Only .isButton is set explicitly. SwiftUI's AccessibilityTraits has no
    // .isNotEnabled member — the disabled trait is not something you add, it
    // is what `.disabled(true)` below already publishes to VoiceOver. An
    // explicit `.accessibilityAddTraits(.isNotEnabled)` does not compile.
    private var traits: AccessibilityTraits {
        node.accessibilityRole == "button" ? .isButton : []
    }

    func body(content: Content) -> some View {
        content
            // Branch on `onTap` presence only, never on `disabled`. `ifLet` is
            // @ViewBuilder if/else, i.e. _ConditionalContent — flipping the
            // branch gives SwiftUI a structurally different view and tears the
            // subtree down. `disabled` is routinely toggled, so branching on it
            // would drop a wrapped TextField's in-flight text and focus, and
            // re-present a wrapped Sheet. The check moves inside the closure,
            // where it costs nothing structurally.
            .ifLet(node.onTap) { view, tap in
                view.contentShape(Rectangle()).onTapGesture {
                    if !node.disabled { tap() }
                }
            }
            // Collapse to a single accessibility element whenever this box is
            // acting as a control. Traits added without collapsing land on
            // every descendant instead, so a role-only box would announce each
            // nested Text as its own button.
            .ifLet(isAccessibilityControl ? () : nil) { view, _ in
                view.accessibilityElement(children: .ignore)
            }
            .ifLet(node.accessibilityLabel) { view, label in
                view.accessibilityLabel(label)
            }
            // One OptionSet, so no _ConditionalContent branch on `disabled`.
            .accessibilityAddTraits(traits)
            // .disabled, not .allowsHitTesting: allowsHitTesting(false) makes
            // the view transparent to touches, so a disabled box used as a
            // blocking overlay or dimmed backdrop would pass taps through to
            // whatever sits behind it. .disabled blocks interaction in the
            // subtree while still consuming the touch.
            .disabled(node.disabled)
    }
}

private struct MobBox: View {
    let node: MobNode

    var body: some View {
        let alignment: Alignment = boxAlignmentFromString(node.boxAlign)

        let stack = ZStack(alignment: alignment) {
            ForEach(mobIdentifiedChildren(node.childNodes)) { item in
                MobNodeView(node: item.node)
            }
        }

        return Group {
            if node.fixedWidth > 0 {
                stack.frame(
                    width: CGFloat(node.fixedWidth),
                    height: node.fixedHeight > 0 ? CGFloat(node.fixedHeight) : nil,
                    alignment: alignment
                )
            } else if node.fixedHeight > 0 {
                stack
                    .frame(height: CGFloat(node.fixedHeight), alignment: alignment)
                    .frame(maxWidth: .infinity, alignment: alignment)
            } else if node.fillHeight {
                // fill_height: true is what lets a wrapping box stretch to the
                // viewport so center alignment lands on the visible midpoint
                // (e.g. for floating dialogs that need to sit mid-screen
                // regardless of their sibling's content size).
                stack.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            } else {
                stack.frame(maxWidth: .infinity, alignment: alignment)
            }
        }
        .padding(node.paddingEdgeInsets)
        .mobBoxBackground(node: node)
        .overlay(
            // Border opt-in via border_color + border_width on the BEAM side.
            // When width is 0 (default) the stroke draws nothing — no perf cost.
            // .allowsHitTesting(false) is critical: without it, SwiftUI routes
            // taps inside the border's bounding rect to the overlay instead of
            // the box's children, swallowing tap events on every nested button.
            RoundedRectangle(cornerRadius: node.cornerRadius)
                .stroke(node.borderColor.map { Color($0) } ?? Color.clear,
                        lineWidth: node.borderWidth)
                .allowsHitTesting(false)
        )
        .mobGestures(node)
        // Interaction + accessibility live in their own ViewModifier: folding
        // them into this chain inline pushed it past SwiftUI's type-inference
        // budget and the Swift build failed outright ("unable to type-check
        // this expression in reasonable time"). Same reason MobBox itself was
        // extracted from MobNodeView.
        .modifier(MobBoxSemantics(node: node))
        // (offset is applied uniformly by MobNodeView's body; not here)
    }
}

// Backgrounds for `MobBox`. When the active theme has `glass: true` the BEAM
// renderer sets `useGlass` on every box that has a `background:` so we swap
// the solid fill for a translucent material. Liquid Glass landed on iOS 26;
// on older systems we fall back to `.ultraThinMaterial` (visually similar,
// less expensive). Without `useGlass` the original solid behaviour is kept.
private extension View {
    @ViewBuilder
    func mobBoxBackground(node: MobNode) -> some View {
        let radius = node.cornerRadius
        let shape: AnyShape =
            radius > 0
            ? AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            : AnyShape(Rectangle())
        let fill = node.backgroundColor.map { Color($0) }

        if node.useGlass {
            // The glass surface must still carry the node's `background:`. The BEAM
            // only sets `useGlass` on boxes that asked for a background, so dropping
            // the colour here made every glassy box collapse to the same neutral
            // grey: selected/active chips became indistinguishable from unselected
            // siblings, and semantic fills (warning, accent, avatar variants) all
            // rendered identically. Android ignores `glass:` and keeps its solid
            // fill, so the same app stayed legible there and not here.
            //
            // `Glass.clear` (vs `Glass.regular`) — the surface is noticeably
            // more transparent; what's behind shows through. Card-style
            // surfaces look "floating" rather than "frosted". Switch to
            // `.regular` if a tinted, opaque-leaning glass is wanted.
            if #available(iOS 26.0, *) {
                // `Glass.tint` takes an Optional, so a box whose background failed
                // to resolve still gets plain untinted clear glass.
                self.glassEffect(.clear.tint(fill), in: shape)
            } else {
                // Pre-26 approximation. A material blurs whatever is behind it, so
                // the fill goes *behind* the material (a later `.background` sits
                // further back) and reads as frosted colour rather than being
                // painted over by the grey.
                self.background(.ultraThinMaterial, in: shape)
                    .background(fill ?? Color.clear, in: shape)
            }
        } else {
            // `in: shape` so the solid fill is clipped to the corner radius — without
            // it the fill is a plain rectangle and only the (separately-stroked)
            // border looks rounded, leaving square fill corners on non-glass boxes.
            self.background(fill ?? Color.clear, in: shape)
        }
    }
}

private func boxAlignmentFromString(_ s: String) -> Alignment {
    switch s {
    case "center":          return .center
    case "top":             return .top
    case "top_center":      return .top
    case "top_trailing":    return .topTrailing
    case "leading":         return .leading
    case "trailing":        return .trailing
    case "bottom":          return .bottom
    case "bottom_leading":  return .bottomLeading
    case "bottom_center":   return .bottom
    case "bottom_trailing": return .bottomTrailing
    default:                return .topLeading
    }
}

// ── Canvas (Mob.Canvas declarative draw spec) ────────────────────────────────
// Renders the node.canvasOps array via SwiftUI Canvas. Each op is an
// NSDictionary with an "op" key plus op-specific fields, pre-resolved by
// the Elixir renderer (color tokens already converted to ARGB integers).

private struct MobCanvasView: View {
    let node: MobNode

    // Tracks whether the active drag has emitted its "began" sample yet, so the
    // first onChanged reports phase "began" and the rest "dragging".
    @State private var dragging = false

    var body: some View {
        let canvas = Canvas { ctx, size in
            let ops = node.canvasOps as? [[String: Any]] ?? []
            for op in ops {
                drawOp(op, in: &ctx, size: size)
            }
        }
        .frame(
            width: node.canvasWidth > 0 ? CGFloat(node.canvasWidth) : nil,
            height: node.canvasHeight > 0 ? CGFloat(node.canvasHeight) : nil
        )

        // Finger-drag input: when the node registered an on_drag handle, attach a
        // continuous drag recognizer (the iOS analog of Android MobCanvas's
        // detectDragGestures). The Canvas frame is sized to the declared logical
        // units (points), and draw ops are drawn in that same space, so the
        // gesture's local-space location is already in canvas coordinates — no
        // pixel→logical rescale needed (unlike Android, where it is).
        //
        // minimumDistance: 0 is intentional: a finger-drawing canvas wants an
        // immediate response and a stationary tap to register as a single point
        // (a dot). This is a deliberate divergence from Android's
        // detectDragGestures, which has a touch-slop threshold, so a bare tap
        // fires a zero-length began/ended drag on iOS but nothing on Android.
        if node.onDrag != nil {
            canvas.gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Flip the @State flag only once, on the first sample, so
                        // a fast drag does not invalidate the view on every move.
                        let phase: String
                        if dragging {
                            phase = "dragging"
                        } else {
                            dragging = true
                            phase = "began"
                        }
                        node.onDrag?(
                            value.translation.width, value.translation.height,
                            value.location.x, value.location.y, phase
                        )
                    }
                    .onEnded { value in
                        dragging = false
                        node.onDrag?(
                            value.translation.width, value.translation.height,
                            value.location.x, value.location.y, "ended"
                        )
                    }
            )
        } else {
            canvas
        }
    }

    private func drawOp(_ op: [String: Any], in ctx: inout GraphicsContext, size: CGSize) {
        guard let opName = op["op"] as? String else { return }

        let color = canvasColor(op["color"])
        let opacity = (op["opacity"] as? Double) ?? 1.0
        let strokeStyle = canvasStrokeStyle(op)
        let isFill = (op["fill"] as? Bool) ?? false

        ctx.opacity = opacity
        defer { ctx.opacity = 1.0 }

        switch opName {
        case "line":
            let path = Path { p in
                p.move(to: CGPoint(x: cgNum(op["x1"]), y: cgNum(op["y1"])))
                p.addLine(to: CGPoint(x: cgNum(op["x2"]), y: cgNum(op["y2"])))
            }
            ctx.stroke(path, with: .color(color), style: strokeStyle)

        case "circle":
            let r = cgNum(op["r"])
            let rect = CGRect(x: cgNum(op["x"]) - r, y: cgNum(op["y"]) - r, width: r * 2, height: r * 2)
            let path = Path(ellipseIn: rect)
            if isFill { ctx.fill(path, with: .color(color)) } else { ctx.stroke(path, with: .color(color), style: strokeStyle) }

        case "ellipse":
            let rx = cgNum(op["rx"])
            let ry = cgNum(op["ry"])
            let rect = CGRect(x: cgNum(op["x"]) - rx, y: cgNum(op["y"]) - ry, width: rx * 2, height: ry * 2)
            let path = Path(ellipseIn: rect)
            if isFill { ctx.fill(path, with: .color(color)) } else { ctx.stroke(path, with: .color(color), style: strokeStyle) }

        case "arc":
            // Mob.Canvas arc convention: degrees, 0° to the right, sweeping clockwise.
            // SwiftUI Path.addArc uses radians; we negate for clockwise from the start.
            let center = CGPoint(x: cgNum(op["x"]), y: cgNum(op["y"]))
            let r = cgNum(op["r"])
            let start = Angle(degrees: cgDouble(op["start_deg"]))
            let end = Angle(degrees: cgDouble(op["end_deg"]))
            let path = Path { p in
                p.addArc(center: center, radius: r, startAngle: start, endAngle: end, clockwise: false)
            }
            ctx.stroke(path, with: .color(color), style: strokeStyle)

        case "rect":
            let rect = CGRect(
                x: cgNum(op["x"]),
                y: cgNum(op["y"]),
                width: cgNum(op["w"]),
                height: cgNum(op["h"])
            )
            let radius = cgNum(op["radius"])
            let path: Path = radius > 0
                ? Path(roundedRect: rect, cornerRadius: radius)
                : Path(rect)
            if isFill { ctx.fill(path, with: .color(color)) } else { ctx.stroke(path, with: .color(color), style: strokeStyle) }

        case "path":
            guard let pts = op["points"] as? [[Double]], !pts.isEmpty else { return }
            let closed = (op["closed"] as? Bool) ?? false
            let path = Path { p in
                p.move(to: CGPoint(x: pts[0][0], y: pts[0][1]))
                for pt in pts.dropFirst() {
                    p.addLine(to: CGPoint(x: pt[0], y: pt[1]))
                }
                if closed || isFill { p.closeSubpath() }
            }
            if isFill { ctx.fill(path, with: .color(color)) } else { ctx.stroke(path, with: .color(color), style: strokeStyle) }

        case "text":
            let str = (op["text"] as? String) ?? ""
            let size = cgNum(op["size"])
            let weight = canvasFontWeight(op["weight"] as? String)
            var text = Text(str).font(.system(size: size, weight: weight))
            if let family = op["family"] as? String, !family.isEmpty {
                text = Text(str).font(.custom(family, size: size).weight(weight))
            }
            let resolved = ctx.resolve(text.foregroundColor(color))
            // Anchor: SwiftUI's draw(at:anchor:) takes a UnitPoint.
            let anchor: UnitPoint = {
                switch op["anchor"] as? String {
                case "center": return .leading  // y stays top; horizontal center handled by switching
                default:       return .topLeading
                }
            }()
            // For horizontal anchor handling we measure first.
            let measured = resolved.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
            let x = cgNum(op["x"])
            let y = cgNum(op["y"])
            let drawX: CGFloat = {
                switch op["anchor"] as? String {
                case "center": return x - measured.width / 2
                case "end":    return x - measured.width
                default:       return x
                }
            }()
            ctx.draw(resolved, at: CGPoint(x: drawX, y: y), anchor: .topLeading)
            _ = anchor // anchor variable unused after switching to manual offset; kept to document intent

        case "image":
            guard let src = op["source"] as? String else { return }
            if let img = UIImage(named: src) {
                let rect = CGRect(
                    x: cgNum(op["x"]),
                    y: cgNum(op["y"]),
                    width: cgNum(op["w"]),
                    height: cgNum(op["h"])
                )
                ctx.draw(Image(uiImage: img), in: rect)
            }

        default:
            break
        }
    }
}

// ── Canvas helpers ───────────────────────────────────────────────────────────

private func cgNum(_ value: Any?) -> CGFloat {
    if let d = value as? Double { return CGFloat(d) }
    if let i = value as? Int { return CGFloat(i) }
    if let n = value as? NSNumber { return CGFloat(n.doubleValue) }
    return 0
}

private func cgDouble(_ value: Any?) -> Double {
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    if let n = value as? NSNumber { return n.doubleValue }
    return 0
}

private func canvasColor(_ value: Any?) -> Color {
    // Pre-resolved ARGB integer from the renderer, or hex string fallback.
    if let argb = value as? Int {
        let a = Double((argb >> 24) & 0xFF) / 255.0
        let r = Double((argb >> 16) & 0xFF) / 255.0
        let g = Double((argb >>  8) & 0xFF) / 255.0
        let b = Double((argb >>  0) & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b, opacity: a)
    }
    if let n = value as? NSNumber {
        return canvasColor(n.intValue)
    }
    if let hex = value as? String, hex.hasPrefix("#") {
        let scanner = Scanner(string: String(hex.dropFirst()))
        var rgb: UInt64 = 0
        if scanner.scanHexInt64(&rgb) {
            let r = Double((rgb >> 16) & 0xFF) / 255.0
            let g = Double((rgb >>  8) & 0xFF) / 255.0
            let b = Double((rgb >>  0) & 0xFF) / 255.0
            return Color(red: r, green: g, blue: b)
        }
    }
    return Color.black
}

private func canvasStrokeStyle(_ op: [String: Any]) -> StrokeStyle {
    let width = cgNum(op["width"])
    let cap: CGLineCap = {
        switch op["cap"] as? String {
        case "round":  return .round
        case "square": return .square
        default:       return .butt
        }
    }()
    let join: CGLineJoin = {
        switch op["join"] as? String {
        case "round": return .round
        case "bevel": return .bevel
        default:      return .miter
        }
    }()
    let dash: [CGFloat] = (op["dash"] as? [Any])?.compactMap { cgNum($0) } ?? []
    return StrokeStyle(
        lineWidth: width > 0 ? width : 1,
        lineCap: cap,
        lineJoin: join,
        dash: dash
    )
}

private func canvasFontWeight(_ name: String?) -> Font.Weight {
    switch name {
    case "thin":     return .thin
    case "light":    return .light
    case "medium":   return .medium
    case "semibold": return .semibold
    case "bold":     return .bold
    default:         return .regular
    }
}

// ── Tab bar ───────────────────────────────────────────────────────────────────

private struct MobTabView: View {
    let node: MobNode
    let tabs: [[String: Any]]

    var body: some View {
        let activeId = node.activeTab ?? (tabs.first?["id"] as? String ?? "")
        TabView(selection: Binding(
            get: { activeId },
            set: { newId in node.onTabSelect?(newId) }
        )) {
            // Keyed on the tab's own id, not on position. This ForEach does
            // iterate child nodes (the subscript below), so toggling a
            // conditional tab shifted every later tab's whole content subtree
            // into its neighbour's identity — text-field buffers and scroll
            // positions discarded, and every named node in those subtrees
            // re-registered with the frame registry.
            ForEach(mobIdentifiedTabs(tabs)) { item in
                let index = item.index
                let tab = item.tab
                if index < node.childNodes.count {
                    let child = node.childNodes[index]
                    MobNodeView(node: child)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(child.backgroundColor.map { Color($0) } ?? Color.clear)
                        .tabItem {
                            Label(
                                tab["label"] as? String ?? "",
                                systemImage: sfSymbolName(tab["icon"] as? String ?? "circle")
                            )
                        }
                        .tag(tab["id"] as? String ?? "\(index)")
                        .ignoresSafeArea(.container, edges: .bottom)
                }
            }
        }
    }
}

// ── Video player ─────────────────────────────────────────────────────────────

private struct MobVideoPlayer: UIViewControllerRepresentable {
    let src: String
    let autoplay: Bool
    let loop: Bool
    let controls: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        let url: URL
        if src.hasPrefix("http://") || src.hasPrefix("https://") {
            url = URL(string: src)!
        } else {
            url = URL(fileURLWithPath: src)
        }
        let player = AVPlayer(url: url)
        vc.player = player
        vc.showsPlaybackControls = controls
        if loop {
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem, queue: .main) { _ in
                player.seek(to: .zero)
                player.play()
            }
        }
        if autoplay { player.play() }
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
}

// ── Camera preview ────────────────────────────────────────────────────────

// Custom UIView whose backing layer is an AVCaptureVideoPreviewLayer.
// UIKit automatically keeps the layer frame in sync with the view bounds —
// no manual frame management required.
private class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var cameraLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct MobCameraPreviewView: UIViewRepresentable {
    let facing: String

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.backgroundColor = .black
        view.cameraLayer.videoGravity = .resizeAspectFill
        // Connect immediately if the session is already running.
        view.cameraLayer.session = g_preview_session
        rotatePreviewConnection(view: view)
        // Observe future session changes (start, stop, facing swap).
        context.coordinator.startObserving(view: view)
        return view
    }

    // Pin the preview to portrait so what the user sees matches the
    // upright frame we ship to the model. Without this, the sensor's
    // landscape-native output renders sideways in a portrait UI.
    private func rotatePreviewConnection(view: CameraPreviewUIView) {
        guard let conn = view.cameraLayer.connection else { return }
        if #available(iOS 17.0, *) {
            if conn.isVideoRotationAngleSupported(90) {
                conn.videoRotationAngle = 90
            }
        } else if conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }
    }

    func updateUIView(_ view: CameraPreviewUIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject {
        private var observer: NSObjectProtocol?
        private weak var hostView: CameraPreviewUIView?

        func startObserving(view: CameraPreviewUIView) {
            hostView = view
            observer = NotificationCenter.default.addObserver(
                forName: .mobCameraSessionChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let view = self?.hostView else { return }
                view.cameraLayer.session = g_preview_session
                if let conn = view.cameraLayer.connection {
                    if #available(iOS 17.0, *) {
                        if conn.isVideoRotationAngleSupported(90) {
                            conn.videoRotationAngle = 90
                        }
                    } else if conn.isVideoOrientationSupported {
                        conn.videoOrientation = .portrait
                    }
                }
            }
        }

        deinit {
            if let obs = observer { NotificationCenter.default.removeObserver(obs) }
        }
    }
}

extension Notification.Name {
    static let mobCameraSessionChanged = Notification.Name("MobCameraSessionChanged")
}

// ── WebView ───────────────────────────────────────────────────────────────────

private let kMobJsShimSwift =
    "(function(){" +
    "if(window.mob)return;" +
    "var _h=[];" +
    "window.mob={" +
      "send:function(d){window.webkit.messageHandlers.mob.postMessage(JSON.stringify(d));}," +
      "onMessage:function(h){_h.push(h);return function(){_h=_h.filter(function(x){return x!==h;});};}," +
      "_dispatch:function(j){try{var d=JSON.parse(j);_h.forEach(function(h){h(d);});}catch(e){}}" +
    "};" +
    "})();"

private struct MobWebView: View {
    let node: MobNode

    var body: some View {
        VStack(spacing: 0) {
            if let title = node.webViewTitle {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            MobWKWebView(node: node)
        }
    }
}

private struct MobWKWebView: UIViewRepresentable {
    let node: MobNode

    func makeCoordinator() -> Coordinator { Coordinator(node: node) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "mob")
        let shim = WKUserScript(source: kMobJsShimSwift,
                                injectionTime: .atDocumentStart,
                                forMainFrameOnly: true)
        config.userContentController.addUserScript(shim)
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        g_webview = wv
        if let urlStr = node.webViewUrl, let url = URL(string: urlStr) {
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        g_webview = wv
        context.coordinator.node = node
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var node: MobNode
        init(node: MobNode) { self.node = node }

        // JS → Elixir: window.mob.send(data) arrives here.
        // Delegates to mob_deliver_webview_message() in mob_nif.m.
        func userContentController(_ ucc: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "mob", let json = message.body as? String else { return }
            mob_deliver_webview_message(json)
        }

        // URL whitelist enforcement.
        func webView(_ wv: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url?.absoluteString else {
                decisionHandler(.allow); return
            }
            let allowStr = node.webViewAllow ?? ""
            let allowList = allowStr.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            guard !allowList.isEmpty else { decisionHandler(.allow); return }
            if allowList.contains(where: { url.hasPrefix($0) }) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                mob_deliver_webview_blocked(url)
            }
        }
    }
}

// ── Input component views ──────────────────────────────────────────────────

private struct MobTextField: View {
    let node: MobNode
    let placeholder: String
    let initialText: String
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(node: MobNode, placeholder: String, initialText: String) {
        self.node = node
        self.placeholder = placeholder
        self.initialText = initialText
        _text = State(initialValue: initialText)
    }

    private var keyboardType: UIKeyboardType {
        switch node.keyboardTypeStr {
        case "number":  return .numberPad
        case "decimal": return .decimalPad
        case "email":   return .emailAddress
        case "phone":   return .phonePad
        case "url":     return .URL
        default:        return .default
        }
    }

    private var submitLabel: SubmitLabel {
        switch node.returnKeyStr {
        case "next":   return .next
        case "go":     return .go
        case "search": return .search
        case "send":   return .send
        default:       return .done
        }
    }

    @ViewBuilder
    private var field: some View {
        if node.isSecure {
            SecureField(placeholder, text: $text)
        } else {
            TextField(placeholder, text: $text)
        }
    }

    var body: some View {
        field
            .focused($isFocused)
            .keyboardType(keyboardType)
            .submitLabel(submitLabel)
            .onSubmit {
                node.onSubmit?()
                // dismiss for terminal actions; "next" intentionally keeps keyboard open
                if node.returnKeyStr != "next" { isFocused = false }
            }
            .onChange(of: text) { _, newValue in
                node.onChangeStr?(newValue)
            }
            .onChange(of: isFocused) { _, focused in
                if focused { node.onFocus?() } else { node.onBlur?() }
            }
            // Sync from parent when the `value:` prop changes externally —
            // but only if the user isn't actively typing (which would yank
            // the cursor and overwrite their in-flight edits). This is the
            // controlled-input fix for the case where Elixir code updates
            // the bound value via Mob.Socket.assign without user input.
            .onChange(of: initialText) { _, newValue in
                if !isFocused && text != newValue {
                    text = newValue
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
            // Only contribute keyboard-toolbar items when THIS field is
            // focused. Without the `if isFocused` guard, every MobTextField
            // on the screen contributes its own Done button to the shared
            // keyboard accessory toolbar — producing N stacked Done buttons
            // when there are N fields visible. Guarded, only the focused
            // field's button shows.
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if isFocused {
                        Spacer()
                        Button("Done") { isFocused = false }
                    }
                }
            }
    }
}

private struct MobToggle: View {
    let node: MobNode
    @State private var isOn: Bool

    init(node: MobNode) {
        self.node = node
        _isOn = State(initialValue: node.checked)
    }

    var body: some View {
        let label = node.text ?? ""
        Toggle(label, isOn: $isOn)
            .onChange(of: isOn) { _, newValue in
                node.onChangeBool?(newValue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // issues.md #8: SwiftUI's Toggle("Label", …) initializer does
            // not propagate the label string into the underlying control's
            // accessibilityLabel — the AX tree exposes the visual Text as
            // a separate node and the Switch as a button with empty label.
            // Setting it here lets `Mob.Test.toggle(node, "Notifications")`
            // find the toggle via plain label match.
            .accessibilityLabel(label)
    }
}

private struct MobSlider: View {
    let node: MobNode
    @State private var value: Double

    init(node: MobNode) {
        self.node = node
        let initial = node.value.isNaN ? node.minValue : node.value
        _value = State(initialValue: initial)
    }

    var body: some View {
        // issues.md #7: SwiftUI's plain Slider doesn't emit AX adjustable
        // actions unless `.accessibilityAdjustableAction` is attached. Without
        // it, VoiceOver users (and `Mob.Test.adjust_slider/4` which calls the
        // same AX API) see :ok back from increment/decrement but the value
        // never changes. Default step is (max - min) / 10 — the same default
        // VoiceOver picks for native UISlider when no explicit step is set.
        let step = (node.maxValue - node.minValue) / 10.0
        Slider(value: $value, in: node.minValue...node.maxValue)
            .onChange(of: value) { _, newValue in
                node.onChangeFloat?(newValue)
            }
            .tint(node.color.map { Color($0) } ?? Color.accentColor)
            .frame(maxWidth: .infinity)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    value = Swift.min(value + step, node.maxValue)
                    node.onChangeFloat?(value)
                case .decrement:
                    value = Swift.max(value - step, node.minValue)
                    node.onChangeFloat?(value)
                @unknown default:
                    break
                }
            }
    }
}

// MobSheetView — native modal bottom sheet. Presentation is owned by this
// view's own @State, not by the transient MobNode the BEAM rebuilds fresh
// every render — SwiftUI preserves @State across re-renders that keep the
// same view identity (same tree position, same case in MobNodeView's
// switch), exactly like MobToggle/MobSlider preserve user-driven state
// against a BEAM-pushed node above. That's what makes "content updates
// without dismissing/re-presenting" and "removing the node dismisses it"
// both fall out for free: a rerender with the sheet still present reuses
// this state; a rerender without it tears the view (and its presentation)
// down entirely.
// Measured intrinsic content height plus the bottom safe-area inset that
// applies *inside* the sheet. `.presentationDetents(.height(x))` sets the
// sheet's TOTAL height, but the content region is inset by the home indicator,
// so a detent of exactly the content height leaves the last rows under it and
// makes a sheet that should fit exactly scroll instead.
private struct MobSheetContentMetrics: Equatable {
    var height: CGFloat = 0
    var bottomInset: CGFloat = 0
}

private struct MobSheetContentHeightKey: PreferenceKey {
    static var defaultValue = MobSheetContentMetrics()

    static func reduce(value: inout MobSheetContentMetrics, nextValue: () -> MobSheetContentMetrics) {
        let next = nextValue()
        value = MobSheetContentMetrics(
            height: max(value.height, next.height),
            bottomInset: max(value.bottomInset, next.bottomInset)
        )
    }
}

// 0 means "root geometry not read yet". Distinguishing unknown from a real
// measurement matters: defaulting to a small number collapsed the first
// presentation of every content sheet to a hairline.
private struct MobAvailableSheetHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private extension EnvironmentValues {
    var mobAvailableSheetHeight: CGFloat {
        get { self[MobAvailableSheetHeightKey.self] }
        set { self[MobAvailableSheetHeightKey.self] = newValue }
    }
}

private struct MobSheetView: View {
    let node: MobNode
    @Environment(\.mobAvailableSheetHeight) private var availableHeight
    @State private var isPresented = true
    @State private var dismissSent = false
    // nil until the content has actually been measured. A numeric sentinel
    // here is what produced a 1pt sheet on first presentation: content can
    // only be measured after the sheet is up, so the first detent was
    // computed from the sentinel.
    @State private var contentMetrics: MobSheetContentMetrics?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: $isPresented, onDismiss: sendDismissOnce) {
                sheetContent
            }
    }

    private func sendDismissOnce() {
        guard !dismissSent else { return }
        dismissSent = true
        node.onDismiss?()
    }

    private var contentDetent: [String: Any]? {
        node.sheetDetents?.compactMap { $0 as? [String: Any] }
            .first { $0["type"] as? String == "content" }
    }

    /// Ceiling for the sheet. `availableHeight` is 0 until the root has
    /// reported geometry; treat that as "no ceiling known yet" rather than
    /// clamping to it, so an unmeasured root can never collapse the sheet.
    private var maximumHeight: CGFloat {
        let configured = (contentDetent?["max_height"] as? NSNumber).map { CGFloat(truncating: $0) }

        switch (configured, availableHeight > 0) {
        case let (.some(limit), true): return min(limit, availableHeight)
        case let (.some(limit), false): return limit
        case (.none, true): return availableHeight
        case (.none, false): return .greatestFiniteMagnitude
        }
    }

    /// Total sheet height for the detent: measured content plus the sheet's
    /// own bottom safe-area inset, capped. nil while unmeasured.
    private var limitedContentHeight: CGFloat? {
        guard let metrics = contentMetrics, metrics.height > 0 else { return nil }
        return max(1, min(metrics.height + metrics.bottomInset, maximumHeight))
    }

    private var sheetBody: some View {
        VStack(spacing: 0) {
            ForEach(mobIdentifiedChildren(node.childNodes)) { item in
                MobNodeView(node: item.node)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(node.paddingEdgeInsets)
    }

    @ViewBuilder
    private var sheetContent: some View {
        Group {
            if contentDetent != nil {
                ScrollView(.vertical) {
                    sheetBody
                        .fixedSize(horizontal: false, vertical: true)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: MobSheetContentHeightKey.self,
                                    value: MobSheetContentMetrics(
                                        height: geometry.size.height,
                                        bottomInset: geometry.safeAreaInsets.bottom
                                    )
                                )
                            }
                        }
                }
                .frame(maxHeight: maximumHeight)
                .onPreferenceChange(MobSheetContentHeightKey.self) { measured in
                    // Ignore sub-point churn so a measurement that feeds the
                    // detent, which resizes the sheet, which re-measures,
                    // settles instead of oscillating.
                    let changed =
                        contentMetrics.map {
                            abs(measured.height - $0.height) > 0.5
                                || abs(measured.bottomInset - $0.bottomInset) > 0.5
                        } ?? true

                    if changed, measured.height > 0 {
                        contentMetrics = measured
                    }
                }
            } else {
                sheetBody
            }
        }
        // Screen readers should treat the sheet as a self-contained modal —
        // VoiceOver focus stays inside it until dismissed, matching
        // .presentationDetents/.sheet's own system-modal behavior.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .ifLet(node.backgroundColor) { view, bg in
            view.presentationBackground(Color(bg))
        }
        // sheetCornerRadius has its own -1-means-unset sentinel (see
        // MobNode.h) so an explicit corner_radius: 0 (square corners) is
        // distinguishable from "not set" (system default radius).
        .ifLet(node.sheetCornerRadius >= 0 ? node.sheetCornerRadius : nil) { view, radius in
            view.presentationCornerRadius(radius)
        }
        .presentationDetents(detentSet)
        .ifLet(hasCustomIndicator ? () : nil) { view, _ in
            view.presentationDragIndicator(.hidden)
        }
        .overlay(alignment: .top) {
            if hasCustomIndicator {
                customIndicator
            }
        }
    }

    private var detentSet: Set<PresentationDetent> {
        if contentDetent != nil {
            // Content can only be measured once the sheet is on screen, so the
            // first evaluation has nothing to size against. Present at .medium
            // for that one frame and switch to the exact height as soon as the
            // measurement lands — the previous sentinel-based version resolved
            // to .height(1) and flashed a hairline on every presentation.
            guard let height = limitedContentHeight else { return [.medium] }
            return [.height(height)]
        }

        let builtInDetents = node.sheetDetents?.compactMap { $0 as? String } ?? []
        var resolved: Set<PresentationDetent> = []
        if builtInDetents.contains("medium") { resolved.insert(.medium) }
        if builtInDetents.contains("large") { resolved.insert(.large) }
        // Mob.Renderer normalizes :detents through Mob.UI.normalize_sheet_detents!/1
        // at the encode boundary, so an invalid list now raises before it ever
        // reaches here rather than arriving as an unknown string. This fallback
        // is therefore only reachable for a node whose detents key is absent
        // entirely.
        return resolved.isEmpty ? [.medium, .large] : resolved
    }

    // Mob.UI.sheet/2 requires all four custom-indicator props together or
    // none — checking one non-sentinel value is enough once that contract
    // holds, but check all four defensively for the same hand-built-node
    // reason as detentSet above.
    private var hasCustomIndicator: Bool {
        node.dragIndicatorColor != nil
            && node.dragIndicatorWidth >= 0
            && node.dragIndicatorHeight >= 0
            && node.dragIndicatorRailHeight >= 0
    }

    private var customIndicator: some View {
        Capsule()
            .fill(node.dragIndicatorColor.map { Color($0) } ?? Color.secondary)
            .frame(width: node.dragIndicatorWidth, height: node.dragIndicatorHeight)
            .frame(height: node.dragIndicatorRailHeight)
            .padding(.top, 6)
    }
}

// ── Local-file image cache ───────────────────────────────────────────────────
// UIImage(contentsOfFile:) reads the file and builds a CGImageSource-backed
// image; the decompression itself is deferred to first draw, which is why
// UIImage.preparingForDisplay() exists. Either way it is synchronous work on
// whichever thread touches it, and unlike UIImage(named:) there is no system
// cache behind it, so nothing survives to the next render.
// The asset-catalogue path gets one for free; the loose-file path gets nothing.
// Calling it from a SwiftUI `body`, as MobImage used to, means that
// read-and-decode runs on the main thread on every evaluation of the node. That
// is bad in the steady state and much worse across a navigation: MobRootView
// keys its subtree on .id(currentNavVersion), so a push or a pop tears the
// whole tree down and rebuilds it, and every local-file image on the incoming
// screen is decoded from scratch while the transition is mid-animation. A
// screen with a handful of photos on it is a visible stall.
//
// Be precise about what this does and does not fix, because the surrounding
// issue is easy to overclaim. A first visit to a screen is a cold cache by
// definition, so a forward push to a new screen full of images is helped not at
// all: that stall needs downsampling, or preparingForDisplay() off the main
// thread, and both are their own change. What goes away here is every decode
// AFTER the first: re-rendering a screen already up, and popping back to one
// visited before, which is the case .id(currentNavVersion) turned from free
// into full price.
//
// This cache is only for the local-file branch. The http(s) branch goes through
// AsyncImage, which is backed by URLSession's own caching, and is left alone.
final class MobImageCache {
    static let shared = MobImageCache()

    private let cache = NSCache<NSString, UIImage>()

    // path -> the key currently holding that path's image, so a rewrite can
    // evict the entry it superseded. See image(atPath:).
    private let keysByPath = NSCache<NSString, NSString>()

    private init() {
        cache.totalCostLimit = Self.budget()
    }

    /// How many decoded bytes we are willing to hold, scaled to the device.
    ///
    /// Cost is counted in decoded bytes (see decodedByteCost below). For scale,
    /// a full-bleed image on a 3x phone is about 1290 * 2796 * 4 which is
    /// roughly 14 MB decoded, so 64 MB holds four or five full-screen photos or
    /// many hundreds of list thumbnails. That is comfortably more than one
    /// screen's worth, which is what makes a back-and-forth between two screens
    /// free without letting a Mob app spend the bulk of its footprint on images
    /// it is not showing.
    ///
    /// It is a fraction of physical memory rather than a flat 64 MB because a
    /// flat number is only defensible on the largest device it will run on.
    /// Mob targets old hardware deliberately, and on a 2 GB iPhone a 64 MB
    /// image cache is a real share of what the app is allowed before the
    /// watchdog takes it, on top of a BEAM that has already reserved its own.
    /// A sixty-fourth gives 16 MB on a 1 GB device and 32 MB on a 2 GB one, and
    /// reaches the 64 MB ceiling from 4 GB up.
    ///
    /// NSCache also evicts on the system's memory-pressure notifications
    /// independently of this number. That is a backstop, not the plan: the
    /// documented behaviour is deliberately vague about when it fires, so the
    /// budget has to be defensible on its own.
    private static func budget() -> Int {
        let physical = ProcessInfo.processInfo.physicalMemory
        let scaled = Int(physical / 64)
        return min(64 * 1024 * 1024, max(16 * 1024 * 1024, scaled))
    }

    /// Decoded image for a local file path, from cache when we have a current
    /// one. Returns nil on the same inputs the uncached call returned nil for,
    /// so the caller's placeholder fallback is unchanged.
    func image(atPath path: String) -> UIImage? {
        guard let key = Self.cacheKey(forPath: path) else {
            // No usable key means no way to tell a later edit of this path from
            // what we might already be holding, so bypass the cache entirely
            // and do exactly what the uncached code did. This is also the
            // missing-file path: stat fails, the decode below fails too, and
            // the caller draws its placeholder as before.
            return UIImage(contentsOfFile: path)
        }

        if let hit = cache.object(forKey: key) { return hit }

        guard let decoded = UIImage(contentsOfFile: path) else {
            // Deliberately no negative caching. A path can become valid later
            // (a download landing into it, a file the app is about to write),
            // and a remembered nil would pin the placeholder there for the life
            // of the process. Re-attempting costs a failed open on a file that
            // stays broken, which is much cheaper than being permanently wrong.
            return nil
        }

        let cost = Self.decodedByteCost(decoded)

        // NSCache silently DROPS an object whose cost exceeds totalCostLimit:
        // setObject appears to succeed and the very next object(forKey:) returns
        // nil. Verified against Foundation rather than assumed. Without this
        // guard a full-resolution photo is re-decoded on every render exactly as
        // before, plus a stat, and the reader has no way to tell.
        //
        // The numbers are not hypothetical: a 12 MP capture is 4032 * 3024 * 4,
        // about 48.75 MB decoded, which is over the 48 MB budget of a 3 GB
        // device and over the 32 MB of a 2 GB one. So on the very hardware the
        // scaled budget exists to protect, the single most likely large image in
        // a Mob app does not fit.
        //
        // Skipping the insert is the honest floor, not the fix. The real fix is
        // to stop holding full-resolution bitmaps for a view that is drawing
        // them at a fraction of the size: downsample at load with
        // CGImageSourceCreateThumbnailAtIndex against the node's measured frame.
        // That changes what is rendered, not just what is remembered, so it is
        // its own change with its own verification rather than a rider here.
        guard cost <= cache.totalCostLimit else { return decoded }

        // Drop the entry this path used to have. The old key encodes the old
        // size and mtime, so nothing can ever look it up again, but it keeps
        // occupying budget until NSCache evicts it, and what NSCache evicts to
        // make room is some other screen's images. A path rewritten in place
        // over and over, which is exactly what a camera capture or a thumbnail
        // refresh does, would otherwise push the rest of the app out of the
        // cache one dead full-size bitmap at a time.
        //
        // The side table is itself an NSCache so it cannot grow without bound.
        // Losing an entry to eviction only costs us this cleanup, degrading to
        // the behaviour we would have had without it.
        if let previous = keysByPath.object(forKey: path as NSString), previous != key {
            cache.removeObject(forKey: previous)
        }
        keysByPath.setObject(key, forKey: path as NSString)

        cache.setObject(decoded, forKey: key, cost: cost)
        return decoded
    }

    /// Identity of a file's *contents*, as far as we can cheaply establish it.
    private static func cacheKey(forPath path: String) -> NSString? {
        // Keyed on (path, size, mtime) rather than on the path alone, because a
        // file can be rewritten in place: a photo re-cropped over its original,
        // a downloaded avatar overwritten at the same cache location. Path-only
        // keying serves the superseded picture for the rest of the process,
        // which is a correctness bug, not a performance one. Size is in the key
        // as well as mtime because a rewrite inside the filesystem's timestamp
        // granularity is not impossible, and the length usually moves when the
        // bytes do.
        //
        // The price is one stat(2) per body evaluation, and that is the one
        // syscall this change knowingly leaves on the main thread. It is the
        // right trade: a stat on an inode the VFS already has hot is a few
        // microseconds, against the tens of milliseconds a JPEG decode costs on
        // the same thread, so we are buying "never stale" for roughly a
        // thousandth of what we are saving. Both alternatives are worse: drop
        // the stat and serve stale images, or push cache-busting onto authors
        // by making them vary the path, which they would forget to do.
        // Resolve first. attributesOfItem does NOT traverse a terminal symlink,
        // while UIImage(contentsOfFile:) does, so a symlinked path would be
        // keyed on the link's own size and mtime while being decoded from the
        // target. Rewriting the target then leaves the key unchanged and serves
        // the superseded image for ever, which is precisely the failure the
        // (path, size, mtime) key exists to prevent, silently defeated for the
        // one case where a path is most likely to be a stable alias for
        // changing content.
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved) else {
            return nil
        }
        // Bypass rather than substitute a default. Falling back to 0 here would
        // silently degrade the key to path-only, which is the exact correctness
        // bug this function exists to avoid, and it would do it invisibly. The
        // documented policy above is that an unusable key means no caching.
        guard
            let size = (attrs[.size] as? NSNumber)?.uint64Value,
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        else {
            return nil
        }
        // \u{1} separates the fields so a path ending in digits cannot run into
        // the size and collide with a different (path, size) pair, the same
        // trick mobIdentifiedChildren uses for its keys.
        return "\(path)\u{1}\(size)\u{1}\(mtime)" as NSString
    }

    /// What one cached image actually costs us in memory.
    private static func decodedByteCost(_ image: UIImage) -> Int {
        // The decoded footprint, not the file size. A 2 MB JPEG is ~14 MB of
        // bitmap once decoded, so budgeting by file size would let the cache
        // hold several times the memory it believes it is holding and defeat
        // the point of having a limit. Read it off the backing CGImage where
        // there is one: bytesPerRow already accounts for row padding and for
        // formats that are not four bytes per pixel. Fall back to a 4-bytes-
        // per-pixel estimate at the image's scale for the images that have no
        // CGImage (a CIImage-backed one, say). An estimate is fine there; the
        // number only steers eviction.
        if let cg = image.cgImage {
            return cg.bytesPerRow * cg.height
        }
        let scale = image.scale
        return Int(image.size.width * scale * image.size.height * scale * 4)
    }

    // Thread safety: NSCache does its own locking, and everything wrapped
    // around it here is either pure (deriving a key string) or a filesystem
    // read. The lookup is a check-then-insert and so is not atomic: two
    // threads can miss on the same key and both decode. That race costs one
    // duplicate decode and a setObject that overwrites an equal value; it
    // cannot yield a wrong image, because the key encodes the file's size and
    // mtime, so two threads that derived the same key were looking at the same
    // bytes. Holding a lock across the whole lookup would instead serialise
    // decodes onto the caller, which is the cost this cache exists to remove.
}

// ── Lazy list ────────────────────────────────────────────────────────────────
//
// Its own view rather than a case in MobNodeView's body, because it needs
// @State to latch `on_end_reached` and MobNodeView renders every node in the
// tree: an Optional<Int> on that struct is storage paid thousands of times over
// for a thing only one node type uses.
private struct MobLazyList: View {
    let node: MobNode

    // The child count we last fired `on_end_reached` for.
    //
    // Without this, the callback fires on content REPLACEMENT rather than on
    // arrival at the end. Since MOB-127 keyed children on the author's `:id`,
    // replacing a list's contents gives every row a new identity, so the last
    // row's `.onAppear` runs again even though nobody scrolled. A search screen
    // re-queried on each keystroke then fires one pagination request per
    // keystroke, where before it fired none (MOB-141).
    //
    // Latching on the count is what makes this survive a replacement: only
    // navigation changes the container's identity, so this @State outlives a
    // new tree arriving for the same screen. Re-querying and getting twenty
    // results again is suppressed; loading a page and going twenty to forty is
    // not, which is exactly the pagination flow the callback exists for.
    //
    // What it does NOT fix: a re-query whose result count differs every time
    // still fires once per distinct count. Distinguishing "new content, user is
    // at the end" from "new content, user never scrolled" needs scroll
    // position, not content identity, and the honest fix for that is to drive
    // this from the scroll observer rather than from `.onAppear`. Handlers
    // should still be written to be idempotent.
    @State private var firedForCount: Int?

    var body: some View {
        let children = mobIdentifiedChildren(node.childNodes)

        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(children) { item in
                    MobNodeView(node: item.node)
                        .onAppear {
                            guard item.index == children.count - 1 else { return }
                            guard firedForCount != children.count else { return }
                            firedForCount = children.count
                            node.onTap?()
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .padding(node.paddingEdgeInsets)
        .background(node.backgroundColor.map { Color($0) } ?? Color.clear)
        .ifLet(node.nativeViewId) { view, id in view.accessibilityIdentifier(id) }
    }
}

private struct MobImage: View {
    let node: MobNode

    private var contentMode: ContentMode {
        node.contentModeStr == "fill" ? .fill : .fit
    }

    private var placeholder: Color {
        node.placeholderColor.map { Color($0) } ?? Color(UIColor.systemGray5)
    }

    var body: some View {
        Group {
            if let src = node.src {
                if src.hasPrefix("http://") || src.hasPrefix("https://"),
                   let url = URL(string: src) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: contentMode)
                        default:
                            placeholder
                        }
                    }
                } else if let uiImage = MobImageCache.shared.image(atPath: src) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(
            width: node.fixedWidth  > 0 ? node.fixedWidth  : nil,
            height: node.fixedHeight > 0 ? node.fixedHeight : nil
        )
        .clipShape(RoundedRectangle(cornerRadius: node.cornerRadius))
    }
}

// ── Root view — observed by the hosting controller ─────────────────────────

public struct MobRootView: View {
    @ObservedObject var model = MobViewModel.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var currentRoot: MobNode?
    @State private var currentTransition: String = "none"
    // Local mirror of model.navVersion so the .id() change happens INSIDE
    // the withAnimation block (the model's @Published value changes via
    // SwiftUI observation, which doesn't carry the animation context and
    // produces a default crossfade instead of the .move transition).
    @State private var currentNavVersion: Int = 0
    @State private var availableSheetHeight: CGFloat = 1

    /// Share of the root's height a content-detent sheet may occupy at most.
    /// Keeps a tall sheet visibly a sheet — parent still showing behind it —
    /// rather than an unrecognisable full-screen cover.
    private static let sheetHeightCeilingFraction: CGFloat = 0.9

    public init() {}

    public var body: some View {
        ZStack {
            if let root = currentRoot {
                MobNodeView(node: root)
                    // .id changes only on navigation (push/pop/reset), so
                    // typing in a TextField doesn't tear the view down.
                    // Driven by currentNavVersion (not model.navVersion)
                    // so the change happens inside withAnimation — see
                    // .onChange(of: model.rootVersion) below.
                    .id(currentNavVersion)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(navTransition(currentTransition))
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 20) {
                        if let error = model.startupError {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 44))
                                .foregroundColor(Color.orange)
                            Text("Startup Error")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                            Text(error)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(Color(red: 0.9, green: 0.5, blue: 0.5))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 28)
                        } else {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .scaleEffect(1.3)
                            Text(model.startupPhase)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(.white.opacity(0.75))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
        }
        // Live root height, published so a content-detent sheet can cap itself
        // against real geometry rather than a guess. Read in a `.background`
        // so it costs no layout, and `initial: true` so the first value lands
        // without waiting for a resize. Re-fires on rotation, split view and
        // Stage Manager resizes, which is what re-clamps a presented sheet.
        //
        // The ceiling is a fraction of the root rather than the whole thing:
        // a content sheet that measures taller than the screen should still
        // leave the parent visible behind it, the way .large does, instead of
        // becoming an indistinguishable full-screen cover.
        .background {
            GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in
                    availableSheetHeight = max(1, height * Self.sheetHeightCeilingFraction)
                }
            }
        }
        .environment(\.mobAvailableSheetHeight, availableSheetHeight)
        .ignoresSafeArea(.container, edges: [.bottom, .horizontal])
        .onChange(of: model.rootVersion) {
            let t = model.transition
            let newRoot = model.root
            let newNavVersion = model.navVersion
            // Capture transition before the animation block so the modifier
            // sees the right value when the new view is inserted.
            currentTransition = t
            // Log every nav transition so log-tail-based checks can verify
            // the animation fired without resorting to video recording.
            // Format: [MobNav] transition=<push|pop|reset|none> navVersion=<n>
            if t != "none" {
                NSLog("[MobNav] transition=%@ navVersion=%d", t, newNavVersion)
            }
            if let animation = navAnimation(t) {
                withAnimation(animation) {
                    currentRoot = newRoot
                    // Apply navVersion inside withAnimation so the .id()
                    // change carries the animation context — without this
                    // SwiftUI replaces the view via default crossfade and
                    // the .move transition never plays.
                    currentNavVersion = newNavVersion
                }
            } else {
                currentRoot = newRoot
                currentNavVersion = newNavVersion
            }
        }
        // Notify Elixir when the OS appearance toggles so subscribers
        // (Mob.Device → Mob.Theme.Adaptive consumers) can re-resolve.
        // SwiftUI re-evaluates `colorScheme` automatically on system change,
        // so this fires reliably without polling.
        .onChange(of: colorScheme) { _, newScheme in
            mob_notify_color_scheme(newScheme == .dark ? "dark" : "light")
        }
    }

    private func navTransition(_ t: String) -> AnyTransition {
        switch t {
        case "push":
            return .asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .leading)
            )
        case "pop":
            return .asymmetric(
                insertion: .move(edge: .leading),
                removal: .move(edge: .trailing)
            )
        case "reset":
            return .opacity
        default:
            return .identity
        }
    }

    private func navAnimation(_ t: String) -> Animation? {
        switch t {
        case "push", "pop":
            return .spring(response: 0.3, dampingFraction: 0.85)
        case "reset":
            return .easeInOut(duration: 0.25)
        default:
            return nil
        }
    }
}

// MARK: - Batch 5: scroll position observation
//
// MobScrollObserver wires SwiftUI's scroll-geometry observer to MobNode's
// closures. Tier 1 (raw deltas) goes through node.onScroll which is throttled
// native-side. Tier 2 (semantic begin/end/top) is derived here. Tier 3 (parallax,
// fade-on-scroll, sticky) is rendered with no BEAM round-trip.

// MobScrollObserverGate applies the iOS 18+ observer when available and
// falls through to a no-op on older iOS. Once a UIKit-backed observer for
// iOS 17 lands, this is where the alternative would dispatch.
struct MobScrollObserverGate: ViewModifier {
    let node: MobNode
    let isHorizontal: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(MobScrollObserver(node: node, isHorizontal: isHorizontal))
        } else {
            content
        }
    }
}

/// A tab paired with a stable identity.
///
/// Tabs are dictionaries rather than MobNodes, so they cannot go through
/// mobIdentifiedChildren — but the ForEach over them subscripts childNodes, so
/// positional keying there discards a whole tab's content subtree when the tab
/// list changes. Same rules as the child helper, including the duplicate
/// fallback: two unkeyed tabs must not share a key.
struct MobIdentifiedTab: Identifiable {
    let id: String
    let index: Int
    let tab: [String: Any]
}

func mobIdentifiedTabs(_ tabs: [[String: Any]]) -> [MobIdentifiedTab] {
    var seen = Set<String>()
    seen.reserveCapacity(tabs.count)

    return tabs.enumerated().map { index, tab in
        var key: String
        if let authored = tab["id"] as? String, !authored.isEmpty {
            key = "i\u{1}" + authored
        } else {
            key = "p\u{1}\(index)"
        }
        if !seen.insert(key).inserted {
            key = "d\u{1}\(index)\u{1}" + key
        }
        return MobIdentifiedTab(id: key, index: index, tab: tab)
    }
}

/// A child paired with a stable identity for `ForEach`.
///
/// Positional identity (`id: \.offset`) means an insert or delete makes every
/// later row a different view as far as SwiftUI is concerned, so it is rebuilt
/// rather than patched. That is what MOB-127 is about.
///
/// Author `:id` when the node has one, position otherwise. The two are prefixed
/// differently so an author id of "3" cannot collide with position 3. A
/// repeated id falls back to including the position, because SwiftUI requires
/// ForEach ids to be unique and misbehaves quietly when they are not — which
/// would be a worse bug than the one being fixed.
struct MobIdentifiedChild: Identifiable {
    let id: String
    let index: Int
    let node: MobNode
}

func mobIdentifiedChildren(_ children: [MobNode]) -> [MobIdentifiedChild] {
    var seen = Set<String>()
    seen.reserveCapacity(children.count)

    return children.enumerated().map { index, child in
        var key: String
        if let authored = child.nativeViewId, !authored.isEmpty {
            key = "i\u{1}" + authored
        } else {
            key = "p\u{1}\(index)"
        }
        if !seen.insert(key).inserted {
            key = "d\u{1}\(index)\u{1}" + key
        }
        return MobIdentifiedChild(id: key, index: index, node: child)
    }
}

// MobScrollObserver wires SwiftUI's onScrollGeometryChange (iOS 18+) to the
// MobNode closures populated by mob_nif.m. Throttling and delta-thresholding
// happen native-side in mob_send_scroll, so this modifier just forwards every
// geometry change. End-of-scroll is detected by a debounced "no motion for N
// ms" timer.
@available(iOS 18.0, *)
struct MobScrollObserver: ViewModifier {
    let node: MobNode
    let isHorizontal: Bool

    @State private var lastX: CGFloat = 0
    @State private var lastY: CGFloat = 0
    @State private var lastTs: TimeInterval = 0
    @State private var hasBegun: Bool = false
    @State private var pastThreshold: Bool = false
    @State private var endTask: Task<Void, Never>?

    private static let endDebounceMs: Int = 150

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGPoint.self, of: { $0.contentOffset }) { _, offset in
                let now = ProcessInfo.processInfo.systemUptime
                let dt = lastTs > 0 ? now - lastTs : 0
                let x = offset.x
                let y = offset.y
                let dx = x - lastX
                let dy = y - lastY
                let vx = dt > 0 ? dx / CGFloat(dt) : 0
                let vy = dt > 0 ? dy / CGFloat(dt) : 0

                if !hasBegun {
                    hasBegun = true
                    node.onScrollBegan?()
                    node.onScroll?(0, 0, x, y, 0, 0, "began")
                } else {
                    node.onScroll?(dx, dy, x, y, vx, vy, "dragging")
                }

                // Tier 2 — top reached (fires on entering y == 0)
                if y <= 0.001 && lastY > 0.001 {
                    node.onTopReached?()
                }

                // Tier 2 — scrolled-past (latched, only fires on transition)
                let threshold = node.scrolledPastThreshold
                if threshold > 0 {
                    let nowPast = (isHorizontal ? x : y) > threshold
                    if nowPast && !pastThreshold {
                        node.onScrolledPast?()
                    }
                    pastThreshold = nowPast
                }

                lastX = x
                lastY = y
                lastTs = now

                // Debounced scroll-ended detector. Cancel any prior task and
                // schedule a fresh one — fires only after motion stops for
                // endDebounceMs.
                endTask?.cancel()
                let ms = Self.endDebounceMs
                endTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                    if Task.isCancelled { return }
                    if hasBegun {
                        node.onScrollEnded?()
                        node.onScrollSettled?()
                        node.onScroll?(0, 0, lastX, lastY, 0, 0, "ended")
                        hasBegun = false
                    }
                }
            }
    }
}

// A VStack that can be lazy without duplicating the call site. SwiftUI has no
// way to pick between VStack and LazyVStack at runtime inside one expression,
// and @ViewBuilder's `if` produces two different view identities — which is
// fine here because `lazy` is fixed for a given node's position in the tree.
struct MobEitherStack<Content: View>: View {
    let lazy: Bool
    let alignment: HorizontalAlignment
    @ViewBuilder let content: Content

    init(
        lazy: Bool,
        alignment: HorizontalAlignment,
        @ViewBuilder content: () -> Content
    ) {
        self.lazy = lazy
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        if lazy {
            LazyVStack(alignment: alignment, spacing: 0) { content }
        } else {
            VStack(alignment: alignment, spacing: 0) { content }
        }
    }
}
