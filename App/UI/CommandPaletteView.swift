// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct CommandPaletteView: View {
    @Bindable var controller: CommandPaletteController
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let items = controller.items
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.title3)
                TextField("Search machines, sessions, and commands", text: $controller.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { controller.confirm() }
            }
            .padding(.horizontal, 16)
            .frame(height: PaletteMetrics.fieldHeight)

            if !items.isEmpty {
                Divider()
                resultList(items)
                    .frame(height: PaletteMetrics.listHeight(for: items))
            }
        }
        .frame(width: PaletteMetrics.width)
        .glassSurface(in: RoundedRectangle(cornerRadius: PaletteMetrics.cornerRadius, style: .continuous))
        .onAppear { fieldFocused = true }
        .onChange(of: controller.isPresented) { _, presented in
            if presented { fieldFocused = true }
        }
        .onChange(of: controller.query) {
            controller.selectedIndex = 0
            controller.layout()
        }
        .onChange(of: items.count) { controller.layout() }
    }

    private func resultList(_ items: [PaletteItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || items[index - 1].section != item.section {
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbolName)
                .font(.title3)
                .frame(width: 24)
                .foregroundStyle(isSelected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                Text(item.subtitle)
                    .font(.callout)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let detail = item.detail {
                Text(detail)
                    .font(.callout.monospaced())
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PaletteMetrics.rowHeight)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: PaletteMetrics.rowCornerRadius, style: .continuous)
                .fill(isSelected ? Color.accentColor : .clear))
        .foregroundStyle(isSelected ? .white : .primary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
