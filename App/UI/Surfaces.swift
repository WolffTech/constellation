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
