import SwiftUI

/// "Posture Buddy" — the friendly mascot figure shown on the main screen as the
/// app's primary user-facing visual. Side-profile caricature of someone sitting
/// at a desk. Head + neck pivot forward at the shoulder as the score drops,
/// mimicking forward-head posture (the same thing the ear-shoulder angle
/// measures). Built from SwiftUI primitives — no custom asset, no SF Symbol.
///
/// Color cue: the head + nose track the current grade color (green / yellow / red).
/// This deliberately matches `ScoreHUDView`'s ring tint — both surfaces should
/// "agree" at a glance. Don't refactor as redundant.
///
/// Mirroring: the figure faces the same direction the user appears to face in
/// the (mirrored) camera preview. The mapping is empirically inverted from the
/// "obvious" geometry — `dominantEar == .left` mirrors, `.right` doesn't. This
/// is because Vision's anatomical left/right ear labels on the `.leftMirrored`
/// front-camera buffer don't line up with the user's true anatomy in the way
/// you'd naively expect; the mapping was determined by trying both and seeing
/// which produced the matches-the-mirror result. `nil` (pre-calibration) →
/// default right-facing pose.
///
/// Animation policy: this view is a pure function of `score` and `dominantEar`.
/// Smooth interpolation is driven by the body-level `.animation(_:value:)` chain
/// in `ContentView`, not by state inside this view.
struct PostureBuddyView: View {
    let score: PostureScore?
    let dominantEar: EarSide?

    // Fixed inner coordinate space so positions + the rotation anchor stay
    // deterministic across renders. `.position(x:y:)` on every shape — no
    // VStack/HStack auto-sizing, which could drift the anchor between states.
    private static let canvasSize = CGSize(width: 220, height: 260)
    private static let shoulderPivot = CGPoint(x: 35, y: 95)
    private static let bodyOpacity: Double = 0.85
    private static let furnitureOpacity: Double = 0.4

    var body: some View {
        ZStack {
            furniture
            limbs
            headNeck
        }
        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
        // Mirror horizontally based on which side Vision tracks. The condition
        // is empirically `.left`-triggered (not `.right`, as raw anatomy would
        // suggest) — see the doc-comment header for why. Mirroring also flips
        // the head's clockwise pivot into counter-clockwise visually, so the
        // head still leans toward the desk in either orientation.
        .scaleEffect(x: dominantEar == .left ? -1 : 1, y: 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Static layers

    private var furniture: some View {
        ZStack {
            // Desk top
            Rectangle()
                .fill(.white.opacity(Self.furnitureOpacity))
                .frame(width: 140, height: 6)
                .position(x: 140, y: 140)
            // Desk leg (right side, away from the figure)
            Rectangle()
                .fill(.white.opacity(Self.furnitureOpacity))
                .frame(width: 6, height: 100)
                .position(x: 203, y: 192)
            // Chair seat
            RoundedRectangle(cornerRadius: 3)
                .fill(.white.opacity(Self.furnitureOpacity))
                .frame(width: 90, height: 10)
                .position(x: 65, y: 175)
            // Chair back
            RoundedRectangle(cornerRadius: 4)
                .fill(.white.opacity(Self.furnitureOpacity))
                .frame(width: 12, height: 85)
                .position(x: 21, y: 130)
        }
    }

    /// Stick-figure limbs as a single stroked Path. Round line caps + joins make
    /// the joints look like ball-joints without separate shapes.
    private var limbs: some View {
        ZStack {
            Path { p in
                // Visible-side shin: knee → foot
                p.move(to: CGPoint(x: 105, y: 170))
                p.addLine(to: CGPoint(x: 105, y: 240))
                // Thigh: hip/butt → knee (slightly downward toward chair front)
                p.move(to: CGPoint(x: 35, y: 165))
                p.addLine(to: CGPoint(x: 105, y: 170))
                // Torso: hip → shoulder (vertical; the spine is static, only the
                // head/neck pivots above the shoulder)
                p.move(to: CGPoint(x: 35, y: 165))
                p.addLine(to: Self.shoulderPivot)
                // Arm: shoulder → hand on desk
                p.move(to: Self.shoulderPivot)
                p.addLine(to: CGPoint(x: 140, y: 140))
            }
            .stroke(
                .white.opacity(Self.bodyOpacity),
                style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round)
            )
            // Hand resting on desk
            Circle()
                .fill(.white.opacity(Self.bodyOpacity))
                .frame(width: 14, height: 14)
                .position(x: 140, y: 140)
        }
    }

    // MARK: - Pivoting layer

    /// 80×90 container whose bottom-center sits exactly on the shoulder pivot.
    /// `.rotationEffect(anchor: .init(x: 0.5, y: 1.0))` rotates around that
    /// bottom-center, sweeping the head through a forward arc.
    private var headNeck: some View {
        ZStack {
            // Neck: bottom of capsule sits at the shoulder pivot
            Capsule()
                .fill(.white.opacity(Self.bodyOpacity))
                .frame(width: 10, height: 22)
                .position(x: 40, y: 79)
            // Head
            Circle()
                .fill(headColor)
                .frame(width: 50, height: 50)
                .position(x: 40, y: 35)
            // Nose nub on the right side (sells "side profile" without an SF Symbol)
            Circle()
                .fill(headColor)
                .frame(width: 9, height: 9)
                .position(x: 60, y: 35)
        }
        .frame(width: 80, height: 90)
        .rotationEffect(.degrees(Self.leanDegrees(for: score)), anchor: UnitPoint(x: 0.5, y: 1.0))
        // Position the container's center so its bottom-center lands on the
        // shoulder pivot: center.y = pivot.y - height/2.
        .position(x: Self.shoulderPivot.x, y: Self.shoulderPivot.y - 45)
    }

    // MARK: - Score → degrees / color

    private var headColor: Color {
        score?.grade.swiftUIColor ?? .white
    }

    /// Linear ramp from upright to max forward lean. Pre-calibration / nil →
    /// upright. The 90-cap gives a visible micro-lean even at "good but not
    /// perfect" scores; the 30-floor caps the visual at a clearly-bad pose
    /// (real-world poor scores typically bottom out around 20–40, never 0).
    static func leanDegrees(for score: PostureScore?) -> Double {
        guard let value = score?.value else { return 0 }
        let upright: Float = 90
        let floor: Float = 30
        let maxLean: Double = 35
        if value >= upright { return 0 }
        if value <= floor { return maxLean }
        let t = Double((upright - value) / (upright - floor))
        return t * maxLean
    }
}
