//
//  ContentView.swift
//  Posture Buddy
//
//  Created by Aleks Kamko on 4/20/26.
//

import SwiftUI
import UIKit

private extension View {
    func rotatedIfUpsideDown(_ flipped: Bool) -> some View {
        rotationEffect(flipped ? .degrees(180) : .zero)
    }
}

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var poseEstimator = PoseEstimator()
    @StateObject private var soundCoach = PostureSoundCoach()
    @StateObject private var calibration = CalibrationController()
    @EnvironmentObject private var notificationManager: NotificationManager

    @Environment(\.scenePhase) private var scenePhase
    @State private var isUpsideDown: Bool = UIDevice.current.orientation == .portraitUpsideDown
    @State private var trackingTimeoutTask: Task<Void, Never>?
    @State private var showTrackingFailedAlert = false

    // Once calibration completes, shrink the camera surface to a bottom-right
    // corner widget (with a camera icon) and drop the underlying preview layer
    // so `AVCaptureVideoPreviewLayer` stops compositing frames — saves GPU power
    // while the capture session keeps feeding PoseEstimator. Tap the widget to
    // expand back to full-screen; tap the expanded preview to minimize again.
    @State private var videoHidden: Bool = false
    @State private var cameraMinimized: Bool = false
    @State private var videoHideTask: Task<Void, Never>?

    /// Toggles the main on-screen visual between the friendly figure caricature
    /// (false, default) and the live skeleton overlay (true, debug).
    @State private var showDebugOverlay: Bool = false

    /// Hide every UI chrome element (HUD, buttons, camera preview, overlays)
    /// to inspect just the 3D rig. Bottom-left toggle; useful for camera /
    /// pose / bone diagnosis via finger-orbit on the SCNView.
    @State private var hideUI: Bool = false

    // Debug transform state driven by AxisKnob + pan/pinch gestures when
    // `hideUI` is on. `PostureBuddy3DView` only applies these when
    // `debugEnabled` is true, so toggling `hideUI` off snaps the model back
    // to its normal position without losing the values.
    // Seeded with the same isometric default the non-debug path uses so
    // entering Hide-UI doesn't change the view — knobs just start there.
    @State private var modelYaw: Double = PostureBuddy3DView.defaultYawDeg
    @State private var modelPitch: Double = PostureBuddy3DView.defaultPitchDeg
    @State private var modelRoll: Double = PostureBuddy3DView.defaultRollDeg
    @State private var modelScale: Double = 1.0
    @State private var modelScaleAtStart: Double = 1.0
    @State private var modelOffset: CGSize = .zero
    @State private var modelOffsetAtStart: CGSize = .zero

    private let trackingTimeoutSeconds: Double = 45
    private let minimizeStartDelay: Duration = .seconds(3)
    private static let cameraAnimationDuration: Double = 0.6

    /// Dark slate backdrop shown behind the buddy once the camera preview
    /// fades out. Slightly warmer than pure black so the white mascot has a
    /// little tonal separation from the backdrop.
    private static let backdropSlate = Color(red: 36/255, green: 37/255, blue: 43/255)

    var body: some View {
        mainContent
            .animation(.easeInOut(duration: 0.3), value: isUpsideDown)
            .animation(.easeInOut(duration: 0.2), value: calibration.countdown)
            .animation(.easeInOut(duration: 0.2), value: calibration.instruction)
            .animation(.easeInOut(duration: 0.2), value: showTrackingFailedAlert)
            .animation(.easeInOut(duration: Self.cameraAnimationDuration), value: cameraMinimized)
            // Drives PostureBuddy3DView's slouch animation. 0.4s feels natural
            // for body motion (slower than the snappy 0.2s state changes).
            .animation(.easeInOut(duration: 0.4), value: poseEstimator.currentPose?.score?.value)
            .animation(.easeInOut(duration: 0.2), value: showDebugOverlay)
            // Snap mirroring (don't animate the buddy "flipping" through its
            // mid-flip transparent state when calibration commits).
            .animation(nil, value: poseEstimator.dominantEar)
            .task {
                poseEstimator.updateOrientation(UIDevice.current.orientation.visionOrientation)
                await cameraManager.requestAccessAndSetup()
                cameraManager.setSampleBufferDelegate(poseEstimator)
                resumeCapture()
            }
            .onChange(of: poseEstimator.isTrackingReady) { _, ready in
                if ready {
                    trackingTimeoutTask?.cancel()
                    trackingTimeoutTask = nil
                }
            }
            .onChange(of: poseEstimator.isCalibrated) { _, calibrated in
                if calibrated {
                    minimizeCamera(afterDelay: minimizeStartDelay)
                } else {
                    // Recalibration or reset — bring the preview back for the
                    // upcoming calibration flow.
                    expandCamera()
                }
            }
            .onChange(of: poseEstimator.currentPose?.score?.value) {
                guard poseEstimator.isCalibrated else { return }
                // Drop nil scores: the classifier regularly pauses for single frames
                // (face landmarks flicker, yaw crosses the threshold). Forwarding those
                // nils would reset in-flight slouch/recovery timers on every blip,
                // preventing them from ever firing. Long-horizon resets happen
                // explicitly via pauseCapture + calibration.start.
                guard let score = poseEstimator.currentPose?.score else { return }
                notificationManager.update(score: score)
                soundCoach.update(score: score)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                let deviceOrientation = UIDevice.current.orientation
                isUpsideDown = deviceOrientation == .portraitUpsideDown
                poseEstimator.updateOrientation(deviceOrientation.visionOrientation)
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    resumeCapture()
                case .background, .inactive:
                    pauseCapture()
                @unknown default:
                    break
                }
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            Self.backdropSlate.ignoresSafeArea()

            // Buddy (or skeleton overlay) sits beneath the camera surface.
            // The camera covers it at full-screen and reveals it as the camera
            // shrinks to the corner widget.
            if showDebugOverlay {
                PostureOverlayView(detectedPose: poseEstimator.currentPose)
                    .ignoresSafeArea()
                    .rotatedIfUpsideDown(isUpsideDown)
            } else {
                PostureBuddy3DView(
                    score: poseEstimator.currentPose?.score,
                    dominantEar: poseEstimator.dominantEar,
                    debugEnabled: hideUI,
                    yawDeg: modelYaw,
                    pitchDeg: modelPitch,
                    rollDeg: modelRoll,
                    scale: modelScale,
                    translation: modelOffset
                )
                .ignoresSafeArea()
                .rotatedIfUpsideDown(isUpsideDown)
                .gesture(modelDragGesture, including: hideUI ? .gesture : .none)
                .simultaneousGesture(modelPinchGesture, including: hideUI ? .gesture : .none)
            }

            if !hideUI {
                cameraContainer
            }

            if !hideUI {
            VStack {
                HStack {
                    ScoreHUDView(score: poseEstimator.currentPose?.score,
                                 isCalibrated: poseEstimator.isCalibrated)
                        .padding()
                    Spacer()
                }
                Spacer()

                Group {
                    if poseEstimator.isTrackingReady {
                        CalibrateButton(
                            isCalibrated: poseEstimator.isCalibrated,
                            hasSavedBaselines: poseEstimator.hasSavedBaselines,
                            isActive: calibration.isActive
                        ) {
                            if calibration.isActive {
                                calibration.cancel()
                            } else if poseEstimator.hasSavedBaselines && !poseEstimator.isCalibrated {
                                // "Start Tracking" — restored baselines from disk; flip
                                // tracking on without re-running calibration.
                                poseEstimator.startTracking()
                            } else {
                                calibration.start(
                                    poseEstimator: poseEstimator,
                                    soundCoach: soundCoach,
                                    notificationManager: notificationManager
                                )
                            }
                        }
                    } else {
                        TrackingLoadingView(message: "Initializing pose tracking…")
                    }
                }
                // Small gap below the calibrate button before the Debug toggle.
                // The Debug button itself carries the rest of the bottom-clearance
                // (so the prop / bezel doesn't occlude either button).
                .padding(.bottom, 12)

                // Debug toggle — outside the `isTrackingReady` Group so it's
                // always available (useful for previewing the figure before
                // pose tracking has warmed up).
                Button { showDebugOverlay.toggle() } label: {
                    Text(showDebugOverlay ? "Hide Debug" : "Debug")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().stroke(.white.opacity(0.4), lineWidth: 1))
                }
                .padding(.bottom, 100)
            }
            .rotatedIfUpsideDown(isUpsideDown)
            }

            if calibration.isActive && !hideUI {
                GuidedCalibrationOverlay(
                    instruction: calibration.instruction,
                    countdown: calibration.countdown
                )
                .rotatedIfUpsideDown(isUpsideDown)
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if showTrackingFailedAlert && !hideUI {
                AlertOverlay(
                    title: "Pose Tracking Unavailable",
                    message: "Apple's pose-detection model couldn't load on this device. Try:\n\n• Free up storage space on your iPhone\n• Force-quit and relaunch Posture Buddy\n• Restart your iPhone",
                    buttonTitle: "OK"
                ) {
                    showTrackingFailedAlert = false
                }
                .rotatedIfUpsideDown(isUpsideDown)
                .transition(.opacity)
            }

            // Always-visible Hide/Show UI toggle. Stays on top so we can get
            // the chrome back when we're done inspecting the rig.
            VStack {
                Spacer()
                HStack {
                    Button { hideUI.toggle() } label: {
                        Text(hideUI ? "Show UI" : "Hide UI")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(.black.opacity(0.4)))
                            .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 1))
                    }
                    .padding(.leading, 20)
                    .padding(.bottom, 100)
                    Spacer()
                }
            }
            .rotatedIfUpsideDown(isUpsideDown)

            // Debug axis knobs shown in Hide-UI mode. Press-and-drag each knob
            // vertically to spin that axis; Reset zeroes all five transforms.
            if hideUI {
                VStack {
                    Spacer()
                    HStack(spacing: 14) {
                        Spacer()
                        AxisKnob(label: "Y", value: $modelYaw,   accent: .cyan)
                        AxisKnob(label: "P", value: $modelPitch, accent: .yellow)
                        AxisKnob(label: "R", value: $modelRoll,  accent: .pink)
                        Button {
                            modelYaw = PostureBuddy3DView.defaultYawDeg
                            modelPitch = PostureBuddy3DView.defaultPitchDeg
                            modelRoll = PostureBuddy3DView.defaultRollDeg
                            modelScale = 1.0; modelScaleAtStart = 1.0
                            modelOffset = .zero; modelOffsetAtStart = .zero
                        } label: {
                            Text("Reset")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(.black.opacity(0.55)))
                                .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
                        }
                        .padding(.trailing, 20)
                    }
                    .padding(.bottom, 100)
                }
                .rotatedIfUpsideDown(isUpsideDown)
            }
        }
    }

    /// One-finger drag on the 3D view translates the model in screen X/Y while
    /// `hideUI` is on. Captures the offset at drag-start so repeated strokes
    /// accumulate instead of snapping back.
    private var modelDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                modelOffset = CGSize(
                    width:  modelOffsetAtStart.width  + g.translation.width,
                    height: modelOffsetAtStart.height + g.translation.height
                )
            }
            .onEnded { _ in modelOffsetAtStart = modelOffset }
    }

    /// Pinch-to-scale the model while `hideUI` is on. Multiplied against the
    /// start value for continuous scaling across multiple pinches.
    private var modelPinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { m in modelScale = max(0.2, modelScaleAtStart * m) }
            .onEnded   { _ in modelScaleAtStart = modelScale }
    }

    /// Camera surface: full-screen preview at `cameraMinimized == false`,
    /// literally scaled down to a bottom-right corner widget when minimized.
    /// Uses `.scaleEffect` + `.offset` (not `.frame` + `.position`) so the
    /// scale transform goes directly onto the view's backing layer — which
    /// IS the `AVCaptureVideoPreviewLayer` — and CoreAnimation interpolates
    /// it smoothly. `.frame` animation on a `UIViewRepresentable` only
    /// translates / masks the preview during the transition; the video
    /// content itself doesn't resize until the animation completes. Uniform
    /// scaling also keeps the corner widget at the screen's aspect ratio
    /// automatically (no separate height math).
    @ViewBuilder
    private var cameraContainer: some View {
        GeometryReader { geo in
            let fullW = geo.size.width
            let fullH = geo.size.height
            let minWidth: CGFloat = 80
            let scale: CGFloat = cameraMinimized ? minWidth / fullW : 1.0
            let safeScale = max(scale, 0.001)   // counter-scale divisor

            let cornerInsetX: CGFloat = 20
            let cornerInsetY: CGFloat = 100    // matches Hide UI / Debug button stack height

            // `scaleEffect`'s `anchor` is the point on the view that stays
            // fixed during scaling. Bottom-right anchor shrinks toward the
            // bottom-right of the full-screen frame; we then offset inward by
            // the inset to leave a margin. Upside-down: anchor the opposite
            // corner so the widget ends up at the user's visual bottom-right
            // either way (the camera-icon overlay is also counter-rotated).
            let anchor: UnitPoint = isUpsideDown ? .topLeading : .bottomTrailing
            let offsetX: CGFloat = !cameraMinimized ? 0
                : (isUpsideDown ? cornerInsetX : -cornerInsetX)
            let offsetY: CGFloat = !cameraMinimized ? 0
                : (isUpsideDown ? cornerInsetY : -cornerInsetY)

            // Corner radius + stroke live in the PRE-scale coordinate space,
            // so they get scaled along with the preview content. Pre-scale
            // radius 70 lands at ~14pt visible when minimized; pre-scale
            // stroke 5 lands at ~1pt visible. Both are 0 / invisible at full-
            // screen so the preview fills edge-to-edge.
            let preRadius: CGFloat = cameraMinimized ? 70 : 0
            let preStrokeWidth: CGFloat = 5

            ZStack {
                if !videoHidden {
                    CameraPreviewView(session: cameraManager.session)
                } else {
                    Self.backdropSlate
                }

                // Icon overlay. Counter-scaled by 1/scale so the icon reads at
                // a constant ~28pt visually regardless of the outer scale. The
                // slate mat makes the icon readable even during the single
                // frame where preview + slate are both rendered (before
                // `videoHidden = true` fires post-animation).
                ZStack {
                    Self.backdropSlate
                    Image(systemName: "video.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .scaleEffect(1 / safeScale)
                        .rotationEffect(isUpsideDown ? .degrees(180) : .zero)
                }
                .opacity(cameraMinimized ? 1 : 0)
            }
            .frame(width: fullW, height: fullH)
            .clipShape(RoundedRectangle(cornerRadius: preRadius))
            .overlay(
                RoundedRectangle(cornerRadius: preRadius)
                    .stroke(.white.opacity(cameraMinimized ? 0.35 : 0),
                            lineWidth: preStrokeWidth)
            )
            .scaleEffect(scale, anchor: anchor)
            .offset(x: offsetX, y: offsetY)
            .contentShape(Rectangle())
            .onTapGesture { toggleCameraIfAllowed() }
        }
        .ignoresSafeArea()
    }

    /// Toggle the camera surface state. Only meaningful once we have baselines
    /// to show something underneath, and never mid-calibration where the
    /// GuidedCalibrationOverlay is the subject of the screen.
    private func toggleCameraIfAllowed() {
        guard poseEstimator.isCalibrated, !calibration.isActive else { return }
        if cameraMinimized {
            expandCamera()
        } else {
            minimizeCamera(afterDelay: .zero)
        }
    }

    /// Animates the camera surface from full-screen down to the corner widget,
    /// then tears down the `CameraPreviewView` to save GPU. `afterDelay` is 0
    /// for manual tap; the post-calibration auto-flow uses `minimizeStartDelay`.
    private func minimizeCamera(afterDelay: Duration) {
        videoHideTask?.cancel()
        videoHideTask = Task { @MainActor in
            if afterDelay > .zero {
                try? await Task.sleep(for: afterDelay)
                if Task.isCancelled { return }
            }
            cameraMinimized = true
            // Wait out the shrink animation before dropping the preview layer
            // so the user sees it smoothly shrink (no pop-to-icon mid-way).
            try? await Task.sleep(for: .seconds(Self.cameraAnimationDuration + 0.15))
            if Task.isCancelled { return }
            videoHidden = true
        }
    }

    /// Re-adds the preview layer and animates the widget back to full-screen.
    /// Setting `videoHidden = false` first ensures the user sees live frames
    /// during the grow animation, not slate.
    private func expandCamera() {
        videoHideTask?.cancel()
        videoHidden = false
        cameraMinimized = false
    }

    /// Resumes or starts camera capture: keeps the screen awake, starts the capture
    /// session, and arms the tracking-load timeout.
    private func resumeCapture() {
        UIApplication.shared.isIdleTimerDisabled = true
        cameraManager.start()
        startTrackingTimeout()
    }

    /// Mirror of `resumeCapture` for when the app backgrounds: stops capture and
    /// unwinds any in-progress coaching / calibration state.
    private func pauseCapture() {
        UIApplication.shared.isIdleTimerDisabled = false
        cameraManager.stop()
        calibration.cancel()
        trackingTimeoutTask?.cancel()
        notificationManager.update(score: nil)
        soundCoach.reset()
    }

    private func startTrackingTimeout() {
        trackingTimeoutTask?.cancel()
        guard !poseEstimator.isTrackingReady else { return }
        trackingTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(trackingTimeoutSeconds))
            } catch {
                return  // cancelled before timeout elapsed
            }
            if !poseEstimator.isTrackingReady {
                showTrackingFailedAlert = true
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(NotificationManager())
}
