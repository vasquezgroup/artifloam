import SwiftUI

/// A thick linear indicator. Unknown totals stay indeterminate; measured values
/// may be supplied without converting elapsed time into a fictitious percentage.
struct StewardProgressBar: View {
    var title: String? = nil
    var value: Double? = nil
    var thickness: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @Environment(\.stewardTheme) private var theme
    private var mint: Color { theme.accent }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title { Text(title).stewardFont(.caption).foregroundStyle(.secondary) }
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: value != nil || reduceMotion || phase != .active)) { timeline in
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        if let value {
                            Capsule().fill(LinearGradient(colors: [mint.opacity(0.70), mint], startPoint: .leading, endPoint: .trailing))
                                .frame(width: geometry.size.width * min(1, max(0, value)))
                        } else if reduceMotion || phase != .active {
                            Capsule().fill(mint.opacity(0.48)).frame(width: geometry.size.width * 0.40).offset(x: geometry.size.width * 0.30)
                        } else {
                            let fraction = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.65) / 1.65
                            let segment = geometry.size.width * 0.40
                            Capsule().fill(LinearGradient(colors: [mint.opacity(0.22), mint, .white.opacity(0.80), .mint.opacity(0.22)], startPoint: .leading, endPoint: .trailing))
                                .frame(width: segment).offset(x: (geometry.size.width + segment) * fraction - segment)
                        }
                    }.clipShape(Capsule()).overlay { Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5) }
                }.frame(height: thickness)
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel(title ?? "Progress")
            .accessibilityValue(value.map { "\(Int(min(1, max(0, $0)) * 100)) percent" } ?? "In progress; total not yet known")
    }
}
