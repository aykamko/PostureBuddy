import SwiftUI

struct AlertOverlay: View {
    let title: String
    let message: String
    let buttonTitle: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.leading)
                Button(action: onDismiss) {
                    Text(buttonTitle)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.accentColor))
                }
                .padding(.top, 4)
            }
            .padding(22)
            .frame(maxWidth: 320)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.15)))
            .padding(24)
        }
    }
}
