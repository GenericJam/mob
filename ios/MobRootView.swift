// MobRootView.swift — SwiftUI entry point. Observes MobViewModel and renders the
// node tree pushed by BEAM NIFs via MobViewModel.setRoot().

import SwiftUI

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
                .contentShape(Rectangle())
                .onTapGesture { node.onTap?() }

            case .row:
                HStack(spacing: 0) {
                    ForEach(node.childNodes) { MobNodeView(node: $0) }
                }
                .padding(node.padding)
                .background(node.backgroundColor.map { Color($0) } ?? Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { node.onTap?() }

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

    public init() {}

    public var body: some View {
        Group {
            if let root = model.root {
                MobNodeView(node: root)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack {
                    Spacer()
                    Text("Starting Mob…")
                        .font(.system(size: 24, weight: .bold))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }
}
