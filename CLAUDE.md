# Posture Buddy

iOS app that monitors sitting posture in real time using the front camera. The user props their phone in **portrait** mode to the side of themselves while working at a desk; the app watches their side profile, scores posture, and vibrates/alerts after sustained poor posture.

## Core Design Decisions

### Pose estimation: 2D only
- Uses **`VNDetectHumanBodyPoseRequest`** (2D), not 3D.
- The **3D variant (`VNDetectHumanBodyPose3DRequest` / `DetectHumanBodyPose3DRequest`) is broken on iOS 26** — fails with `Error Domain=com.apple.Vision Code=9 "Unable to run HumanBodyPose3D pipeline"` and `Could not create mlImage buffer of type kCVPixelFormatType_32BGRA`. Both the `VN`-prefixed and Swift-native API fail. Do not reintroduce it without testing on a current iOS version.
  - This is likely broken because the camera will typically not capture all of the user's joints when propped up on the desk, since the desk occludes the bottom half of the body. In other workds, we usually only see the top half of the body.

### Scoring: calibration-based, not absolute
- 2D pose can't tell the difference between "bad posture" and "weird camera angle" — if the camera is below or off-axis, a good posture looks like forward-head from the camera's perspective.
- Solution: user taps **Set Baseline Posture**, app snapshots the ear-shoulder (and shoulder-hip, if hip is visible) angles as the baseline. Future scores measure **deviation from baseline**, not deviation from a theoretical ideal.
- Side-profile scoring only uses **same-side joints** (ear→shoulder→hip). Centerline joints (nose, neck, root) are anatomically offset from the visible shoulder and produce non-zero angles even in perfect posture, so they're not used for scoring.
- Hip often isn't visible (desk occludes it); scoring falls back to ear-shoulder alone when that's the case.

### Orientation: portrait + portrait-upside-down
- Supported orientations (Info.plist-equivalent in `project.pbxproj`): `UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown`.
- **iOS's native portrait-upside-down rotation is unreliable on iPhone.** Setting the `AppDelegate` `supportedInterfaceOrientationsFor:` returning both doesn't actually rotate the UI.
- Instead, we **manually flip the UI** with `.rotationEffect(.degrees(180))` when we detect `UIDeviceOrientation.portraitUpsideDown` (via `UIDevice.current.beginGeneratingDeviceOrientationNotifications()` + `orientationDidChangeNotification`).
- The **`CameraPreviewView` is NOT rotated** — `AVCaptureVideoPreviewLayer` handles its own orientation internally; double-rotating it shows the user upside-down in the preview.
- Vision orientation hint is flipped: front-camera-portrait = `.leftMirrored`, upside-down = `.rightMirrored`.
- **Native SwiftUI `.alert` uses the system interface orientation and won't respect manual rotation** — use the custom `AlertOverlay` component inside the rotated ZStack instead.

### Concurrency: MainActor default isolation
- Project uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — every class is implicitly `@MainActor`.
- `AVCaptureVideoDataOutputSampleBufferDelegate.captureOutput` MUST be marked `nonisolated` or frames get dispatched to main, defeating the background video queue and blocking the UI.
- Shared background state (orientation, last-processed-time, smoothed score, current angles, baseline) is protected with `OSAllocatedUnfairLock`.
- Static `let` constants used from `nonisolated` methods must be explicitly `nonisolated static let`.

### Audio: synthesized marimba-like tones
- No bundled sound files. `SoundEffects.swift` generates tones at runtime using `AVAudioEngine` + `AVAudioPCMBuffer` + a simple additive synthesis (fundamental + octave + fast-decaying inharmonic "clink").
- **Countdown melody**: F4 → G4 → A4 → B4 → C5 (top half of C major resolving on C5). 5 beats total; the 5th beat (at count=1 on screen) is the capture moment.
- Tone buffers are **pre-generated on a background queue at startup** — never synthesize on the main thread at play time.
- Before each countdown, we **prime the audio pipeline** with a 1-second silent buffer (showing a "Get ready…" spinner) so the render thread is hot before the first tone. An earlier approach of continuous silence loop was removed to save battery.
- Audio session: `.playback` category with `.mixWithOthers` — plays even when the silent switch is on; doesn't interrupt background audio.
- **Must set `AVCaptureSession.automaticallyConfiguresApplicationAudioSession = false`** in `CameraManager` — otherwise the camera session disrupts our audio session on start, causing first-tone glitches.
- Audio format matches the **hardware sample rate** (queried via `AVAudioSession.sharedInstance().sampleRate`, typically 48kHz) to avoid real-time resampling on the audio thread. Preferred IO buffer duration is 40ms (vs ~23ms default) for CPU-spike tolerance.

