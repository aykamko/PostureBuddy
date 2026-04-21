import SwiftUI

/// Overlay shown during the guided-calibration flow. Displays the current instruction
/// (e.g. "Look at the middle of your screen") and a large countdown number during
/// each per-position hold.
struct GuidedCalibrationOverlay: View {
    let instruction: String?
    let countdown: Int?

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()

            VStack(spacing: 18) {
                if let instruction {
                    Text(instruction)
                        .font(countdown == nil ? .title.weight(.semibold) : .title3.weight(.medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
                if let countdown {
                    Text("\(countdown)")
                        .font(.system(size: 140, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: true))
                        .id(countdown)
                }
            }
            .padding(32)
            .frame(maxWidth: 340)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 24))
        }
        .animation(.easeInOut(duration: 0.2), value: countdown)
    }
}
