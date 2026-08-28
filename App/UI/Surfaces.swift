// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// Liquid Glass on macOS 26 and later; a material with a hairline before that.
/// For things that float over content: status pills, the command palette.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
        } else {
            content
                .clipShape(shape)
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.separator))
        }
    }
}

extension View {
    func glassSurface(in shape: some InsettableShape) -> some View {
        modifier(GlassSurface(shape: shape))
    }
}

/// A small inline tag: "Default" beside a profile, a machine's tags.
struct Chip: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

/// A bar directly under the toolbar. On macOS 26 it is a safe-area bar that
/// shares the toolbar's layer; before that, a `.bar` strip with a hairline.
struct TopBar<Bar: View>: ViewModifier {
    let isPresented: Bool
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.safeAreaBar(edge: .top, spacing: 0) {
                if isPresented { bar() }
            }
        } else {
            VStack(spacing: 0) {
                if isPresented {
                    bar().background(.bar)
                    Divider()
                }
                content
            }
        }
    }
}

extension View {
    func topBar(isPresented: Bool, @ViewBuilder content: @escaping () -> some View) -> some View {
        modifier(TopBar(isPresented: isPresented, bar: content))
    }
}

/// A sheet's title row, aligned with the grouped form below it. macOS sheets
/// have no titlebar, and the header a NavigationStack would draw indents its
/// title past the form's leading edge.
struct SheetTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)
            .frame(height: 44)
            .accessibilityAddTraits(.isHeader)
    }
}
