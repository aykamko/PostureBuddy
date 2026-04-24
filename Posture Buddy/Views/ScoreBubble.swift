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
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: Self.circleSize, height: Self.circleSize)

            BubbleTail()
                .fill(ringColor)
                .frame(width: Self.tailWidth, height: Self.tailHeight)
                .opacity(tailVisible ? 1 : 0)
        }
        .frame(width: Self.circleSize, height: Self.totalHeight)
    }

    private var label: String {
        if let score { return "\(Int(score.value))" }
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
