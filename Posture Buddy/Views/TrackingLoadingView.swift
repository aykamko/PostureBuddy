import SwiftUI

struct TrackingLoadingView: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text(message)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Capsule().fill(Color.white.opacity(0.18)))
    }
}
