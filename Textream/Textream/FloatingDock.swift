//
//  FloatingDock.swift
//  Textream
//

import SwiftUI

/// The tool surface ExcalidrawZ floats over its canvas, brought across to Textream.
///
/// Their editor keeps nothing in the window's chrome. The tools sit on a slab of material that
/// hovers over the work: a hairline edge, a soft drop beneath it, and icon only buttons that print
/// their own keyboard shortcut in the bottom corner. Every measurement is derived from one unit,
/// `size`, so the whole dock rescales by changing a single number, which is how their toolbar
/// steps between its dense and expanded layouts.
///
/// Textream has two grounds where Excalidraw has one. The writing side is white paper and the
/// reading side is a black mirror, so the surface takes a tone rather than following the system
/// appearance.
enum DockTone {
    case light
    case dark

    /// The colour of a tool that is simply available, neither picked nor pressed.
    var idleTint: Color {
        switch self {
        case .light: return .secondary
        case .dark: return .white.opacity(0.75)
        }
    }

    /// The hairline that separates the slab from whatever is behind it. `.separator` is tuned for
    /// window chrome and disappears over black, so the mirror draws its own.
    var edge: AnyShapeStyle {
        switch self {
        case .light: return AnyShapeStyle(.separator)
        case .dark: return AnyShapeStyle(Color.white.opacity(0.12))
        }
    }

    var hoverFill: Color {
        switch self {
        case .light: return .primary.opacity(0.07)
        case .dark: return .white.opacity(0.12)
        }
    }

    /// Their shadow is light mode only, because a dark canvas swallows it. The mirror is darker
    /// than any canvas, so it takes a wider, heavier drop to lift the slab off the black.
    var shadow: (color: Color, radius: CGFloat, y: CGFloat) {
        switch self {
        case .light: return (.black.opacity(0.08), 10, 4)
        case .dark: return (.black.opacity(0.45), 16, 6)
        }
    }
}

/// A row of tools on a floating slab. Put it in an `.overlay` over the pane it acts on, never in
/// the window's toolbar: hovering over the work is the whole point of the pattern.
struct FloatingDock<Content: View>: View {
    var tone: DockTone = .light
    /// The unit the dock is built from. Their toolbar uses 20 and derives everything else from it.
    var size: CGFloat = 20
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
        .padding(size / 3)
        .background {
            RoundedRectangle(cornerRadius: size / 1.6)
                .fill(.regularMaterial)
                .stroke(tone.edge, lineWidth: 0.5)
        }
        // Grouped first, so the drop falls from the slab as one shape rather than from each
        // button through the gaps between them.
        .compositingGroup()
        .shadow(color: tone.shadow.color, radius: tone.shadow.radius, x: 0, y: tone.shadow.y)
        // Material picks its lightness from the appearance around it, not from what is actually
        // behind it. The mirror is black inside a window that is otherwise in light appearance,
        // so without this the slab comes out pale grey on black.
        .environment(\.colorScheme, tone == .dark ? .dark : .light)
    }
}

/// One icon only tool. It carries no label, so the shortcut badge and the tooltip are the whole
/// of how it explains itself, exactly as on their canvas.
struct DockButton: View {
    var systemImage: String
    var help: String
    /// Printed small in the bottom corner of the tool. Keep it to a glyph or two: an arrow, a
    /// digit, a letter. Longer than that and it stops being a badge and starts being a label.
    var shortcut: String? = nil
    /// A tool that is currently picked, drawn the way their selected tool is.
    var isSelected: Bool = false
    /// The one action the pane is built around. Filled solid rather than tinted.
    var isEmphasized: Bool = false
    /// Ends or discards something. Their delete button reads red and nothing else does.
    var isDestructive: Bool = false
    var tint: Color? = nil
    var isDisabled: Bool = false
    var tone: DockTone = .light
    var size: CGFloat = 20
    var action: () -> Void

    @State private var isHovering = false

    private var foreground: Color {
        if isDestructive { return .red }
        if isEmphasized { return .white }
        if let tint { return tint }
        if isSelected { return .accentColor }
        return tone.idleTint
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .resizable()
                .scaledToFit()
                // Sized off the frame rather than a font, so the glyph centres on the cell
                // instead of on a text baseline.
                .frame(width: size * 0.62, height: size * 0.62)
                .frame(width: size, height: size)
                .foregroundStyle(foreground)
                .padding(size / 5)
                .background {
                    RoundedRectangle(cornerRadius: size / 1.6)
                        .fill(cellFill)
                }
                .overlay(alignment: .bottomTrailing) {
                    if let shortcut {
                        // Tucked inside the cell rather than hung off its corner. Their tools are
                        // wide enough to carry an overhanging badge; these are not, and a badge
                        // that escapes the cell reads as a stray glyph in the row.
                        Text(shortcut)
                            .font(.system(size: size * 0.34, weight: .semibold))
                            .foregroundStyle(foreground.opacity(0.65))
                            .padding([.trailing, .bottom], size / 8)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
        .onHover { isHovering = $0 && !isDisabled }
        .help(help)
    }

    private var cellFill: AnyShapeStyle {
        if isEmphasized { return AnyShapeStyle(Color.accentColor) }
        // Their picked tool is the accent colour taken down a level rather than the flat accent,
        // so a selection sits behind the glyph instead of shouting over it.
        if isSelected { return AnyShapeStyle(Color.accentColor.secondary) }
        if isHovering { return AnyShapeStyle(tone.hoverFill) }
        return AnyShapeStyle(Color.clear)
    }
}

/// A value shown between tools, such as the current point size. Sized to match a tool's cell so
/// the row keeps one baseline.
struct DockReadout: View {
    var text: String
    var tone: DockTone = .light
    var size: CGFloat = 20

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.55, weight: .medium, design: .monospaced))
            .foregroundStyle(tone.idleTint)
            .frame(minWidth: size, alignment: .center)
            .padding(.horizontal, size / 6)
            .frame(height: size + (size / 5) * 2)
    }
}

/// Splits a dock into groups. Their toolbar breaks the drawing tools away from everything else the
/// same way.
struct DockDivider: View {
    var tone: DockTone = .light
    var size: CGFloat = 20

    var body: some View {
        Rectangle()
            .fill(tone.edge)
            .frame(width: 1, height: size)
            .padding(.horizontal, size / 4)
    }
}
