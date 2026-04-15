// MobViewModel.swift — Shared state store between BEAM NIFs and SwiftUI.
// NIFs call setRoot() from any thread; the @Published triggers SwiftUI re-render on main.

import SwiftUI
import Combine

@objc public class MobViewModel: NSObject, ObservableObject {
    @objc public static let shared = MobViewModel()

    @Published public var root: MobNode? = nil
    /// Increments on every setRoot call; views use onChange(of: rootVersion) to
    /// trigger withAnimation rather than watching root directly (root identity
    /// may change even for same-screen re-renders).
    @Published public var rootVersion: Int = 0
    /// Transition type for the *next* root change. Read by MobRootView before
    /// calling withAnimation; not @Published to avoid spurious recompositions.
    public var transition: String = "none"

    @objc public func setRoot(_ node: MobNode?, transition: String) {
        DispatchQueue.main.async {
            self.transition = transition
            self.root = node
            self.rootVersion += 1
        }
    }
}

// Factory: lets ObjC (AppDelegate.m) create the SwiftUI hosting controller
// without knowing about the generic UIHostingController<MobRootView> type.
@objc public class MobUIFactory: NSObject {
    @objc public static func makeRootViewController() -> UIViewController {
        return UIHostingController(rootView: MobRootView())
    }
}
