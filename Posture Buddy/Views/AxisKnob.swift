import SwiftUI

/// Press-and-drag vertical slider for one rotation axis. Captures the value at
/// the start of each drag, so the number accumulates across multiple strokes
/// instead of snapping back. Swipe up → value increases, swipe down → decreases.
///
/// Used by `ContentView` in Hide-UI (debug) mode to spin the 3D model's
/// yaw / pitch / roll without fighting SceneKit's built-in camera controller.
struct AxisKnob: View {
    let label: String
    @Binding var value: Double
    var degPerPoint: Double = 1.0
    var accent: Color = .white

    @State private var dragStart: Double?

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.footnote.weight(.bold))
                .foregroundStyle(accent)
            Text("\(Int(value.rounded()))°")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(accent.opacity(0.8))
        }
        .frame(width: 56, height: 56)
        .background(Circle().fill(.black.opacity(0.55)))
        .overlay(Circle().stroke(accent.opacity(0.45), lineWidth: 1))
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    if dragStart == nil { dragStart = value }
                    value = (dragStart ?? 0) - Double(gesture.translation.height) * degPerPoint
                }
                .onEnded { _ in dragStart = nil }
        )
    }
}
