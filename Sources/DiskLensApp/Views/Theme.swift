import AppKit
import SwiftUI

extension Color {
    /// A color with separate light and dark appearances.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

enum Theme {
    static let brandStart = Color(light: 0x2A78D6, dark: 0x3987E5)
    static let brandEnd = Color(light: 0x13A979, dark: 0x1BAF7A)
    static var brand: LinearGradient {
        LinearGradient(colors: [brandStart, brandEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let safe = Color(light: 0x0CA30C, dark: 0x2DBE4B)
    static let review = Color(light: 0xE08A00, dark: 0xF5A623)
    static let keep = Color.secondary
    static let danger = Color(light: 0xD03B3B, dark: 0xE66767)

    static let cardRadius: CGFloat = 16
}

/// Fixed color and icon per category, so a category keeps its look as sizes change.
/// The eight hues follow a palette checked for colour-blind separation; the rest share a neutral.
enum CategoryStyle {
    static func of(_ name: String) -> (symbol: String, color: Color) {
        switch name {
        case "Documents": ("doc.fill", Color(light: 0x2A78D6, dark: 0x3987E5))
        case "App data": ("square.stack.3d.up.fill", Color(light: 0x4A3AA7, dark: 0x9085E9))
        case "Caches & temp": ("archivebox.fill", Color(light: 0xEB6834, dark: 0xD95926))
        case "Applications": ("square.grid.2x2.fill", Color(light: 0x1BAF7A, dark: 0x199E70))
        case "Developer tools": ("wrench.and.screwdriver.fill", Color(light: 0xEDA100, dark: 0xC98500))
        case "Photos & media": ("photo.fill", Color(light: 0xE87BA4, dark: 0xD55181))
        case "Xcode & Simulators": ("hammer.fill", Color(light: 0x008300, dark: 0x008300))
        case "Docker": ("shippingbox.fill", Color(light: 0xE34948, dark: 0xE66767))
        case "Android SDK": ("cpu.fill", neutral)
        case "Desktop & Downloads": ("arrow.down.circle.fill", neutral)
        case "Trash": ("trash.fill", neutral)
        default: ("ellipsis.circle.fill", neutral)
        }
    }

    static let neutral = Color(light: 0x9A9890, dark: 0x6B6A65)
}

/// Shows the pointing-hand cursor over anything clickable.
struct HandCursor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            content.onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.pointingHand.set()
                case .ended: NSCursor.arrow.set()
                }
            }
        }
    }
}

extension View {
    func handCursor() -> some View { modifier(HandCursor()) }
}

/// A text link in the brand color, with the hand cursor.
struct LinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Theme.brandStart : Color.secondary)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
            .handCursor()
    }
}

extension ButtonStyle where Self == LinkButtonStyle {
    static var textLink: LinkButtonStyle { LinkButtonStyle() }
}

/// Plain icon button (Finder, copy) with the hand cursor.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .padding(4)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.0001), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .handCursor()
    }
}

struct PremiumCard: ViewModifier {
    var padding: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }
}

extension View {
    func premiumCard(padding: CGFloat = 20) -> some View { modifier(PremiumCard(padding: padding)) }
}

/// Soft brand-tinted page background.
struct PageBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [Theme.brandStart.opacity(0.07), Theme.brandEnd.opacity(0.03), .clear],
                           startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
    }
}

struct GradientButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font((large ? Font.body : .callout).weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 18 : 12)
            .padding(.vertical, large ? 10 : 6)
            .background(Theme.brand.opacity(isEnabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: large ? 11 : 8, style: .continuous))
            .shadow(color: Theme.brandStart.opacity(isEnabled ? 0.3 : 0), radius: 6, y: 2)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(Rectangle())
            .handCursor()
    }
}

struct SoftButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color = .accentColor
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font((large ? Font.body : .callout).weight(.semibold))
            .foregroundStyle(isEnabled ? tint : .secondary)
            .padding(.horizontal, large ? 18 : 12)
            .padding(.vertical, large ? 10 : 6)
            .background(tint.opacity(configuration.isPressed ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: large ? 11 : 8, style: .continuous))
            .contentShape(Rectangle())
            .handCursor()
    }
}

/// Circular gauge of how full the drive is.
struct RingGauge: View {
    let fraction: Double
    let free: String
    let total: String
    var size: CGFloat = 170

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 16)
            Circle()
                .trim(from: 0, to: max(0.01, min(1, fraction)))
                .stroke(AngularGradient(colors: [Theme.brandEnd, Theme.brandStart, fraction > 0.9 ? Theme.danger : Theme.brandStart],
                                        center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * fraction)),
                        style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text(free).font(.system(size: size * 0.17, weight: .bold, design: .rounded)).monospacedDigit()
                Text("free of \(total)").font(.caption).foregroundStyle(.secondary)
                Text("\(Int((fraction * 100).rounded()))% used").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .padding(.top, 4)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .combine)
    }
}

/// Small colored icon tile used on cards and rows.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct Chip: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = .secondary
    var help: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
        .help(help ?? "")
    }
}
