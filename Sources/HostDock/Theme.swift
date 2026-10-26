import AppKit
import SwiftUI

enum DockTheme {
    static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: NSColor.Name("HostDock.\(name)")) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
    static let backgroundNS = adaptive("background", light: 0xF3F6FA, dark: 0x101722)
    static let surfaceNS = adaptive("surface", light: 0xFFFFFF, dark: 0x182432)
    static let textNS = adaptive("text", light: 0x18283B, dark: 0xE9F0F7)
    static let secondaryNS = adaptive("secondary", light: 0x566C85, dark: 0x8FA2B8)
    static let accentNS = adaptive("accent", light: 0x087F9C, dark: 0x35C8E8)
    static let borderNS = adaptive("border", light: 0xDDE5EF, dark: 0x2A394A)
    static let onAccent = Color(nsColor: adaptive("onAccent", light: 0xFFFFFF, dark: 0x08232D))
    static let background = Color(nsColor: backgroundNS)
    static let surface = Color(nsColor: surfaceNS)
    static let text = Color(nsColor: textNS)
    static let secondary = Color(nsColor: secondaryNS)
    static let accent = Color(nsColor: accentNS)
    static let border = Color(nsColor: borderNS)
}

struct HostDockMark: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            Path { path in
                path.move(to: CGPoint(x: w * 0.38, y: h * 0.18))
                path.addLine(to: CGPoint(x: w * 0.22, y: h * 0.18))
                path.addLine(to: CGPoint(x: w * 0.22, y: h * 0.82))
                path.addLine(to: CGPoint(x: w * 0.38, y: h * 0.82))
                path.move(to: CGPoint(x: w * 0.62, y: h * 0.18))
                path.addLine(to: CGPoint(x: w * 0.78, y: h * 0.18))
                path.addLine(to: CGPoint(x: w * 0.78, y: h * 0.82))
                path.addLine(to: CGPoint(x: w * 0.62, y: h * 0.82))
                path.move(to: CGPoint(x: w * 0.24, y: h * 0.5))
                path.addLine(to: CGPoint(x: w * 0.76, y: h * 0.5))
            }.stroke(style: StrokeStyle(lineWidth: w * 0.105, lineCap: .round, lineJoin: .round))
        }
    }
}

struct DockButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @ViewState private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium)).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 14).frame(minHeight: 36)
            .foregroundStyle(prominent ? DockTheme.onAccent : DockTheme.text)
            .background(prominent ? DockTheme.accent : DockTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? DockTheme.accent : prominent ? Color.clear : DockTheme.border, lineWidth: focused ? 2 : 1))
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
            .overlay(RoundedRectangle(cornerRadius: 8).fill(DockTheme.accent.opacity(enabled && hovered ? 0.06 : 0)).allowsHitTesting(false))
            .onHover { hovered = $0 }.modifier(DockHoverCursor())
    }
}

struct DockHoverCursor: ViewModifier {
    var cursor = NSCursor.pointingHand
    @Environment(\.isEnabled) private var enabled
    @ViewState private var hovered = false
    @ViewState private var pushed = false
    func body(content: Content) -> some View {
        content.onHover { hovered = $0; update($0 && enabled) }
            .onChange(of: enabled) { _, value in update(hovered && value) }
            .onDisappear { update(false) }
    }
    private func update(_ active: Bool) {
        guard active != pushed else { return }
        if active { cursor.push() } else { NSCursor.pop() }
        pushed = active
    }
}

struct DockTextFieldStyle: TextFieldStyle {
    @FocusState private var focused: Bool
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).focused($focused)
            .padding(.horizontal, 11).frame(height: 36)
            .background(DockTheme.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? DockTheme.accent : DockTheme.border, lineWidth: focused ? 2 : 1))
    }
}

struct DockFormField<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { Text(title).frame(width: 104, alignment: .leading); content().frame(minWidth: 120, maxWidth: .infinity) }
            VStack(alignment: .leading, spacing: 8) { Text(title); content() }
        }.font(.system(size: 12)).textFieldStyle(DockTextFieldStyle())
    }
}

struct DockTabs<Selection: Hashable>: View {
    let options: [(Selection, String)]
    @Binding var selection: Selection
    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title).font(.system(size: 13, weight: selection == value ? .semibold : .medium))
                        .frame(maxWidth: .infinity).frame(height: 32).contentShape(Rectangle())
                        .foregroundStyle(selection == value ? DockTheme.text : DockTheme.secondary)
                        .background(selection == value ? DockTheme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selection == value ? DockTheme.border : Color.clear))
                }.buttonStyle(.plain).modifier(DockHoverCursor()).accessibilityLabel(title).accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }.padding(2).background(DockTheme.background, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
    }
}

struct DockNotice: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.system(size: 12)).foregroundStyle(DockTheme.text)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .textSelection(.enabled)
    }
}
