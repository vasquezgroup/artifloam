import AppKit
import SwiftUI

private struct StewardTextScaleKey: EnvironmentKey { static let defaultValue: Double = 1 }
extension EnvironmentValues {
    var stewardTextScale: Double {
        get { self[StewardTextScaleKey.self] }
        set { self[StewardTextScaleKey.self] = newValue }
    }
}

/// AppKit's semantic fonts keep the native hierarchy. Reading-size support is
/// app-specific on macOS, so the app supplies a persistent, explicit enlargement.
enum StewardTextStyle {
    case body, callout, caption, caption2, headline, title, title2, title3
    var native: NSFont.TextStyle {
        switch self {
        case .body: return .body
        case .callout: return .callout
        case .caption: return .caption1
        case .caption2: return .caption2
        case .headline: return .headline
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        }
    }
}
private struct StewardFont: ViewModifier {
    @Environment(\.stewardTextScale) private var scale
    let style: StewardTextStyle
    let weight: Font.Weight?
    let design: Font.Design
    func body(content: Content) -> some View {
        let base = max(style == .body || style == .callout ? 13 : 11,
                       NSFont.preferredFont(forTextStyle: style.native, options: [:]).pointSize)
        content.font(.system(size: base * scale, weight: weight ?? (style == .headline ? .semibold : .regular), design: design))
    }
}
extension View {
    func stewardFont(_ style: StewardTextStyle, weight: Font.Weight? = nil, design: Font.Design = .default) -> some View {
        modifier(StewardFont(style: style, weight: weight, design: design))
    }
}

/// Larger, consistent targets without the platform's thin compact field bezel.
struct StewardInputStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).stewardFont(.body)
            .padding(.horizontal, 13).padding(.vertical, 11).frame(minHeight: 42)
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.10), lineWidth: 0.7).allowsHitTesting(false) }
    }
}
extension View { func stewardInput() -> some View { modifier(StewardInputStyle()) } }
