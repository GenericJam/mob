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
        let send: MobNativeSend = { event, payload in
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                mob_send_component_event(handle, event, json)
            }
        }
        return factory(props, send)
    }
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
        if let family = fontFamily, !family.isEmpty {
            font = Font.custom(family, size: size)
        } else {
            font = .system(size: size)
        }
        font = font.weight(weight)
        if italic { font = font.italic() }
        return font
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

    var body: some View {
        Group {
            switch node.nodeType {
            case .column:
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(node.childNodes.enumerated()), id: \.offset) { _, child in MobNodeView(node: child) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(node.paddingEdgeInsets)
                .background(node.backgroundColor.map { Color($0) } ?? Color.clear)
                .ifLet(node.onTap) { view, tap in
                    view.contentShape(Rectangle()).onTapGesture { tap() }
                }
                .mobGestures(node)

            case .row:
                HStack(spacing: 0) {
                    ForEach(Array(node.childNodes.enumerated()), id: \.offset) { _, child in MobNodeView(node: child) }
                }
                .padding(node.paddingEdgeInsets)
                .background(node.backgroundColor.map { Color($0) } ?? Color.clear)
                .ifLet(node.onTap) { view, tap in
                    view.contentShape(Rectangle()).onTapGesture { tap() }
                }
                .mobGestures(node)

            case .box:
                ZStack(alignment: .topLeading) {
                    ForEach(Array(node.childNodes.enumerated()), id: \.offset) { _, child in MobNodeView(node: child) }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(node.paddingEdgeInsets)
                .background(node.backgroundColor.map { Color($0) } ?? Color.clear)
                .ifLet(node.onTap) { view, tap in
                    view.contentShape(Rectangle()).onTapGesture { tap() }
                }
                .mobGestures(node)

            case .label:
                Text(node.text ?? "")
                    .font(node.resolvedFont)
                    .foregroundColor(node.textColor.map { Color($0) } ?? Color.primary)
                    .multilineTextAlignment(node.textAlignEnum)
                    .lineSpacing(node.computedLineSpacing)
                    .kerning(node.letterSpacing)
                    .frame(maxWidth: .infinity, alignment: node.frameTextAlignment)
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
                Button(action: { node.onTap?() }) {
                    Text(node.text ?? "")
                        .font(node.resolvedFont)
                        .foregroundColor(node.textColor.map { Color($0) } ?? Color.clear)
                        .lineLimit(1)
                        .frame(maxWidth: node.fillWidth ? .infinity : nil)
                }
                .padding(node.paddingEdgeInsets)
                .background(node.backgroundColor.map { Color($0) } ?? Color.clear)
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
                            ForEach(Array(node.childNodes.enumerated()), id: \.offset) { _, child in MobNodeView(node: child) }
                        }
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(node.childNodes.enumerated()), id: \.offset) { _, child in MobNodeView(node: child) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .padding(node.paddingEdgeInsets)
                .background(node.backgroundColor.map { Color($0) } ?? Color.clear)
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
                    Spacer().frame(minHeight: node.fixedSize, maxHeight: node.fixedSize)
                } else {
                    Spacer()
                }

            case .image:
                MobImage(node: node)
                    .padding(node.paddingEdgeInsets)

            case .lazyList:
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(node.childNodes.enumerated()), id: \.offset) { index, child in
                            MobNodeView(node: child)
                                .onAppear {
                                    if index == node.childNodes.count - 1 {
                                        node.onTap?()
                                    }
                                }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                .padding(node.paddingEdgeInsets)
                .background(node.backgroundColor.map { Color($0) } ?? Color.clear)

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
                        .ifLet(node.fixedWidth  > 0 ? node.fixedWidth  : nil) { v, w in v.frame(width:  CGFloat(w)) }
                        .ifLet(node.fixedHeight > 0 ? node.fixedHeight : nil) { v, h in v.frame(height: CGFloat(h)) }
                        .padding(node.paddingEdgeInsets)
                }

            case .cameraPreview:
                MobCameraPreviewView(facing: node.cameraFacing)
                    .ifLet(node.fixedWidth  > 0 ? node.fixedWidth  : nil) { v, w in v.frame(width:  CGFloat(w)) }
                    .ifLet(node.fixedHeight > 0 ? node.fixedHeight : nil) { v, h in v.frame(height: CGFloat(h)) }
                    .padding(node.paddingEdgeInsets)

            case .webView:
                MobWebView(node: node)
                    .ifLet(node.fixedWidth  > 0 ? node.fixedWidth  : nil) { v, w in v.frame(width:  CGFloat(w)) }
                    .ifLet(node.fixedHeight > 0 ? node.fixedHeight : nil) { v, h in v.frame(height: CGFloat(h)) }
                    .padding(node.paddingEdgeInsets)

            case .nativeView:
                if let view = MobNativeViewRegistry.shared.view(for: node) {
                    view.padding(node.paddingEdgeInsets)
                }

            @unknown default:
                EmptyView()
            }
        }
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
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                if index < node.childNodes.count {
                    let child = node.childNodes[index]
                    MobNodeView(node: child)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(child.backgroundColor.map { Color($0) } ?? Color.clear)
                        .tabItem {
                            Label(
                                tab["label"] as? String ?? "",
                                systemImage: tab["icon"] as? String ?? "circle"
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
        // Observe future session changes (start, stop, facing swap).
        context.coordinator.startObserving(view: view)
        return view
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
                self?.hostView?.cameraLayer.session = g_preview_session
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

    var body: some View {
        TextField(placeholder, text: $text)
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
                if focused { node.onFocus?() }
                else       { node.onBlur?() }
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
        Slider(value: $value, in: node.minValue...node.maxValue)
            .onChange(of: value) { _, newValue in
                node.onChangeFloat?(newValue)
            }
            .tint(node.color.map { Color($0) } ?? Color.accentColor)
            .frame(maxWidth: .infinity)
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
                if (src.hasPrefix("http://") || src.hasPrefix("https://")),
                   let url = URL(string: src) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: contentMode)
                        default:
                            placeholder
                        }
                    }
                } else if let uiImage = UIImage(contentsOfFile: src) {
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
            width:  node.fixedWidth  > 0 ? node.fixedWidth  : nil,
            height: node.fixedHeight > 0 ? node.fixedHeight : nil
        )
        .clipShape(RoundedRectangle(cornerRadius: node.cornerRadius))
    }
}

// ── Root view — observed by the hosting controller ─────────────────────────

public struct MobRootView: View {
    @ObservedObject var model = MobViewModel.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var currentRoot: MobNode? = nil
    @State private var currentTransition: String = "none"
    // Local mirror of model.navVersion so the .id() change happens INSIDE
    // the withAnimation block (the model's @Published value changes via
    // SwiftUI observation, which doesn't carry the animation context and
    // produces a default crossfade instead of the .move transition).
    @State private var currentNavVersion: Int = 0

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
                insertion:  .move(edge: .trailing),
                removal:    .move(edge: .leading)
            )
        case "pop":
            return .asymmetric(
                insertion:  .move(edge: .leading),
                removal:    .move(edge: .trailing)
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
    @State private var endTask: Task<Void, Never>? = nil

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
