// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Private pasteboard type for sidebar rows. Declared in Info.plist.
    static let sidebarItem = UTType(exportedAs: "tech.wolff.constellation.sidebar-item")
}

/// What a sidebar drag carries. The pasteboard only marks the type so other
/// apps ignore it; the item itself travels through `SidebarDragSession`.
enum SidebarDragItem: Hashable {
    case machine(MachineID)
    case group(GroupID)

    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = Data("\(self)".utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.sidebarItem.identifier, visibility: .ownProcess) { completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }
}

/// The item being dragged. A plain reference, not observed: the drag source
/// and every drop target read and write it many times per drag, and none of
/// that should redraw the list.
@MainActor
final class SidebarDragSession {
    var item: SidebarDragItem?
}

enum DropEdge {
    case above
    case below
}

/// Accepts sidebar drags on one row and draws the insertion line. When the
/// row is edge-sensitive its upper half means "before" and its lower half
/// "after"; otherwise the whole row is one target and the line sits below.
struct SidebarDropModifier: ViewModifier {
    let session: SidebarDragSession
    let accepts: (SidebarDragItem) -> Bool
    let edgeSensitive: (SidebarDragItem) -> Bool
    let perform: (SidebarDragItem, DropEdge) -> Void
    @State private var height: CGFloat = 24
    @State private var edge: DropEdge?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
            // The modified view is the row's label, inset from the row edges;
            // push the line out to the boundary between rows.
            .overlay(alignment: .top) { if edge == .above { line.offset(y: -6) } }
            .overlay(alignment: .bottom) { if edge == .below { line.offset(y: 6) } }
            .onDrop(of: [.sidebarItem], delegate: Delegate(
                session: session, height: height, edge: $edge,
                accepts: accepts, edgeSensitive: edgeSensitive, perform: perform))
    }

    private var line: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 3)
            .allowsHitTesting(false)
    }

    private struct Delegate: DropDelegate {
        let session: SidebarDragSession
        let height: CGFloat
        @Binding var edge: DropEdge?
        let accepts: (SidebarDragItem) -> Bool
        let edgeSensitive: (SidebarDragItem) -> Bool
        let perform: (SidebarDragItem, DropEdge) -> Void

        func validateDrop(info: DropInfo) -> Bool {
            session.item.map(accepts) ?? false
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            guard let item = session.item, accepts(item) else { return DropProposal(operation: .forbidden) }
            let proposed = edge(for: item, at: info.location)
            if edge != proposed { edge = proposed }
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            edge = nil
        }

        func performDrop(info: DropInfo) -> Bool {
            edge = nil
            guard let item = session.item, accepts(item) else { return false }
            session.item = nil
            perform(item, edge(for: item, at: info.location))
            return true
        }

        private func edge(for item: SidebarDragItem, at location: CGPoint) -> DropEdge {
            edgeSensitive(item) && location.y < height / 2 ? .above : .below
        }
    }
}
