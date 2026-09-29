//
//  SkillsHubApp.swift
//  SkillsHub
//
//  Created by 叶茂盛 on 2026/6/19.
//

import AppKit
import SwiftUI

@main
struct SkillsHubApp: App {
    @NSApplicationDelegateAdaptor(SkillsHubAppDelegate.self) private var appDelegate
    @State private var library: SkillsHubLibraryController

    init() {
        _library = State(initialValue: ContentView.makeLibrary())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(library: library)
                .onAppear { appDelegate.library = library }
        }
        .defaultSize(width: 1200, height: 812)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .textEditing) {
                Button(SkillsHubLocalization().localized("Search", language: library.language)) { appDelegate.focusSearch() }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}

final class SkillsHubAppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the window appears so termination can stop filesystem observation.
    @MainActor weak var library: SkillsHubLibraryController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconImage = bundledIconImage() ?? workspaceIconImage() {
            NSApp.applicationIconImage = iconImage
        }
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--skillshub-ui-fixture"),
           let appearanceIndex = arguments.firstIndex(of: "--skillshub-ui-fixture-appearance"),
           arguments.indices.contains(appearanceIndex + 1) {
            NSApp.appearance = NSAppearance(named: arguments[appearanceIndex + 1] == "Dark" ? .darkAqua : .aqua)
        }
        if arguments.contains("--skillshub-ui-fixture") || arguments.contains("--skillshub-ui-empty-fixture"),
           let flagIndex = arguments.firstIndex(of: "--skillshub-ui-fixture-window-width"),
           arguments.indices.contains(flagIndex + 1),
           let width = Double(arguments[flagIndex + 1]) {
            DispatchQueue.main.async {
                guard let window = NSApp.windows.first else { return }
                var frame = window.frame
                frame.size.width = width
                window.setFrame(frame, display: true)
            }
        }
#endif
    }

    func focusSearch() {
        guard let window = NSApp.keyWindow else { return }
        func searchField(in view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField, field.window === window, !field.isHiddenOrHasHiddenAncestor { return field }
            return view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        let views = (window.toolbar?.items.compactMap(\.view) ?? []) + [window.contentView].compactMap { $0 }
        if let field = views.lazy.compactMap({ searchField(in: $0) }).first {
            (field as? WorkspaceSearchField)?.isFocused = true
            field.placeholderString = ""
            window.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            library?.cancelPendingRechecks()
            library?.observation.stop()
        }
    }

    private func bundledIconImage() -> NSImage? {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let iconImage = NSImage(contentsOf: iconURL),
              iconImage.size != .zero else {
            return nil
        }
        return iconImage
    }

    private func workspaceIconImage() -> NSImage? {
        let iconImage = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        return iconImage.size == .zero ? nil : iconImage
    }
}
