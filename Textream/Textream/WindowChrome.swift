//
//  WindowChrome.swift
//  Textream
//

import AppKit
import SwiftUI

/// Moves the window's close, minimise and zoom buttons in from the corner, the way Music sets
/// them: with air between them and the edge of the panel they sit on, rather than jammed into it.
///
/// AppKit lays the buttons out itself and does so again whenever the window is resized, keyed or
/// moved, so this reapplies its own positions after each of those. The offsets are measured from
/// the window's top left corner.
struct TrafficLightInset: NSViewRepresentable {
    var x: CGFloat
    var y: CGFloat

    func makeNSView(context: Context) -> TrafficLightInsetView {
        let view = TrafficLightInsetView()
        view.inset = CGPoint(x: x, y: y)
        return view
    }

    func updateNSView(_ view: TrafficLightInsetView, context: Context) {
        view.inset = CGPoint(x: x, y: y)
        view.apply()
    }
}

final class TrafficLightInsetView: NSView {
    var inset = CGPoint(x: 22, y: 20)
    private var observers: [NSObjectProtocol] = []

    /// The distance between the centres of neighbouring buttons, which AppKit keeps at twenty.
    static let pitch: CGFloat = 20

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        guard let window else { return }
        apply()

        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
            NSWindow.didMoveNotification,
            NSWindow.didExitFullScreenNotification
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.apply()
            }
        }
    }

    /// Positions the three buttons. Done twice, now and on the next turn of the run loop, because
    /// AppKit's own layout of them can land after the notification that prompted this one.
    func apply() {
        place()
        DispatchQueue.main.async { [weak self] in self?.place() }
    }

    private func place() {
        guard let window else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in types.enumerated() {
            guard let button = window.standardWindowButton(type),
                  let container = button.superview else { continue }
            // AppKit's y runs upward from the bottom of the title bar, so "this far from the top"
            // is measured down from the container's height.
            let origin = NSPoint(
                x: inset.x + CGFloat(index) * Self.pitch,
                y: container.bounds.height - inset.y - button.frame.height
            )
            if button.frame.origin != origin {
                button.setFrameOrigin(origin)
            }
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

/// Lets both columns of the split view run the full height of the window, under the toolbar.
///
/// AppKit grants that to the sidebar column on its own, which is why the traffic lights sit over
/// the sidebar panel, and withholds it from the detail column, so the content there is laid out
/// a toolbar's height down however the safe area is treated. Nothing in SwiftUI reaches that
/// setting, so this finds the split view controller and turns it on for every column. It also
/// drops the sidebar toggle the split view puts in the toolbar.
struct SplitViewChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> SplitViewChromeView { SplitViewChromeView() }
    func updateNSView(_ view: SplitViewChromeView, context: Context) { view.apply() }
}

final class SplitViewChromeView: NSView {
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        guard let window else { return }
        apply()
        // SwiftUI can rebuild the toolbar and the split view after the window first appears.
        observers = [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.apply()
            }
        }
    }

    func apply() {
        place()
        DispatchQueue.main.async { [weak self] in self?.place() }
    }

    private func place() {
        guard let window, let content = window.contentView else { return }
        for split in Self.splitViewControllers(under: content) {
            for item in split.splitViewItems where !item.allowsFullHeightLayout {
                item.allowsFullHeightLayout = true
            }
        }
        if let toolbar = window.toolbar {
            for (index, item) in toolbar.items.enumerated().reversed() where Self.isSidebarToggle(item) {
                toolbar.removeItem(at: index)
            }
        }
    }

    /// SwiftUI does not make its split view controller a child of the hosting controller, so the
    /// controller tree is empty. It is reachable as the delegate of the split view in the view tree.
    static func splitViewControllers(under root: NSView) -> [NSSplitViewController] {
        var found: [NSSplitViewController] = []
        var queue: [NSView] = [root]
        while let view = queue.popLast() {
            if let split = view as? NSSplitView,
               let controller = split.delegate as? NSSplitViewController {
                found.append(controller)
            }
            queue.append(contentsOf: view.subviews)
        }
        return found
    }

    static func isSidebarToggle(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == .toggleSidebar { return true }
        let raw = item.itemIdentifier.rawValue.lowercased()
        return raw.contains("togglesidebar") || raw.hasSuffix("sidebartoggle")
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
