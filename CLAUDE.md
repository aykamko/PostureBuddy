# Posture Buddy

iOS app that monitors sitting posture in real time using the front camera. The user props their phone in **portrait** mode to the side of themselves while working at a desk; the app watches their side profile, scores posture, and vibrates/alerts after sustained poor posture.

## Core Design Decisions

### Pose estimation: 2D only
- Uses **`VNDetectHumanBodyPoseRequest`** (2D), not 3D.
- The **3D variant (`VNDetectHumanBodyPose3DRequest` / `DetectHumanBodyPose3DRequest`) is broken on iOS 26** — fails with `Error Domain=com.apple.Vision Code=9 "Unable to run HumanBodyPose3D pipeline"` and `Could not create mlImage buffer of type kCVPixelFormatType_32BGRA`. Both the `VN`-prefixed and Swift-native API fail. Do not reintroduce it without testing on a current iOS version.
  - This is likely broken because the camera will typically not capture all of the user's joints when propped up on the desk, since the desk occludes the bottom half of the body. In other workds, we usually only see the top half of the body.

### Scoring: 3-position calibration + head-yaw-aware classification
- 2D pose can't separate "bad posture" from "weird camera angle" or "head turned". Rotating your head ~30° toward the screen shifts the ear's 2D position enough to tank the score even with perfect torso posture.
- Solution: guided calibration at **three head positions** — middle, left, right edge of screen. Each baseline captures `earShoulderAngle`, `shoulderHipAngle?`, and a 2-component `YawSignature` (see below).
- At runtime: the current frame's `YawSignature` is matched to the closest baseline by **2D Euclidean distance**; scoring is done against that baseline's angles. If the closest distance is more than `yawClassificationThreshold` (0.2 currently) from all three baselines (head turned too far, looking up/down, etc.), or if no face was detected at all, we return **nil** from the analyzer and **pause scoring** rather than produce a misleading number.
- Side-profile scoring uses **same-side joints** (ear→shoulder→hip). Centerline joints (nose, neck, root) are anatomically offset from the visible shoulder and produce non-zero angles even in perfect posture, so they're not used for the score itself.
- Hip often isn't visible (desk occludes it); scoring falls back to ear-shoulder alone when that's the case.

### Head-yaw classification: 2-component signature
Yaw in our side-profile setup isn't one-dimensional. A single scalar (direction or frontality alone) collapses "clean side profile" and "3/4 view toward camera" into the same value because they're near the same bbox-midline offset. `YawSignature` is a pair of features:

- **`direction`** (~[-0.5, +0.5]): face median-line x-offset within the bbox, computed as `mean(medianLine.normalizedPoints.x) - 0.5`. Falls back to `noseCrest` if `medianLine` isn't populated. Captures left/right head rotation.
- **`frontality`** ([0, 1]): `min(leftEar.confidence, rightEar.confidence) / max(...)` from the body-pose model. Near 0 = deep profile (only one ear visible), near 1 = head turned toward camera enough that both ears are detected. Captures how much of the face is visible — the critical signal that separates positions that share a direction.

Classification uses `YawSignature.distance(to:)` (plain Euclidean). Baselines and thresholds live in an unnormalized space; if in practice one axis dominates because its variance swamps the other, weight/scale one side before adding.

### Head-yaw detection: VNDetectFaceLandmarksRequest
- Runs alongside `VNDetectHumanBodyPoseRequest` per frame. Face landmarks provide the `direction` component; body-pose ear confidences provide `frontality`. Both are packed into a `YawSignature` in `PoseEstimator.captureOutput`.
- **Do NOT use `VNFaceObservation.yaw` directly.** Despite Apple's docs claiming revision 3+ gives continuous values, in practice `yaw` is still quantized to 45° buckets (-π/4, -π/2, etc.) for side-profile faces on iOS 26. Observed: "middle" and "right" calibration positions both returned exactly -0.785 rad (-45°), making them indistinguishable. The quantization makes `yaw` unusable for 3-position classification.
- Revision is still set to `currentRevision` for landmark detection itself; we just don't read the `yaw` property anymore.
- Face landmarks are also rendered on the overlay as **cyan** dots + bounding box for debugging — distinguishable from the white body keypoints. See `PostureOverlayView.swift`.
- Landmark points are in `VNFaceLandmarkRegion2D.normalizedPoints`, which are *bounding-box-local* (0-1 within the face rect). `extractFaceLandmarks(from:)` converts them to image-normalized coords so they share the skeleton's coordinate system (needed for drawing, not for the yaw `direction` signal which uses bbox-local coords).

### Guided calibration flow
- Triggered by **Set Baseline Posture** (or Recalibrate). Uses pre-recorded voice + marimba countdown:
  1. Audio pipeline prime (1s silent buffer) + "Get ready…" spinner
  2. Voice: *"Let's calibrate. Please sit up straight."*
  3. For middle / left / right:
     - Voice: *"First, look at the middle of your screen."* → *"Next, look at the left of your screen."* → *"Last, look at the right of your screen."*
     - 3-beat marimba countdown (3, 2, 1) with tick + capture sounds
     - Snapshot `PostureAngles` at count=1
  4. Voice: *"Calibration is complete."*
