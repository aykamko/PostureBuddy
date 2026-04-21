//
//  ContentView.swift
//  Posture Buddy
//
//  Created by Aleks Kamko on 4/20/26.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var poseEstimator = PoseEstimator()
    @EnvironmentObject private var notificationManager: NotificationManager

    @Environment(\.scenePhase) private var scenePhase
    @State private var isUpsideDown = false
    @State private var showUnsupportedAlert = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(session: cameraManager.session)
                .ignoresSafeArea()

            PostureOverlayView(detectedPose: poseEstimator.currentPose)
                .ignoresSafeArea()
                .rotationEffect(isUpsideDown ? .degrees(180) : .zero)

            VStack {
                HStack {
                    ScoreHUDView(score: poseEstimator.currentPose?.score)
                        .padding()
                    Spacer()
                }
                Spacer()
                if case .warning(let seconds) = notificationManager.alertState {
                    Text("Poor posture — alert in \(seconds)s")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(.bottom, 20)
                }
            }
            .rotationEffect(isUpsideDown ? .degrees(180) : .zero)
        }
        .animation(.easeInOut(duration: 0.3), value: isUpsideDown)
        .task {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            isUpsideDown = UIDevice.current.orientation == .portraitUpsideDown
            poseEstimator.updateOrientation(visionOrientation(for: UIDevice.current.orientation))
            await cameraManager.requestAccessAndSetup()
            cameraManager.setSampleBufferDelegate(poseEstimator)
            cameraManager.start()
        }
        .onChange(of: poseEstimator.currentPose?.score.value) {
            notificationManager.update(score: poseEstimator.currentPose?.score)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let deviceOrientation = UIDevice.current.orientation
            let flipped = deviceOrientation == .portraitUpsideDown
            print("[Posture] orientation changed: \(deviceOrientation.rawValue) → upsideDown: \(flipped)")
            isUpsideDown = flipped
            poseEstimator.updateOrientation(visionOrientation(for: deviceOrientation))
        }
        .onChange(of: poseEstimator.threeDStatus) { _, status in
            if status == .unavailable { showUnsupportedAlert = true }
        }
        .alert("Device Not Supported", isPresented: $showUnsupportedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Posture Buddy requires 3D body pose estimation, which isn't available on this device. Without it, posture scoring would be inaccurate due to camera angle.")
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                cameraManager.start()
            case .background, .inactive:
                cameraManager.stop()
                notificationManager.update(score: nil)
            @unknown default:
                break
            }
        }
    }
}

private func visionOrientation(for deviceOrientation: UIDeviceOrientation) -> CGImagePropertyOrientation {
    // Front camera, portrait: .leftMirrored; upside-down portrait: .rightMirrored
    deviceOrientation == .portraitUpsideDown ? .rightMirrored : .leftMirrored
}

struct ScoreHUDView: View {
    let score: PostureScore?

    var body: some View {
        ZStack {
            Circle()
                .stroke(gradeColor, lineWidth: 5)
                .frame(width: 72, height: 72)
            VStack(spacing: 1) {
                Text(score.map { "\(Int($0.value))" } ?? "--")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("score")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .background(.black.opacity(0.4), in: Circle())
    }

    private var gradeColor: Color {
        guard let c = score?.grade.color else { return .gray }
        return Color(red: c.red, green: c.green, blue: c.blue)
    }
}

#Preview {
    ContentView()
        .environmentObject(NotificationManager())
}
