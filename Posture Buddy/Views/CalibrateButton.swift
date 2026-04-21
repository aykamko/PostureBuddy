import SwiftUI

struct CalibrateButton: View {
    let isCalibrated: Bool
    let isActive: Bool   // true during audio-prime or countdown phases
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                Text(label).font(.title2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
            .background(Capsule().fill(background))
        }
    }

    private var icon: String {
        if isActive { return "xmark.circle.fill" }
        return isCalibrated ? "arrow.clockwise.circle.fill" : "scope"
    }

    private var label: String {
        if isActive { return "Cancel" }
        return isCalibrated ? "Recalibrate" : "Set Baseline Posture"
    }

    private var background: Color {
        if isActive { return .red.opacity(0.8) }
        return isCalibrated ? Color.white.opacity(0.2) : Color.accentColor
    }
}
