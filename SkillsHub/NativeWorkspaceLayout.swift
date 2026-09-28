import AppKit
import SwiftUI

/// Store for sidebar and list width preferences; UI fixtures swap in an isolated suite before any view appears.
enum WorkspaceLayoutPreferences {
    @MainActor static var defaults: UserDefaults = .standard
}

/// Native noncollapsing list/detail split. Only divider drags change the saved preference.
struct NativeWorkspaceSplit<Left: View, Right: View>: NSViewControllerRepresentable {
    var preferenceKey: String
    var stateKey: String = ""
    var language: AppLanguage
    @ViewBuilder var left: () -> Left
    @ViewBuilder var right: () -> Right

    func makeNSViewController(context: Context) -> WorkspaceSplitController {
        WorkspaceSplitController(key: preferenceKey)
    }

    func updateNSViewController(_ controller: WorkspaceSplitController, context: Context) {
        controller.changePage(to: stateKey)
        controller.leading.rootView = AnyView(left().environment(\.appLanguage, language))
        controller.trailing.rootView = AnyView(right().environment(\.appLanguage, language))
        controller.requestScrollRestoration()
    }

    static func dismantleNSViewController(_ controller: WorkspaceSplitController, coordinator: ()) {
        controller.saveScrollPosition()
    }
}

final class WorkspaceSplitController: NSViewController, NSSplitViewDelegate {
    let leading = NSHostingController(rootView: AnyView(EmptyView()))
    let trailing = NSHostingController(rootView: AnyView(EmptyView()))
    private let split = NSSplitView()
    private let key: String
    private var preferred: CGFloat
    private static var scrollPositions: [String: CGPoint] = [:]
    private var pageKey = ""
    private var needsScrollRestoration = true
    private var scrollRestorationRetries = 0
    private var scrollRestorationScheduled = false
    private weak var observedClipView: NSClipView?
    private var observedDocumentHeight: CGFloat = 0

    func requestScrollRestoration() {
        guard needsScrollRestoration else { return }
        DispatchQueue.main.async { [weak self] in self?.restoreScrollPosition() }
    }

    private func scheduleScrollRestoration() {
        guard scrollRestorationRetries < 20, !scrollRestorationScheduled else { return }
        scrollRestorationRetries += 1
        scrollRestorationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self else { return }
            self.scrollRestorationScheduled = false
            self.restoreScrollPosition()
        }
    }

    func changePage(to key: String) {
        guard key != pageKey else { return }
        saveScrollPosition()
        pageKey = key
        needsScrollRestoration = true
        scrollRestorationRetries = 0
        observedDocumentHeight = 0
    }

    private var listScrollView: NSScrollView? {
        func find(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return find(in: leading.view)
    }

    func saveScrollPosition() {
        guard !pageKey.isEmpty, let scroll = listScrollView else { return }
        let documentHeight = scroll.documentView?.bounds.height ?? 0
        guard documentHeight > 0 else { return }
        let current = scroll.contentView.bounds.origin
        if needsScrollRestoration, current.y <= (Self.scrollPositions[pageKey]?.y ?? 0) { return }
        if documentHeight >= observedDocumentHeight { Self.scrollPositions[pageKey] = current }
    }

    private func observeScroll(_ scroll: NSScrollView) {
        let clip = scroll.contentView
        guard observedClipView !== clip else { return }
        if let observedClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClipView)
        }
        observedClipView = clip
        observedDocumentHeight = 0
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollBoundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func scrollBoundsChanged(_ notification: Notification) {
        guard let clip = notification.object as? NSClipView,
              clip === observedClipView, let scroll = clip.enclosingScrollView else { return }
        if needsScrollRestoration, clip.bounds.origin.y <= (Self.scrollPositions[pageKey]?.y ?? 0) { return }
        let height = scroll.documentView?.bounds.height ?? 0
        if height > 0, height >= observedDocumentHeight {
            observedDocumentHeight = height
            Self.scrollPositions[pageKey] = clip.bounds.origin
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewWillDisappear() {
        saveScrollPosition()
        needsScrollRestoration = true
        super.viewWillDisappear()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let scroll = listScrollView { observeScroll(scroll) }
        restoreScrollPosition()
    }

    private func restoreScrollPosition() {
        guard needsScrollRestoration, !scrollRestorationScheduled else { return }
        if let scroll = listScrollView { observeScroll(scroll) }
        guard let scroll = listScrollView, let document = scroll.documentView,
              document.bounds.height > 0 else {
            scheduleScrollRestoration()
            return
        }
        document.layoutSubtreeIfNeeded()
        let saved = Self.scrollPositions[pageKey] ?? .zero
        let maximumY = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: min(saved.y, maximumY)))
        scroll.reflectScrolledClipView(scroll.contentView)
        if saved.y > maximumY, scrollRestorationRetries < 20 {
            // ponytail: retry lazy List layout for up to two seconds; use row anchors if larger lists outgrow this.
            scheduleScrollRestoration()
        } else {
            needsScrollRestoration = false
            observedDocumentHeight = document.bounds.height
        }
    }

    init(key: String) {
        self.key = key
        let saved = WorkspaceLayoutPreferences.defaults.double(forKey: key)
        preferred = saved > 0 ? min(520, max(288, saved)) : 344
        super.init(nibName: nil, bundle: nil)
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        view = split
        addChild(leading)
        addChild(trailing)
        split.addArrangedSubview(leading.view)
        split.addArrangedSubview(trailing.view)
        leading.view.setAccessibilityIdentifier("workspace-list-pane")
        trailing.view.setAccessibilityIdentifier("workspace-detail-pane")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 288 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(520, splitView.bounds.width - splitView.dividerThickness - 360)
    }
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        let width = min(preferred, max(288, min(520, splitView.bounds.width - splitView.dividerThickness - 360)))
        leading.view.frame = NSRect(x: 0, y: 0, width: width, height: splitView.bounds.height)
        trailing.view.frame = NSRect(x: width + splitView.dividerThickness, y: 0,
                                     width: max(0, splitView.bounds.width - width - splitView.dividerThickness), height: splitView.bounds.height)
    }
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        preferred = min(520, max(288, min(proposedPosition, splitView.bounds.width - splitView.dividerThickness - 360)))
        WorkspaceLayoutPreferences.defaults.set(preferred, forKey: key)
        return preferred
    }
}

