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
                .padding(node.padding)
                .background(node.backgroundColor.map { Color($0) } ?? Color.clear)
                .ifLet(node.onTap) { view, tap in
                    view.contentShape(Rectangle()).onTapGesture { tap() }
                }

            case .row:
                HStack(spacing: 0) {
                    ForEach(node.childNodes) { MobNodeView(node: $0) }
                }
                .padding(node.padding)
                .background(node.backgroundColor.map { Color($0) } ?? Color.clear)
                .ifLet(node.onTap) { view, tap in
                    view.contentShape(Rectangle()).onTapGesture { tap() }
                }

            case .label:
                Text(node.text ?? "")
                    .font(node.textSize > 0 ? .system(size: node.textSize) : .body)
                    .foregroundColor(node.textColor.map { Color($0) } ?? Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(node.padding)
                    .background(node.backgroundColor.map { Color($0) } ?? Color.clear)

            case .button:
                Button(action: { node.onTap?() }) {
                    Text(node.text ?? "")
                        .font(node.textSize > 0 ? .system(size: node.textSize) : .body)
                        .foregroundColor(node.textColor.map { Color($0) } ?? Color.accentColor)
                        .frame(maxWidth: .infinity)
                }
                .padding(node.padding)
                .background(node.backgroundColor.map { Color($0) } ?? Color.clear)

            case .scroll:
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(node.childNodes) { MobNodeView(node: $0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(node.padding)
                .background(node.backgroundColor.map { Color($0) } ?? Color.clear)

            @unknown default:
                EmptyView()
            }
        }
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
        .ignoresSafeArea(edges: .bottom)
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