### ANE / pose-model resilience
- Apple's pose model (`cnn_human_pose.espresso.net`) ships with iOS but each new app process must re-load the weights from disk into the ANE. There's no way to persist the loaded model across app launches.
- **Do not run a "warmup" Vision inference concurrently with the camera pipeline.** Tried this with `Task.detached { poseEstimator.warmUp() }` that ran a dummy inference on a blank 256×256 buffer; result was the ANE serializing warmup and real-frame inferences, slowing the whole app to a crawl. Accept the ~1-2 second cold-start on first frame instead.
- Apple's pose model occasionally fails to load onto the Neural Engine with errors like `ANECF error: failed to load ANE model ... Cannot open additional blob file`. Usually fixed by restarting the iPhone or freeing storage.
- If no valid pose observation is received within **20 seconds** of the camera starting, the app shows an `AlertOverlay` telling the user to free space / reboot / force-quit.

## File Layout

```
Posture Buddy/
├── Posture_BuddyApp.swift       App entry. Creates NotificationManager, configures audio session
├── ContentView.swift            Root view; wires camera + pose + overlay + HUD + calibration UI
├── CameraManager.swift          AVCaptureSession owner (front camera, BGRA, no audio session touch)
├── CameraPreviewView.swift      UIViewRepresentable wrapping AVCaptureVideoPreviewLayer
├── PoseEstimator.swift          Runs VNDetectHumanBodyPoseRequest on videoQueue; publishes DetectedPose
├── PostureAnalyzer.swift        Pure math: picks best side, computes angles, scores vs baseline
├── PostureOverlayView.swift     SwiftUI Canvas drawing the skeleton on top of the camera preview
├── NotificationManager.swift    Tracks poor-posture duration; fires haptic + local notification
└── SoundEffects.swift           Synthesized marimba tones for countdown + capture
```

## Data Flow

```
AVCaptureSession (front camera, BGRA)
    │  CMSampleBuffer on videoQueue
    ▼
PoseEstimator.captureOutput (nonisolated, 10 FPS throttled)
    │  VNDetectHumanBodyPoseRequest → VNHumanBodyPoseObservation
    │  PostureAnalyzer.computeAngles → PostureAngles
    │  PostureAnalyzer.score(current, baseline) → PostureScore  (only if calibrated)
    │  exponential smoothing (0.8*prev + 0.2*new)
    ▼  Task { @MainActor } publishes DetectedPose
ContentView
    ├── CameraPreviewView        (bottom layer, not rotated)
    ├── PostureOverlayView       (Canvas, rotated with UI)
    ├── ScoreHUDView             (108pt circle, color-coded score)
    ├── CalibrateButton / TrackingLoadingView / PrimingOverlay / CountdownOverlay / AlertOverlay
    └── NotificationManager.update (only after calibration)
```

## Permissions & Build Settings

- **`INFOPLIST_KEY_NSCameraUsageDescription`** is set in both Debug and Release in `project.pbxproj`.
- **`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown"`**.
- **Bundle ID**: `akamko.Posture-Buddy`. Team: `ZC95DNC67Z`.
- **Deployment target**: iOS 26.4.

## Dev Workflow

- **Build via Xcode MCP** (`BuildProject` action) — gives structured error output.
- **Launch on device with `./run.sh`** — uses `osascript` to send Cmd+R to Xcode. Requires Accessibility permission for `osascript` (first run prompts; granted via System Settings → Privacy & Security → Accessibility).
- The `run.sh` script is at the project root; chmod +x'd.
- Must test on a **physical device** — the Simulator has no camera.
- **SourceKit diagnostics frequently show stale false positives** (e.g., "No such module 'UIKit'", "'AVAudioSession' is unavailable in macOS", "Cannot find type X"). If `BuildProject` returns success, the build is good — ignore stale SourceKit errors.

## Gotchas Discovered

- **CMSampleBuffer race on startup**: `requestAccessAndSetup()` must await the `videoQueue.async` block (via `withCheckedContinuation`), otherwise `setSampleBufferDelegate` fires before `videoOutput` exists and frames are never delivered.
- **`FigCaptureSourceRemote err=-17281`** and similar Fig/VTEST/Espresso console errors on camera startup are usually benign — they fire during session negotiation and stop after the first valid frame.
- **"Frame received" spam**: log throttling (2-second interval) is important; pose estimation at 10 FPS can easily flood the console.
- **Tone pitch-shifting with `AVAudioPlayer.rate`** changes duration too — not used; we synthesize each pitch separately.
- **Idle timer**: `UIApplication.shared.isIdleTimerDisabled = true` when the scene is active, `false` when backgrounded, so the screen doesn't sleep during use.