/// Configure the system NavigationSplitView without replacing its delegate or sidebar material.
struct FixedSidebarConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SidebarConfigurationView() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? SidebarConfigurationView)?.configure() }
}
private final class SidebarConfigurationView: NSView {
    private weak var configuredSplit: NSSplitView?
    private let widthKey = "SkillsHub.sidebar.preferredWidth"
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
    func configure() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.contentMinSize = NSSize(width: 1040, height: 560)
            self.window?.autorecalculatesKeyViewLoop = true
            var parent = self.superview
            while let current = parent {
                if let split = current as? NSSplitView,
                   let controller = split.delegate as? NSSplitViewController,
                   let item = controller.splitViewItems.first {
                    item.canCollapse = false
                    item.minimumThickness = 176
                    item.maximumThickness = 260
                    if self.configuredSplit !== split {
                        NotificationCenter.default.removeObserver(self, name: NSSplitView.didResizeSubviewsNotification, object: self.configuredSplit)
                        self.configuredSplit = split
                        let saved = WorkspaceLayoutPreferences.defaults.double(forKey: self.widthKey)
                        split.setPosition(saved > 0 ? min(260, max(176, saved)) : 196, ofDividerAt: 0)
                        NotificationCenter.default.addObserver(self, selector: #selector(self.rememberWidth), name: NSSplitView.didResizeSubviewsNotification, object: split)
                    }
                    break
                }
                parent = current.superview
            }
        }
    }
    @objc private func rememberWidth() {
        guard NSEvent.pressedMouseButtons != 0, let width = configuredSplit?.arrangedSubviews.first?.frame.width else { return }
        WorkspaceLayoutPreferences.defaults.set(min(260, max(176, width)), forKey: widthKey)
    }
}

struct NativeWorkspaceSearch: NSViewRepresentable {
    @Binding var text: String
    var prompt: String
    var identifier: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSView {
        let search = WorkspaceSearchField()
        search.delegate = context.coordinator
        search.controlSize = .regular
        search.sendsSearchStringImmediately = true
        search.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(search)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            search.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        context.coordinator.search = search
        return container
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        guard let search = context.coordinator.search else { return }
        if search.stringValue != text { search.stringValue = text }
        search.placeholderString = search.isFocused ? "" : prompt
        search.setAccessibilityLabel(prompt)
        search.setAccessibilityIdentifier(identifier)
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeWorkspaceSearch
        weak var search: WorkspaceSearchField?
        init(_ parent: NativeWorkspaceSearch) { self.parent = parent }
        func controlTextDidBeginEditing(_ obj: Notification) {
            search?.isFocused = true
            search?.placeholderString = ""
        }
        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSSearchField { parent.text = field.stringValue }
        }
        func controlTextDidEndEditing(_ obj: Notification) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let search = self.search else { return }
                let focused = search.currentEditor() != nil || search.window?.firstResponder === search
                search.isFocused = focused
                search.placeholderString = focused ? "" : self.parent.prompt
            }
        }
    }
}

final class WorkspaceSearchField: NSSearchField {
    var isFocused = false

    override func mouseDown(with event: NSEvent) {
        isFocused = true
        placeholderString = ""
        super.mouseDown(with: event)
        placeholderString = ""
    }

    override func becomeFirstResponder() -> Bool {
        isFocused = true
        placeholderString = ""
        let accepted = super.becomeFirstResponder()
        placeholderString = ""
        return accepted
    }
}
