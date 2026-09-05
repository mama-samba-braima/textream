//
//  SidebarRow.swift
//  Textream
//

import SwiftUI

/// ExcalidrawZ's sidebar row, brought across.
///
/// Their sidebar does not use the list's own selection at all. Every row paints itself: an inset
/// rounded pill that fills with the accent colour at a fifth of its strength when the row is
/// picked, with grey at the same strength when the pointer is merely over it, and with nothing
/// otherwise. Hover, selection and press are one state, so the row answers the pointer before it
/// is clicked and the picked row never becomes a solid bar across the whole column.
///
/// That is worth having here for a reason beyond looks. A system selection paints whatever the
/// list decides is one row, which is what made picking a page light up its sections along with it.
/// A row that paints itself can only ever light up itself.
struct SidebarRowSurface: ViewModifier {
    var isSelected: Bool
    var isPressed: Bool = false
    /// How far in the row sits, in steps. Their rows carry their depth as leading padding rather
    /// than leaning on the list to indent them.
    var depth: Int = 0
    /// The row's inner padding. Fixed in their sidebar; here it follows the sidebar text size, so
    /// a larger sidebar gets taller rows rather than the same rows with bigger writing in them.
    var padding: CGFloat = 6

    @State private var isHovered = false

    private var isActive: Bool { isHovered || isSelected || isPressed }

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content
            Spacer(minLength: 0)
        }
        .padding(padding)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(isPressed ? 0.28 : 0.2)
                        : Color.gray.opacity(isPressed ? 0.28 : 0.2)
                )
                .opacity(isActive ? 1 : 0)
        }
        // Their sidebar indents the label and leaves the pill full width, because a file and the
        // folder holding it are never both lit. Here a page and the section being read are lit at
        // once, and two full width pills touching read as one block across both rows. Indenting
        // the pill as well as the label keeps the child underneath its parent rather than joined
        // to it.
        .padding(.leading, CGFloat(depth) * padding * 2)
        .animation(.easeInOut(duration: 0.16), value: isActive)
    }
}

extension View {
    func sidebarRowSurface(
        isSelected: Bool,
        depth: Int = 0,
        padding: CGFloat = 6
    ) -> some View {
        modifier(SidebarRowSurface(isSelected: isSelected, depth: depth, padding: padding))
    }

    /// Strips the list's own chrome from a row so the surface above is the only thing drawn.
    /// Without this the sidebar style paints its selection underneath the pill.
    func sidebarRowChrome() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 2, trailing: 6))
            .listRowSeparator(.hidden)
    }
}
