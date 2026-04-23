import SwiftUI

struct CalibrateButton: View {
    let isCalibrated: Bool
    let hasSavedBaselines: Bool   // true when restored from disk, awaiting "Start Tracking" tap
    let isActive: Bool            // true during audio-prime or countdown phases
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

    // Priority: cancel > recalibrate > start tracking > set baseline
    private var icon: String {
        if isActive { return "xmark.circle.fill" }
        if isCalibrated { return "arrow.clockwise.circle.fill" }
        if hasSavedBaselines { return "play.circle.fill" }
        return "scope"
    }

    private var label: String {
        if isActive { return "Cancel" }
        if isCalibrated { return "Recalibrate" }
        if hasSavedBaselines { return "Start Tracking" }
        return "Set Baseline Posture"
    }

    private var background: Color {
        if isActive { return .red.opacity(0.8) }
        if isCalibrated { return Color.white.opacity(0.2) }
        return Color.accentColor   // both Start Tracking and Set Baseline are primary actions
    }
}
