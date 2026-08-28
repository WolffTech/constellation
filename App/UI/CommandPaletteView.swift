// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct CommandPaletteView: View {
    @Bindable var controller: CommandPaletteController
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let items = controller.items
        let connecting = controller.mode == .connect
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: connecting ? "bolt.horizontal" : "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.title3)
                TextField(connecting ? "user@host:port" : "Search machines, sessions, and commands", text: $controller.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { controller.confirm() }
            }
            .padding(.horizontal, 16)
            .frame(height: PaletteMetrics.fieldHeight)

            if let notice = controller.notice {
                Divider()
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(height: PaletteMetrics.noticeHeight)
            }
            if !items.isEmpty {
                Divider()
                resultList(items)
                    .frame(height: PaletteMetrics.listHeight(for: items, connecting: connecting))
            }
        }
        .frame(width: PaletteMetrics.width)
        .containerShape(PaletteMetrics.panelShape)
        .glassSurface(in: PaletteMetrics.panelShape)
        .onAppear { fieldFocused = true }
        .onChange(of: controller.isPresented) { _, presented in
            if presented { fieldFocused = true }
        }
        .onChange(of: controller.query) {
            controller.selectedIndex = 0
            controller.layout()
        }
        .onChange(of: items.count) { controller.layout() }
        .onChange(of: controller.notice) { controller.layout() }
    }

    private var connecting: Bool { controller.mode == .connect }

    private func resultList(_ items: [PaletteItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        // Connect mode's typed target needs no heading; it is the prompt's answer.
                        if index == 0 || items[index - 1].section != item.section,
                           !(connecting && item.section == .quickConnect) {
                            Text(item.section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .frame(height: PaletteMetrics.headerHeight, alignment: .bottomLeading)
                        }
                        PaletteRow(item: item, isSelected: index == controller.clampedSelection)
                            .id(item.id)
                            .onTapGesture {
                                controller.selectedIndex = index
                                controller.confirm()
                            }
                            .onHover { if $0, controller.followsHover { controller.selectedIndex = index } }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, PaletteMetrics.listPadding)
            }
            .onChange(of: controller.clampedSelection) { _, index in
                guard items.indices.contains(index) else { return }
                proxy.scrollTo(items[index].id, anchor: nil)
            }
        }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    /// The system's selection colors, so the row follows the accent and
    /// high-contrast settings like a list selection does. Not `.selection`:
    /// a borderless panel is never "emphasized", so that renders gray.
    private var selectedFill: Color { Color(nsColor: .selectedContentBackgroundColor) }
    private var selectedText: Color { Color(nsColor: .alternateSelectedControlTextColor) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbolName)
                .font(.title3)
                .frame(width: 24)
                .foregroundStyle(isSelected ? selectedText : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                Text(item.subtitle)
                    .font(.callout)
                    .foregroundStyle(isSelected ? selectedText.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let detail = item.detail {
                Text(detail)
                    .font(.callout.monospaced())
                    .foregroundStyle(isSelected ? selectedText.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PaletteMetrics.rowHeight)
        .contentShape(Rectangle())
        .background { if isSelected { highlight } }
        .foregroundStyle(isSelected ? selectedText : .primary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Concentric with the panel on macOS 26; a fixed radius before that.
    @ViewBuilder
    private var highlight: some View {
        if #available(macOS 26, *) {
            ConcentricRectangle(corners: .concentric(minimum: .fixed(6))).fill(selectedFill)
        } else {
            RoundedRectangle(cornerRadius: PaletteMetrics.rowCornerRadius, style: .continuous).fill(selectedFill)
        }
    }
}
