import SwiftUI

/// Floating score readout — a circle with the current score number inside,
/// optionally with a downward tail so it reads as a speech-bubble pointing to
/// the buddy's head. The tail is fade-only (its frame stays in the bbox) so
/// callers can position the bbox by `.position(_:)` without the layout
/// shifting between with-tail and without-tail states.
struct ScoreBubble: View {
    let score: PostureScore?
    let isCalibrated: Bool
    let tailVisible: Bool

    static let circleSize: CGFloat = 80
    static let tailWidth: CGFloat = 14
    static let tailHeight: CGFloat = 12
    /// Total bbox height — circle + tail, with a 2pt overlap so the tail
    /// reads as continuous with the circle's stroke instead of a floating
    /// triangle below it.
    static let totalHeight: CGFloat = circleSize + tailHeight - 2

    private var ringColor: Color {
        score?.grade.swiftUIColor ?? .white.opacity(0.55)
    }

    var body: some View {
        VStack(spacing: -2) {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.55))
                Circle()
                    .stroke(ringColor, lineWidth: 5)
                Text(label)
                    .font(.system(size: 30, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.identity)
            }
            .frame(width: Self.circleSize, height: Self.circleSize)

            BubbleTail()
                .fill(ringColor)
                .frame(width: Self.tailWidth, height: Self.tailHeight)
                .opacity(tailVisible ? 1 : 0)
        }
        .frame(width: Self.circleSize, height: Self.totalHeight)
        // 3pt of breathing room around the bubble before the offscreen Metal
        // buffer is sized — without this the Circle's stroke (which extends
        // ±2.5pt outside the circle path) gets clipped at the buffer edge,
        // leaving rough ring edges. The padding expands the bbox by 3pt on
        // every side; the bubble's geometric center is unchanged so external
        // `.position()` math stays correct.
        .padding(3)
        // Coalesce shapes + text into one Metal layer so position animations
        // transform them as a single unit. Without drawingGroup, SwiftUI
        // renders Text into its own backing store that lags behind the rim
        // during fast motion (slouch tilts, etc.).
        .drawingGroup()
    }

    private var label: String {
        if let score { return "\(Int(score.value.rounded()))" }
        return isCalibrated ? "--" : "·"
    }
}

private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