- Cancel button (the calibrate button goes red during calibration) stops voice, cancels the task, and reverts — previous baselines stay intact.
- If `snapshotCurrentAngles()` returns nil at any capture moment (no valid pose), the flow aborts with *"Couldn't detect your pose. Please try again."*

### Voice guidance — pre-recorded, not TTS
- Originally used `AVSpeechSynthesizer`, but iOS default TTS voices sound robotic and premium voices require per-user downloads from Settings → Accessibility. Apple also walls off Siri's voice from third-party apps entirely (Siri voice downloads are not exposed via `AVSpeechSynthesisVoice.speechVoices()` or the `say` command).
- Solution: ship **pre-recorded `.aiff` files** in the bundle, one per prompt. `VoiceGuide.shared.say(_: VoicePrompt)` plays the matching file via `AVAudioPlayer` (delegate callback resumes a `CheckedContinuation` when done).
- Recordings were generated with **ElevenLabs** (Clara voice). Raw clips are stored outside the bundle at `voice-samples/` (ignored by Xcode); the chopped segments live in `Posture Buddy/VoicePrompts/` and are auto-included via the file-system-synchronized group.
- `VoicePrompt` is a `String`-backed `CaseIterable` enum whose raw values match the filenames (e.g., `.lookMiddle` → `look_middle.aiff`).
- Players are lazily loaded and cached on first use; subsequent plays are instant.

### Re-recording the voice prompts
The script:
```
Let's calibrate. Please sit up straight.        → lets_calibrate.aiff
First, look at the middle of your screen.       → look_middle.aiff
Next, look at the left of your screen.          → look_left.aiff
Last, look at the right of your screen.         → look_right.aiff
Calibration is complete.                        → calibration_complete.aiff
Couldn't detect your pose. Please try again.    → pose_not_detected.aiff
```

Workflow:
1. Paste the script into ElevenLabs and export as one mp3 (or chop each line separately in ElevenLabs for better per-phrase intonation — the hand-chopped files ended up sounding more natural than auto-chopped).
2. If auto-chopping a single mp3: `ffmpeg -i in.mp3 -af silencedetect=noise=-35dB:d=0.4 -f null -` to find silence boundaries, then split with `ffmpeg -ss START -to END -i in.mp3 -c:a pcm_s16be out.aiff`.
3. Otherwise convert each mp3 to aiff: `ffmpeg -i in.mp3 -c:a pcm_s16be out.aiff`.
4. Replace files in `Posture Buddy/VoicePrompts/`. Filenames must match `VoicePrompt.rawValue` exactly.

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
├── PostureSoundCoach.swift      Short-horizon (5s) grade-transition sounds (descending on slouch, ascending on recovery)
├── VoiceGuide.swift             Plays bundled .aiff prompts via AVAudioPlayer; keyed by VoicePrompt enum
├── VoicePrompts/                Bundled pre-recorded calibration audio (ElevenLabs "Clara")
│   ├── lets_calibrate.aiff
│   ├── look_middle.aiff
│   ├── look_left.aiff
│   ├── look_right.aiff
│   ├── calibration_complete.aiff
│   └── pose_not_detected.aiff
└── SoundEffects.swift           Synthesized marimba tones + beep pairs for calibration and coaching
```

## Data Flow

```
AVCaptureSession (front camera, BGRA)
    │  CMSampleBuffer on videoQueue
    ▼
PoseEstimator.captureOutput (nonisolated, 10 FPS throttled)
    │  VNDetectHumanBodyPoseRequest → VNHumanBodyPoseObservation (body keypoints + ear confidences)
    │  VNDetectFaceLandmarksRequest → VNFaceObservation (medianLine landmarks, ignore .yaw)
    │  → YawSignature(direction: medianLine offset, frontality: ear-confidence ratio)
    │  PostureAnalyzer.computeAngles(observation, yawSignature:) → PostureAngles
    │  PostureAnalyzer.score(current, baselines) → (PostureScore, position)?  (only if calibrated AND 2D yaw distance < threshold)
    │  exponential smoothing (0.8*prev + 0.2*new)
    ▼  Task { @MainActor } publishes DetectedPose (keypoints + faceLandmarks + score)
ContentView
    ├── CameraPreviewView        (bottom layer, not rotated)
    ├── PostureOverlayView       (Canvas, rotated with UI — body in white, face landmarks in cyan)
    ├── ScoreHUDView             (108pt circle, color-coded score)
    ├── CalibrateButton / TrackingLoadingView / GuidedCalibrationOverlay / AlertOverlay
    └── NotificationManager.update + PostureSoundCoach.update (only after calibration)
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
- **`VNFaceObservation.yaw` is quantized to 45° even at revision 3+ in practice.** Despite Apple's docs. For continuous yaw on iOS 26, don't use the property — compute your own proxy from landmark geometry (`medianLine` offset within bbox is clean).
- **Single-axis yaw isn't enough.** Side-profile ("center") and 3/4 view can collapse to nearly the same median-line offset because the midline is near the bbox edge in both. Need a second axis (frontality = ear-confidence ratio) to separate them.
- **Face landmarks are in bounding-box-local coords**, not image-normalized. `VNFaceLandmarkRegion2D.normalizedPoints` ranges 0-1 within the face rect — you have to transform by `bbox.origin + p * bbox.size` to get image-space coordinates that match what the body pose model returns. For a yaw signal that's bbox-invariant, you can use normalized points directly without converting.
