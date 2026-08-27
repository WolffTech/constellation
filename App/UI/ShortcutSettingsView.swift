// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

struct ShortcutSettingsView: View {
    let shortcuts: ShortcutSettingsStore

    private var menus: [String] {
        var seen: [String] = []
        for action in ShortcutAction.allCases where !seen.contains(action.menu) { seen.append(action.menu) }
        return seen
    }

    var body: some View {
        Form {
            ForEach(menus, id: \.self) { menu in
                Section(menu) {
                    ForEach(ShortcutAction.allCases.filter { $0.menu == menu }) { action in
                        ShortcutRow(action: action, shortcuts: shortcuts)
                    }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { shortcuts.resetAll() }
                }
            } footer: {
                Text("Select Tab 1–9 stay on ⌘1–⌘9. While a terminal has focus, ⌘C, ⌘V, ⌘A and the font-size keys go to the terminal first.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    let shortcuts: ShortcutSettingsStore
    @State private var problem: String?

    var body: some View {
        // Not LabeledContent: it would give both buttons the row's title as
        // their accessibility name.
        HStack(spacing: 6) {
            Text(action.title)
            Spacer()
            ShortcutRecorder(shortcut: shortcuts.shortcut(for: action)) { recorded in
                switch recorded {
                case .assigned(let shortcut):
                    if let issue = shortcut.problem {
                        problem = issue
                    } else {
                        problem = nil
                        shortcuts.assign(shortcut, to: action)
                    }
                case .cleared:
                    problem = nil
                    shortcuts.assign(nil, to: action)
                case .cancelled:
                    break
                }
            }
            .accessibilityLabel(action.title)
            Button {
                problem = nil
                shortcuts.resetToDefault(action)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Restore the default shortcut")
            .accessibilityLabel("Restore default for \(action.title)")
            .disabled(shortcuts.isDefault(action))
        }
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.callout)
        }
        let conflicts = shortcuts.conflicts(with: action)
        if !conflicts.isEmpty {
            Label("Also assigned to \(conflicts.map(\.title).formatted(.list(type: .and)))", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.callout)
        }
    }
}

enum ShortcutRecording {
    case assigned(Shortcut)
    case cleared
    case cancelled
}

/// A button that captures the next key press while active. Escape cancels;
/// Delete on its own clears the shortcut.
struct ShortcutRecorder: View {
    let shortcut: Shortcut?
    let onRecord: (ShortcutRecording) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording { stop(.cancelled) } else { start() }
        } label: {
            Text(isRecording ? "Type shortcut…" : (shortcut?.displayString ?? "None"))
                .foregroundStyle(isRecording || shortcut == nil ? .secondary : .primary)
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .accessibilityValue(shortcut?.displayString ?? "None")
        .accessibilityHint(isRecording ? "Type the new shortcut" : "Record a new shortcut")
        .onDisappear { removeMonitor() }
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                handle(event)
            }
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case 0x35 where flags.isEmpty:
            stop(.cancelled)
        case 0x33 where flags.isEmpty, 0x75 where flags.isEmpty:
            stop(.cleared)
        default:
            guard let recorded = Shortcut(event: event) else { return }
            stop(.assigned(recorded))
        }
    }

    private func stop(_ result: ShortcutRecording) {
        removeMonitor()
        isRecording = false
        onRecord(result)
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
