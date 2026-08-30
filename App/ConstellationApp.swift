// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ConstellationRemoteDesktop
import SwiftUI

@main
struct ConstellationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var root = CompositionRoot()

    var body: some Scene {
        WindowGroup {
            ContentView(root: root)
                .environment(root)
                .environment(root.shortcuts)
                .onAppear { appDelegate.root = root }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { root.updates.checkForUpdates() }
                    .disabled(!root.updates.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                CommandButton(.newMachine, root: root)
                CommandButton(.editMachine, root: root)
            }
            // Replaces File › Close: AppKit dispatches ⌘W to the first enabled
            // menu item, so the window's own Close would otherwise win.
            CommandGroup(replacing: .saveItem) {
                CommandButton(.closeSession, root: root)
                CommandButton(.closeOtherSessions, root: root)
                CommandButton(.closeWindow, root: root)
            }
            CommandGroup(after: .toolbar) {
                CommandButton(.commandPalette, root: root)
                Divider()
                CommandButton(.fitToWindow, root: root)
                CommandButton(.actualSize, root: root)
                Divider()
            }
            CommandGroup(after: .importExport) {
                CommandButton(.importMachines, root: root)
                CommandButton(.exportMachines, root: root)
            }
            CommandMenu("Session") {
                CommandButton(.newLocalTerminal, root: root)
                CommandButton(.quickConnect, root: root)
                CommandButton(.connectDefaultProfile, root: root)
                Divider()
                CommandButton(.reconnect, root: root)
                CommandButton(.disconnect, root: root)
                Divider()
                ForEach(1...9, id: \.self) { number in
                    Button("Select Tab \(number)") { root.sessions?.select(number: number) }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                        .disabled(root.sessions?.sessions.indices.contains(number - 1) != true)
                }
                CommandButton(.nextTab, root: root)
                CommandButton(.previousTab, root: root)
                Divider()
                CommandButton(.findInSession, root: root)
            }
            CommandGroup(after: .help) {
                AcknowledgementsCommand()
                CommandButton(.saveSupportBundle, root: root)
            }
        }

        Window("Acknowledgements", id: "acknowledgements") {
            AcknowledgementsView()
        }
        .defaultSize(width: 760, height: 520)

        Settings {
            SettingsView(root: root)
        }
    }
}

/// A menu item for a `ShortcutAction`: title, shortcut and enabled state
/// all come from the root, so the command palette sees the same command.
private struct CommandButton: View {
    let action: ShortcutAction
    let root: CompositionRoot

    init(_ action: ShortcutAction, root: CompositionRoot) {
        self.action = action
        self.root = root
    }

    var body: some View {
        Button(action.menuTitle) { root.perform(action) }
            .keyboardShortcut(root.shortcuts.keyboardShortcut(for: action))
            .disabled(!root.isEnabled(action))
    }
}

/// Menu content gets the environment, so this is where `openWindow` lives.
private struct AcknowledgementsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Acknowledgements") { openWindow(id: "acknowledgements") }
    }
}

/// Routes every quit path (menu, Dock, logout) through the session confirmation.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var root: CompositionRoot?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        root?.prepareForTermination() ?? .terminateNow
    }
}
