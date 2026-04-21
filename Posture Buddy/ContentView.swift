//
//  ContentView.swift
//  Posture Buddy
//
//  Created by Aleks Kamko on 4/20/26.
//

import SwiftUI
import UIKit
import AudioToolbox

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var poseEstimator = PoseEstimator()
    @EnvironmentObject private var notificationManager: NotificationManager

    @Environment(\.scenePhase) private var scenePhase
    @State private var isUpsideDown = false
    @State private var countdown: Int? = nil
    @State private var countdownTask: Task<Void, Never>? = nil

    private let countdownDuration = 5

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
                    ScoreHUDView(score: poseEstimator.currentPose?.score,
                                 isCalibrated: poseEstimator.isCalibrated)
                        .padding()
                    Spacer()
                }
                Spacer()

                if poseEstimator.isCalibrated,
                   countdown == nil,
                   case .warning(let seconds) = notificationManager.alertState {
                    Text("Poor posture — alert in \(seconds)s")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(.bottom, 12)
                }

                CalibrateButton(isCalibrated: poseEstimator.isCalibrated,
                                countdown: countdown) {
                    if countdown != nil {
                        cancelCountdown()
                    } else {
                        startCountdown()
                    }
                }
                .padding(.bottom, 30)
            }
            .rotationEffect(isUpsideDown ? .degrees(180) : .zero)

            if let countdown {
                CountdownOverlay(value: countdown)
                    .rotationEffect(isUpsideDown ? .degrees(180) : .zero)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isUpsideDown)
        .animation(.easeInOut(duration: 0.2), value: countdown)
        .task {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            isUpsideDown = UIDevice.current.orientation == .portraitUpsideDown
            poseEstimator.updateOrientation(visionOrientation(for: UIDevice.current.orientation))
            await cameraManager.requestAccessAndSetup()
            cameraManager.setSampleBufferDelegate(poseEstimator)
            cameraManager.start()
        }
        .onChange(of: poseEstimator.currentPose?.score?.value) {
            guard poseEstimator.isCalibrated else { return }
            notificationManager.update(score: poseEstimator.currentPose?.score)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let deviceOrientation = UIDevice.current.orientation
            let flipped = deviceOrientation == .portraitUpsideDown
            isUpsideDown = flipped
            poseEstimator.updateOrientation(visionOrientation(for: deviceOrientation))
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                cameraManager.start()
            case .background, .inactive:
                cameraManager.stop()
                cancelCountdown()
                notificationManager.update(score: nil)
            @unknown default:
                break
            }
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdown = countdownDuration
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        SoundEffects.play(.tick)
        countdownTask = Task { @MainActor in
            for remaining in stride(from: countdownDuration - 1, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                countdown = remaining > 0 ? remaining : nil
                if remaining > 0 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    SoundEffects.play(.tick)
                }
            }
            // remaining == 0 — capture the baseline
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            SoundEffects.play(.capture)
            poseEstimator.calibrate()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }
}

private func visionOrientation(for deviceOrientation: UIDeviceOrientation) -> CGImagePropertyOrientation {
    deviceOrientation == .portraitUpsideDown ? .rightMirrored : .leftMirrored
}

struct ScoreHUDView: View {
    let score: PostureScore?
    let isCalibrated: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(gradeColor, lineWidth: 5)
                .frame(width: 72, height: 72)
            VStack(spacing: 1) {
                Text(label)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text(isCalibrated ? "score" : "ready")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .background(.black.opacity(0.4), in: Circle())
    }

    private var label: String {
        if let score { return "\(Int(score.value))" }
        return isCalibrated ? "--" : "·"
    }

    private var gradeColor: Color {
        guard let c = score?.grade.color else { return .gray }
        return Color(red: c.red, green: c.green, blue: c.blue)
    }
}

struct CalibrateButton: View {
    let isCalibrated: Bool
    let countdown: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(label).font(.callout.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Capsule().fill(background))
        }
    }

    private var icon: String {
        if countdown != nil { return "xmark.circle.fill" }
        return isCalibrated ? "arrow.clockwise.circle.fill" : "scope"
    }

    private var label: String {
        if countdown != nil { return "Cancel" }
        return isCalibrated ? "Recalibrate" : "Set Baseline Posture"
    }

    private var background: Color {
        if countdown != nil { return .red.opacity(0.8) }
        return isCalibrated ? Color.white.opacity(0.2) : Color.accentColor
    }
}

struct CountdownOverlay: View {
    let value: Int

    var body: some View {
        VStack(spacing: 12) {
            Text("\(value)")
                .font(.system(size: 160, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .id(value)
            Text("Hold your best posture")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(40)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 28))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.35))
        .animation(.easeInOut(duration: 0.25), value: value)
    }
}

#Preview {
    ContentView()
        .environmentObject(NotificationManager())
}
