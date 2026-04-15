// MobRootView.swift — SwiftUI entry point. Observes MobViewModel and renders the
// node tree pushed by BEAM NIFs via MobViewModel.setRoot().

import SwiftUI

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
}

// ── Recursive node renderer ────────────────────────────────────────────────

struct MobNodeView: View {
    let node: MobNode

    var body: some View {
        Group {
            switch node.nodeType {
            case .column:
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(node.childNodes) { MobNodeView(node: $0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(node.paddingEdgeInsets)
                .background(node.backgroundColor.map { Color($0) } ?? Color.clear)
                .ifLet(node.onTap) { view, tap in
                    view.contentShape(Rectangle()).onTapGesture { tap() }
                }

            case .row:
                HStack(spacing: 0) {
                    ForEach(node.childNodes) { MobNodeView(node: $0) }
                }
                .padding(node.paddingEdgeInsets)
                .background(node.backgroundColor.map { Color($0) } ?? Color.clear)
                .ifLet(node.onTap) { view, tap in
                    view.contentShape(Rectangle()).onTapGesture { tap() }
                }

            case .box:
                ZStack(alignment: .topLeading) {
                    ForEach(node.childNodes) { MobNodeView(node: $0) }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(node.paddingEdgeInsets)
                .background(node.backgroundColor.map { Color($0) } ?? Color.clear)
                .ifLet(node.onTap) { view, tap in
                    view.contentShape(Rectangle()).onTapGesture { tap() }
                }

            case .label:
                Text(node.text ?? "")
                    .font(node.textSize > 0 ? .system(size: node.textSize) : .body)
                    .foregroundColor(node.textColor.map { Color($0) } ?? Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(node.paddingEdgeInsets)
                    .background(node.backgroundColor.map { Color($0) } ?? Color.clear)

            case .button:
                Button(action: { node.onTap?() }) {
                    Text(node.text ?? "")
                        .font(node.textSize > 0 ? .system(size: node.textSize) : .body)
                        .foregroundColor(node.textColor.map { Color($0) } ?? Color.accentColor)
                        .frame(maxWidth: .infinity)
                }
                .padding(node.paddingEdgeInsets)
                .background(node.backgroundColor.map { Color($0) } ?? Color.clear)

            case .scroll:
                let isHorizontal = node.axis == "horizontal"
                let axes: Axis.Set = isHorizontal ? .horizontal : .vertical
                ScrollView(axes, showsIndicators: node.showIndicator) {
                    if isHorizontal {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(node.childNodes) { MobNodeView(node: $0) }
                        }
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(node.childNodes) { MobNodeView(node: $0) }
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
                        ForEach(node.childNodes) { child in
                            MobNodeView(node: child)
                                .onAppear {
                                    if child === node.childNodes.last {
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

            @unknown default:
                EmptyView()
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
            if let src = node.src, let url = URL(string: src) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: contentMode)
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(
            width:  node.fixedWidth  > 0 ? node.fixedWidth  : nil,
            height: node.fixedHeight > 0 ? node.fixedHeight : nil
        )
        .background(placeholder)
        .clipShape(RoundedRectangle(cornerRadius: node.cornerRadius))
    }
}

// ── Root view — observed by the hosting controller ─────────────────────────

public struct MobRootView: View {
    @ObservedObject var model = MobViewModel.shared
    @State private var currentRoot: MobNode? = nil

    public init() {}

    public var body: some View {
        ZStack {
            if let root = currentRoot {
                MobNodeView(node: root)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(navTransition(model.transition))
            } else {
                VStack {
                    Spacer()
                    Text("Starting Mob…")
                        .font(.system(size: 24, weight: .bold))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            }
        }
        .ignoresSafeArea(.container, edges: [.bottom, .horizontal])
        .onChange(of: model.rootVersion) { _ in
            let t = model.transition
            if let animation = navAnimation(t) {
                withAnimation(animation) {
                    currentRoot = model.root
                }
            } else {
                currentRoot = model.root
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
