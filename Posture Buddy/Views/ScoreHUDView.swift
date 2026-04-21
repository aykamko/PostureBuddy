import SwiftUI

struct ScoreHUDView: View {
    let score: PostureScore?
    let isCalibrated: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(score?.grade.swiftUIColor ?? .gray, lineWidth: 7)
                .frame(width: 108, height: 108)
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                Text(isCalibrated ? "score" : "ready")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .background(.black.opacity(0.4), in: Circle())
    }

    private var label: String {
        if let score { return "\(Int(score.value))" }
        return isCalibrated ? "--" : "·"
    }
}
