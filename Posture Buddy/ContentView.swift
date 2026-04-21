//
//  ContentView.swift
//  Posture Buddy
//
//  Created by Aleks Kamko on 4/20/26.
//

import SwiftUI
import UIKit
import AudioToolbox

// Guided-calibration timing constants. Kept at file scope so they're easy to tune.
private let postVoicePause: Duration = .milliseconds(300)
private let captureHoldAfterBeat: Duration = .milliseconds(500)
private let postCaptureMarimbaPause: Duration = .milliseconds(400)
private let countdownBeatInterval: Duration = .seconds(1)

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var poseEstimator = PoseEstimator()
    @StateObject private var soundCoach = PostureSoundCoach()
    @EnvironmentObject private var notificationManager: NotificationManager

    @Environment(\.scenePhase) private var scenePhase
    @State private var isUpsideDown: Bool = UIDevice.current.orientation == .portraitUpsideDown
    @State private var countdown: Int? = nil
    @State private var calibrationInstruction: String? = nil
    @State private var countdownTask: Task<Void, Never>? = nil
    @State private var trackingTimeoutTask: Task<Void, Never>? = nil
    @State private var showTrackingFailedAlert = false

    private let perPositionCountdown = 3  // 3-beat countdown per position (3, 2, 1=capture)
    private let trackingTimeoutSeconds: Double = 45

    private var isCalibrating: Bool {
        countdown != nil || calibrationInstruction != nil
    }

    var body: some View {
        mainContent
        .animation(.easeInOut(duration: 0.3), value: isUpsideDown)
        .animation(.easeInOut(duration: 0.2), value: countdown)
        .animation(.easeInOut(duration: 0.2), value: calibrationInstruction)
        .animation(.easeInOut(duration: 0.2), value: showTrackingFailedAlert)
        .task {
            poseEstimator.updateOrientation(visionOrientation(for: UIDevice.current.orientation))
            UIApplication.shared.isIdleTimerDisabled = true
            await cameraManager.requestAccessAndSetup()
            cameraManager.setSampleBufferDelegate(poseEstimator)
            cameraManager.start()
            startTrackingTimeout()
        }
        .onChange(of: poseEstimator.isTrackingReady) { _, ready in
            if ready {
                trackingTimeoutTask?.cancel()
                trackingTimeoutTask = nil
            }
        }
        .onChange(of: poseEstimator.currentPose?.score?.value) {
            guard poseEstimator.isCalibrated else { return }
            let score = poseEstimator.currentPose?.score
            notificationManager.update(score: score)
            soundCoach.update(score: score)
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
                UIApplication.shared.isIdleTimerDisabled = true
                cameraManager.start()
                startTrackingTimeout()
            case .background, .inactive:
                UIApplication.shared.isIdleTimerDisabled = false
                cameraManager.stop()
                cancelCalibration()
                trackingTimeoutTask?.cancel()
                notificationManager.update(score: nil)
                soundCoach.reset()
            @unknown default:
                break
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
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

                Group {
                    if poseEstimator.isTrackingReady {
                        CalibrateButton(isCalibrated: poseEstimator.isCalibrated,
                                        isActive: isCalibrating) {
                            if isCalibrating {
                                cancelCalibration()
                            } else {
                                startGuidedCalibration()
                            }
                        }
                    } else {
                        TrackingLoadingView(message: "Initializing pose tracking…")
                    }
                }
                .padding(.bottom, 30)
            }
            .rotationEffect(isUpsideDown ? .degrees(180) : .zero)

            if isCalibrating {
                GuidedCalibrationOverlay(
                    instruction: calibrationInstruction,
                    countdown: countdown
                )
                .rotationEffect(isUpsideDown ? .degrees(180) : .zero)
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if showTrackingFailedAlert {
                AlertOverlay(
                    title: "Pose Tracking Unavailable",
                    message: "Apple's pose-detection model couldn't load on this device. Try:\n\n• Free up storage space on your iPhone\n• Force-quit and relaunch Posture Buddy\n• Restart your iPhone",
                    buttonTitle: "OK"
                ) {
                    showTrackingFailedAlert = false
                }
                .rotationEffect(isUpsideDown ? .degrees(180) : .zero)
                .transition(.opacity)
            }
        }
    }

    private func startGuidedCalibration() {
        countdownTask?.cancel()
        calibrationInstruction = "Get ready…"
        countdownTask = Task { @MainActor in
            // Priming: warm up audio pipeline. Awaitable — returns after primeDuration.
            await SoundEffects.prime()
            if Task.isCancelled { cleanupCalibration(); return }

            // Intro
            calibrationInstruction = "Sit up straight"
            await VoiceGuide.shared.say(.letsCalibrate)
            if Task.isCancelled { cleanupCalibration(); return }
            try? await Task.sleep(for: postVoicePause)
            if Task.isCancelled { cleanupCalibration(); return }

            // Capture each of the three positions
            let steps: [(instruction: String, voice: VoicePrompt)] = [
                ("Look at the middle of your screen", .lookMiddle),
                ("Look at the left of your screen", .lookLeft),
                ("Look at the right of your screen", .lookRight),
            ]

            var snapshots: [PostureAngles] = []
            for step in steps {
                calibrationInstruction = step.instruction
                await VoiceGuide.shared.say(step.voice)
                if Task.isCancelled { cleanupCalibration(); return }

                // Small breathing room between the voice line ending and the first tick
                try? await Task.sleep(for: postVoicePause)
                if Task.isCancelled { cleanupCalibration(); return }

                // 3-beat countdown with marimba ticks (3, 2, 1=capture)
                // Tick indices 0 and 1 for beats at count=3, count=2; capture note at count=1
                countdown = 3
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                SoundEffects.playTick(index: 0)

                try? await Task.sleep(for: countdownBeatInterval)
                if Task.isCancelled { cleanupCalibration(); return }
                countdown = 2
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                SoundEffects.playTick(index: 1)

                try? await Task.sleep(for: countdownBeatInterval)
                if Task.isCancelled { cleanupCalibration(); return }
                countdown = 1
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                SoundEffects.playCapture()

                guard let angles = poseEstimator.snapshotCurrentAngles() else {
                    await VoiceGuide.shared.say(.poseNotDetected)
                    cleanupCalibration()
                    return
                }
                snapshots.append(angles)

                // Brief pause on "1" so the capture moment is visible
                try? await Task.sleep(for: captureHoldAfterBeat)
                if Task.isCancelled { cleanupCalibration(); return }
                countdown = nil

                // Let the capture marimba note fully ring out before the next voice line
                try? await Task.sleep(for: postCaptureMarimbaPause)
                if Task.isCancelled { cleanupCalibration(); return }
            }

            // Commit all three and reset the sound coach so fresh calibration starts clean
            poseEstimator.calibrate(middle: snapshots[0], left: snapshots[1], right: snapshots[2])
            soundCoach.reset()

            calibrationInstruction = "Calibration complete"
            await VoiceGuide.shared.say(.calibrationComplete)
            calibrationInstruction = nil
        }
    }

    private func cancelCalibration() {
        countdownTask?.cancel()
        countdownTask = nil
        cleanupCalibration()
    }

    private func cleanupCalibration() {
        VoiceGuide.shared.cancel()
        countdown = nil
        calibrationInstruction = nil
    }

    private func startTrackingTimeout() {
        trackingTimeoutTask?.cancel()
        guard !poseEstimator.isTrackingReady else { return }
        trackingTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(trackingTimeoutSeconds))
            if Task.isCancelled { return }
            if !poseEstimator.isTrackingReady {
                showTrackingFailedAlert = true
            }
        }
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
                .stroke(gradeColor, lineWidth: 7)
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

    private var gradeColor: Color {
        guard let c = score?.grade.color else { return .gray }
        return Color(red: c.red, green: c.green, blue: c.blue)
    }
}

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
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(white: 0.15))
            )
            .padding(24)
        }
    }
}

/// Unified overlay for the guided-calibration flow. Shows:
///   • The current instruction (e.g., "Get ready…", "Look at the middle of your screen")
///   • A large countdown number (3 / 2 / 1) during each per-position hold
struct GuidedCalibrationOverlay: View {
    let instruction: String?
    let countdown: Int?

    var body: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.3))
        .animation(.easeInOut(duration: 0.2), value: countdown)
    }
}

#Preview {
    ContentView()
        .environmentObject(NotificationManager())
}
