// MobRootView.swift — SwiftUI entry point. Observes MobViewModel and renders the
// node tree pushed by BEAM NIFs via MobViewModel.setRoot().

import SwiftUI
import AVKit

extension View {
    @ViewBuilder
    func ifLet<T>(_ value: T?, transform: (Self, T) -> some View) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}

// Allow MobNode to be used as ForEach identity (NSObject provides hash/isEqual).
extension MobNode: Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
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

            case .row:
                HStack(spacing: 0) {
                    ForEach(Array(node.childNodes.enumerated()), id: \.offset) { _, child in MobNodeView(node: child) }
                }
                .padding(node.paddingEdgeInsets)
                .background(node.backgroundColor.map { Color($0) } ?? Color.clear)
                .ifLet(node.onTap) { view, tap in
                    view.contentShape(Rectangle()).onTapGesture { tap() }
                }

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
            .onChange(of: text) { newValue in
                node.onChangeStr?(newValue)
            }
            .onChange(of: isFocused) { focused in
                if focused { node.onFocus?() }
                else       { node.onBlur?() }
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
            .toolbar {
                // Always-visible dismiss button — lets users close the keyboard
                // without triggering on_submit (down-arrow pattern from RN).
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isFocused = false }
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
            .onChange(of: isOn) { newValue in
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
            .onChange(of: value) { newValue in
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
    @State private var currentRoot: MobNode? = nil
    @State private var currentTransition: String = "none"

    public init() {}

    public var body: some View {
        ZStack {
            if let root = currentRoot {
                MobNodeView(node: root)
                    // Only assign a new identity on navigation transitions (push/pop),
                    // not on every state-update re-render. Using rootVersion here would
                    // tear down and recreate the whole view tree on every keystroke,
                    // causing MobTextField to lose focus and dismiss the keyboard.
                    .id(model.navVersion)
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
        .onChange(of: model.rootVersion) { _ in
            let t = model.transition
            let newRoot = model.root
            // Capture transition before the animation block so the modifier sees
            // the right value when the new view is inserted.
            currentTransition = t
            if let animation = navAnimation(t) {
                withAnimation(animation) {
                    currentRoot = newRoot
                }
            } else {
                currentRoot = newRoot
            }
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
