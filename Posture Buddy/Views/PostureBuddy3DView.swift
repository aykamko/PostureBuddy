import SwiftUI
import SceneKit
import simd

/// 3D SceneKit version of the Posture Buddy mascot. Loads `stickman.usdz` once
/// at view creation, caches the `Head` bone + its rest orientation, and rotates
/// it from the posture score to drive forward-head-posture animation.
///
/// - SwiftUI's implicit `.animation(_:value:)` doesn't propagate into
///   `UIViewRepresentable.updateUIView` changes on a SceneKit node, so we
///   explicitly wrap bone transforms in an `SCNTransaction` with a duration
///   to get the smooth interpolation.
/// - Mirroring for `dominantEar` is done by rotating the rig's container node
///   180° around the up axis (view from the other side) rather than by flipping
///   scale, which would invert winding order + lighting.
struct PostureBuddy3DView: UIViewRepresentable {
    let score: PostureScore?
    let dominantEar: EarSide?

    // Debug transform overrides — active only when `debugEnabled` is true
    // (`Hide UI` mode in ContentView). Let us rotate / translate / scale the
    // model via on-screen knobs + drag + pinch gestures without perturbing
    // the default score-driven visual.
    var debugEnabled: Bool = false
    var yawDeg: Double = 0
    var pitchDeg: Double = 0
    var rollDeg: Double = 0
    var scale: Double = 1.0
    var translation: CGSize = .zero

    /// Output: where (in the SCNView's local point coords) the top of the
    /// buddy's head currently projects on screen. ContentView reads this to
    /// anchor the score bubble's tail to the head. Throttled to ~20 Hz inside
    /// the Coordinator so SwiftUI doesn't re-evaluate the body 60×/sec.
    var headScreenPosition: Binding<CGPoint?>? = nil

    /// Container's base (mirror-off) scale factor. Referenced by the debug
    /// transform path so "scale × 1.0" matches normal framing. Tuned for the
    /// current `stickman.usdz` export (bounds ~1.8w × 2.3h × 1.2d pre-scale).
    private static let baseScale: Float = 0.7

    /// Model-space units per point of drag translation. Tuned so drag follows
    /// the finger at roughly 1:1 on-screen when the figure is centered.
    private static let translationScale: Float = 0.004

    /// Default viewing orientation for the buddy + chair — a 3/4 isometric-ish
    /// angle chosen in Hide-UI debug mode and baked in here. Applied on top of
    /// the ear-based mirror rotation so left/right mirroring still works.
    /// `internal` (not private) so ContentView can seed the Hide-UI knobs to
    /// these same values — Hide-UI then starts at the same view, not at zero.
    static let defaultYawDeg: Double = -136
    static let defaultPitchDeg: Double = -18
    static let defaultRollDeg: Double = 11

    /// The world point the camera looks at. Used both to set up the camera in
    /// `makeScene` and as the auto-center target for the buddyContainer (so
    /// the rotated bounding-box midpoint lands here every frame).
    private static let cameraLookAt = SIMD3<Float>(0, 0.3, 0.1)

    /// Extra fixed offset applied to the auto-centered buddy position, in
    /// world units. -Z is screen-right with the current camera. Use a small
    /// negative value to nudge the figure off-center toward the right edge.
    private static let viewOffset = SIMD3<Float>(0, -0.2, -0.09)

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
        // Custom gestures are handled at the SwiftUI layer; SceneKit's built-in
        // camera control would fight them.
        view.allowsCameraControl = false
        // We need every-frame ticks to ease sceneTime toward its target in
        // the Coordinator's renderer delegate (smooths score-driven slouch).
        view.rendersContinuously = true
        view.delegate = context.coordinator

        if let scene = Self.makeScene() {
            view.scene = scene
            Self.cacheDriveNodes(scene: scene, into: context.coordinator)
            Self.dumpHierarchyOnce(scene: scene)
        }
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        // Posture score → animation scrub TARGET. The Coordinator's renderer
        // delegate eases the actual `view.sceneTime` toward this target each
        // frame; setting it directly here would jump on every score update.
        let ratio = Self.slouchRatio(for: score)
        context.coordinator.targetSceneTime = ratio * context.coordinator.animationDuration
        // Re-bind every update so SwiftUI re-creating the view doesn't strand
        // the Coordinator with a stale binding.
        context.coordinator.headScreenBinding = headScreenPosition

        // Mirror + debug transform: instant. The mirror flip is visually snappy
        // (CLAUDE.md: "instant flip, otherwise the mirror crossfade is
        // unsightly"), and the debug knobs need 1:1 follow-the-finger feel.
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        if let flipNode = context.coordinator.flipNode {
            let mirrorAngle: Float = dominantEar == .left ? .pi : 0
            let mirrorRot = simd_quatf(angle: mirrorAngle, axis: [0, 1, 0])

            // Build the user-facing rotation. Debug mode uses the live knobs;
            // otherwise we use the baked default 3/4 isometric.
            let userRot: simd_quatf
            if debugEnabled {
                let yaw = Float(yawDeg) * .pi / 180
                let pitch = Float(pitchDeg) * .pi / 180
                let roll = Float(rollDeg) * .pi / 180
                userRot = simd_quatf(angle: yaw,   axis: [0, 1, 0])
                        * simd_quatf(angle: pitch, axis: [1, 0, 0])
                        * simd_quatf(angle: roll,  axis: [0, 0, 1])
            } else {
                let yaw   = Float(Self.defaultYawDeg)   * .pi / 180
                let pitch = Float(Self.defaultPitchDeg) * .pi / 180
                let roll  = Float(Self.defaultRollDeg)  * .pi / 180
                userRot = simd_quatf(angle: yaw,   axis: [0, 1, 0])
                        * simd_quatf(angle: pitch, axis: [1, 0, 0])
                        * simd_quatf(angle: roll,  axis: [0, 0, 1])
            }

            let totalRot = context.coordinator.flipRest * userRot * mirrorRot
            let scaleVal = Self.baseScale * (debugEnabled ? Float(scale) : 1.0)

            flipNode.simdOrientation = totalRot
            flipNode.simdScale = SIMD3(repeating: scaleVal)

            // Auto-center the figure on the camera's look-at by computing the
            // rotated bounding-box center and offsetting position to land it
            // there. The local boundingBox doesn't change as the rig animates
            // significantly, but we recompute every update so slouch + chair
            // stay properly framed.
            let (lmin, lmax) = flipNode.boundingBox
            let localCenter = SIMD3<Float>(
                Float(lmin.x + lmax.x) * 0.5,
                Float(lmin.y + lmax.y) * 0.5,
                Float(lmin.z + lmax.z) * 0.5
            )
            let scaledCenter = SIMD3<Float>(repeating: scaleVal) * localCenter
            let rotatedCenter = totalRot.act(scaledCenter)
            let autoCenter = Self.cameraLookAt + Self.viewOffset - rotatedCenter

            if debugEnabled {
                let dragOffset = SIMD3<Float>(
                    Float(translation.width)  *  Self.translationScale,
                    Float(translation.height) * -Self.translationScale,
                    0
                )
                flipNode.simdPosition = autoCenter + dragOffset
            } else {
                flipNode.simdPosition = autoCenter
            }
        }
        SCNTransaction.commit()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Coordinator doubles as the SCNView delegate so we can smoothly chase a
    /// target sceneTime each render frame, instead of slamming sceneTime to a
    /// new value every time SwiftUI re-runs `updateUIView` (which fires on
    /// step-wise ~10 Hz score updates and reads as choppy).
    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        /// Longest duration across all skeletal animations found at load time.
        /// sceneTime ∈ [0, animationDuration] scrubs the slouch clip.
        var animationDuration: TimeInterval = 0
        /// The scene-tree ancestor we rotate 180° around when mirroring.
        var flipNode: SCNNode?
        var flipRest = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        /// Material on the HeadMesh (peeled off of BodyMesh in the Blender
        /// export so it can be tinted independently of the rest of the body).
        var headMaterial: SCNMaterial?

        /// sceneTime we're easing toward (set in updateUIView from score).
        var targetSceneTime: TimeInterval = 0
        /// Render-loop tick from the previous callback for dt.
        var lastTick: TimeInterval = 0
        /// Rate constant in 1/seconds. ~5 reaches 80% of target in ~0.32 s,
        /// matching the ease feel of the body-level animation modifiers.
        let smoothingRate: Double = 5.0

        /// Head BONE — we project its animated world position (+ a local
        /// offset along bone-local +Y) to screen space each frame so the
        /// score bubble's tail can follow the head as it tilts forward
        /// during the slouch animation. Using the bone (rather than the
        /// HeadMesh node) is what makes the anchor *animated* — the mesh's
        /// own bounding box doesn't update with skinning.
        weak var headBone: SCNNode?
        /// Distance in bone-local units from the Head bone's origin to the
        /// top of the head sphere. Empirical for the current rig — Blender
        /// bones extend along their +Y axis by convention. 0.5 is the sweet
        /// spot where the bubble's tail tip sits just above the head crown.
        static let headTopOffset: Float = 0.55
        /// Where to publish the projected head position (set from updateUIView
        /// each pass). Throttled to `headPublishInterval` to avoid 60Hz
        /// SwiftUI re-renders.
        var headScreenBinding: Binding<CGPoint?>?
        private var lastHeadPublishTime: TimeInterval = 0
        // ~60 Hz: publish on every render frame so the bubble stays in lock-
        // step with the rendered head. Combined with no SwiftUI animation on
        // the binding, this eliminates the ~110 ms chase lag we'd otherwise
        // see (50 ms throttle + 60 ms ease).
        private let headPublishInterval: TimeInterval = 1.0 / 60.0

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            let dt = lastTick == 0 ? 0 : (time - lastTick)
            lastTick = time
            guard dt > 0 else { return }
            let current = renderer.sceneTime
            let alpha = 1 - exp(-smoothingRate * dt)
            renderer.sceneTime = current + (targetSceneTime - current) * alpha

            // Drive the head tint from the smoothed scene time so color
            // tracks the visible slouch animation. HeadMesh has its own
            // material (set up at export time); flipping its diffuse color
            // repaints just the head.
            if let mat = headMaterial, animationDuration > 0 {
                let ratio = max(0, min(1, renderer.sceneTime / animationDuration))
                mat.diffuse.contents = headTintUIColor(ratio: ratio)
            }

            // Project the Head bone's animated world position (with a local
            // +Y offset to land on top of the head sphere) to screen coords
            // each tick. Reading from `bone.presentation` picks up the live
            // animated transform — that's what makes the bubble follow the
            // head forward as the rig slouches.
            if let bone = headBone,
               let scnView = renderer as? SCNView,
               time - lastHeadPublishTime >= headPublishInterval {
                let topLocal = SIMD3<Float>(0, Self.headTopOffset, 0)
                let topWorld = bone.presentation.simdConvertPosition(topLocal, to: nil)
                let proj = scnView.projectPoint(SCNVector3(topWorld.x, topWorld.y, topWorld.z))
                let pt = CGPoint(x: CGFloat(proj.x), y: CGFloat(proj.y))
                lastHeadPublishTime = time
                if let binding = headScreenBinding {
                    DispatchQueue.main.async {
                        binding.wrappedValue = pt
                    }
                }
            }
        }

        /// Ramp tied to `PostureScore.Grade` thresholds (see CLAUDE.md — good
        /// ≥ 75, fair 60-75, poor < 60). `slouchRatio` maps score=90→0,
        /// score=30→1, so 75→0.25, 60→0.5.
        ///
        ///   - ratio ≤ 0.25 (good)       → pure white, no tint
        ///   - 0.25 < ratio ≤ 0.5 (fair) → white blends toward yellow
        ///   - ratio > 0.5 (poor)        → yellow blends toward a softened red
        ///                                  (20% diluted with white so it's
        ///                                  less harsh at full slouch)
        private func headTintUIColor(ratio: Double) -> UIColor {
            let white  = SIMD3<Double>(1.0, 1.0, 1.0)
            let yellow = SIMD3<Double>(1.0, 0.85, 0.0)
            let redRaw = SIMD3<Double>(1.0, 0.20, 0.20)
            let red    = redRaw * 0.8 + white * 0.2  // 20% less strong
            let c: SIMD3<Double>
            if ratio <= 0.25 {
                c = white
            } else if ratio <= 0.5 {
                let t = (ratio - 0.25) / 0.25
                c = white * (1 - t) + yellow * t
            } else {
                let t = (ratio - 0.5) / 0.5
                c = yellow * (1 - t) + red * t
            }
            return UIColor(red: CGFloat(c.x), green: CGFloat(c.y),
                           blue: CGFloat(c.z), alpha: 1)
        }
    }

    // MARK: - Scene construction

    private static func makeScene() -> SCNScene? {
        guard let url = Bundle.main.url(forResource: "stickman", withExtension: "usdz"),
              let scene = try? SCNScene(url: url, options: nil) else {
            Log.line("[Buddy3D]", "failed to load stickman.usdz from bundle")
            return nil
        }

        // Two wrapper layers:
        //   `axisFix`: Blender USD export leaves the model Z-up (feet at z≈0,
        //     head at +z). SceneKit is Y-up. Rotate -90° around X to stand the
        //     figure upright without touching the mirror transform.
        //   `buddyContainer`: the node we flip 180° around Y for mirroring +
        //     scale. Keeping it as a separate ancestor means `flipRest` stays
        //     clean identity and the update-time composition is just `rest * rot`.
        let axisFix = SCNNode()
        axisFix.name = "buddyAxisFix"
        axisFix.simdEulerAngles = SIMD3(-.pi / 2, 0, 0)
        for child in scene.rootNode.childNodes {
            child.removeFromParentNode()
            axisFix.addChildNode(child)
        }

        let container = SCNNode()
        container.name = "buddyContainer"
        container.addChildNode(axisFix)
        scene.rootNode.addChildNode(container)
        // Model is ~8.9 units tall; scale to a manageable size.
        container.simdScale = SIMD3(repeating: 0.15)

        // The new model is already exported in a seated pose (Blender-baked
        // rest pose, see tools/stickman/export_v2.py), so no runtime posing
        // here. Model extends Y ∈ [-0.75, 1.59]; center of mass sits around
        // y ≈ 0.42. Keep axisFix at origin — camera look-at aims at body center.
        axisFix.simdPosition = SIMD3<Float>(0, 0, 0)

        // Log post-setup bounds so we know what we're framing.
        let (minB, maxB) = container.boundingBox
        Log.line("[Buddy3D]", String(format: "container bounds: min=(%.2f,%.2f,%.2f) max=(%.2f,%.2f,%.2f)",
            minB.x, minB.y, minB.z, maxB.x, maxB.y, maxB.z))

        // Camera — side view framed on the seated figure. Scaled model is
        // ~1.64m tall, ~1.27m wide, center-Y ≈ 0.3 world units. Camera 2.5m
        // off in +X with a 45° vertical FOV gives a full-body side profile
        // with margin on top + bottom.
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 45
        cam.camera?.zNear = 0.1
        cam.camera?.zFar = 50
        cam.simdPosition = SIMD3(3.75, Self.cameraLookAt.y, 0)
        cam.simdLook(at: Self.cameraLookAt, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        scene.rootNode.addChildNode(cam)

        // Lighting: soft ambient + one directional for mild shading.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 500
        scene.rootNode.addChildNode(ambient)

        let directional = SCNNode()
        directional.light = SCNLight()
        directional.light?.type = .directional
        directional.light?.intensity = 700
        directional.simdEulerAngles = SIMD3(-0.7, -0.5, 0)
        scene.rootNode.addChildNode(directional)

        return scene
    }

    /// Wire up the buddyContainer for mirror/scale/debug. Also inventory all
    /// skeletal animations so we can log duration for debugging. Attaches the
    /// head-tint shader modifier to BodyMesh so the head warms toward yellow/
    /// red as the slouch advances.
    private static func cacheDriveNodes(scene: SCNScene, into coord: Coordinator) {
        if let container = scene.rootNode.childNode(withName: "buddyContainer", recursively: false) {
            coord.flipNode = container
            coord.flipRest = container.simdOrientation
        }
        var longest: TimeInterval = 0
        var count = 0
        inventoryAnimations(on: scene.rootNode, longest: &longest, count: &count)
        coord.animationDuration = longest
        Log.line("[Buddy3D]",
            "animations found: \(count)  longest duration: \(String(format: "%.3f", longest))s")

        // Force every imported material to render both sides. Pieces of the
        // body rig in the v6 model have flipped normals; under SceneKit's
        // default back-face culling the limbs come out invisible (Eevee's
        // preview renders them anyway because Eevee defaults to two-sided).
        scene.rootNode.enumerateHierarchy { node, _ in
            for m in node.geometry?.materials ?? [] {
                m.isDoubleSided = true
            }
        }

        // Last-ditch: if BodyMesh's geometry came across with no material
        // binding at all (Blender → USD → SceneKit can drop materials in
        // edge cases), give it a plain white PBR material so the body
        // doesn't render as fully transparent.
        if let bodyGeoNode = findFirstGeometryNode(prefixed: "BodyMesh", in: scene.rootNode),
           let geo = bodyGeoNode.geometry,
           geo.materials.isEmpty {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = UIColor.white
            m.metalness.contents = 0.0
            m.roughness.contents = 0.3
            m.isDoubleSided = true
            geo.materials = [m]
            Log.line("[Buddy3D]", "BodyMesh had no materials — assigned default white")
        }

        // Head has been split off as its own mesh in the exporter so we can
        // tint its material directly (no shader modifier). Search for the
        // HeadMesh node and cache its first material.
        if let headMat = findMaterial(for: "HeadMesh", in: scene.rootNode) {
            coord.headMaterial = headMat
        } else {
            Log.line("[Buddy3D]", "WARN: HeadMesh material not found; head tint disabled")
        }

        // Cache the Head BONE so the renderer can project its animated
        // world position to screen each frame for the score-bubble anchor.
        // Walk every skinner in the scene and pick the bone literally named
        // "Head"; if not found, log "head"-containing candidates so we know
        // what to look for.
        var bestSkinner: SCNSkinner?
        var bestCount = 0
        func walkSkinners(_ n: SCNNode) {
            if let s = n.skinner, s.bones.count > bestCount {
                bestSkinner = s
                bestCount = s.bones.count
            }
            for c in n.childNodes { walkSkinners(c) }
        }
        walkSkinners(scene.rootNode)
        if let skinner = bestSkinner {
            if let head = skinner.bones.first(where: { $0.name == "Head" }) {
                coord.headBone = head
                Log.line("[Buddy3D]", "head bone cached: \(head.name ?? "?")")
            } else {
                let candidates = skinner.bones.compactMap(\.name)
                    .filter { $0.lowercased().contains("head") }
                Log.line("[Buddy3D]",
                    "WARN: Head bone not found among \(skinner.bones.count) bones. "
                    + "Head-ish candidates: \(candidates)")
            }
        } else {
            Log.line("[Buddy3D]", "WARN: no skinner found; bubble anchor disabled")
        }
    }

    private static func findMaterial(for nodeNamePrefix: String, in root: SCNNode) -> SCNMaterial? {
        // HeadMesh (etc.) is a group node after USD import; the actual
        // geometry sits on a child like `Sphere_001`. Match by name then
        // walk descendants until we hit one with a material.
        if let name = root.name, name.hasPrefix(nodeNamePrefix) {
            return firstGeometryMaterial(in: root)
        }
        for c in root.childNodes {
            if let m = findMaterial(for: nodeNamePrefix, in: c) { return m }
        }
        return nil
    }

    /// Find the first node carrying actual geometry whose name (or whose
    /// ancestor's name) starts with `prefix`. Used to install a fallback
    /// material if the imported mesh came across without one.
    private static func findFirstGeometryNode(prefixed prefix: String, in root: SCNNode) -> SCNNode? {
        if let name = root.name, name.hasPrefix(prefix) {
            if root.geometry != nil { return root }
            for c in root.childNodes {
                if c.geometry != nil { return c }
            }
        }
        for c in root.childNodes {
            if let f = findFirstGeometryNode(prefixed: prefix, in: c) { return f }
        }
        return nil
    }

    private static func firstGeometryMaterial(in root: SCNNode) -> SCNMaterial? {
        if let mat = root.geometry?.firstMaterial { return mat }
        for c in root.childNodes {
            if let m = firstGeometryMaterial(in: c) { return m }
        }
        return nil
    }

    private static func inventoryAnimations(on node: SCNNode, longest: inout TimeInterval, count: inout Int) {
        for key in node.animationKeys {
            if let player = node.animationPlayer(forKey: key) {
                count += 1
                longest = max(longest, player.animation.duration)
                // Drive the clip with scene time so we can scrub it directly
                // by score in updateUIView. Re-attach so the new time-base
                // setting actually takes effect (changing the property on a
                // running animation is silently ignored on some iOS versions).
                player.animation.usesSceneTimeBase = true
                player.animation.repeatCount = 1
                player.animation.autoreverses = false
                player.animation.timeOffset = 0
                let anim = player.animation
                node.removeAnimation(forKey: key)
                node.addAnimation(anim, forKey: key)
                node.animationPlayer(forKey: key)?.play()
            }
        }
        for c in node.childNodes {
            inventoryAnimations(on: c, longest: &longest, count: &count)
        }
    }

    /// One-time dump of the imported scene's node hierarchy — helpful for
    /// debugging bone-name mismatches on first bring-up. Disable once we trust
    /// the rig.
    private static var didDumpHierarchy = false
    private static func dumpHierarchyOnce(scene: SCNScene) {
        guard !didDumpHierarchy else { return }
        didDumpHierarchy = true
        Log.line("[Buddy3D]", "scene hierarchy:")
        func walk(_ node: SCNNode, depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            let name = node.name ?? "(unnamed)"
            var tags: [String] = []
            if node.camera != nil { tags.append("camera") }
            if let l = node.light { tags.append("light:\(l.type.rawValue)") }
            if node.geometry != nil { tags.append("mesh") }
            if let sk = node.skinner { tags.append("skinner:\(sk.bones.count)bones") }
            let kind = tags.isEmpty ? "" : " [" + tags.joined(separator: ",") + "]"
            Log.line("[Buddy3D]", "\(indent)• \(name)\(kind)")
            for c in node.childNodes { walk(c, depth: depth + 1) }
        }
        walk(scene.rootNode, depth: 0)
    }

    // MARK: - Score → slouch ratio

    /// Linear ramp from "upright" to "fully slouched", matching the transfer
    /// function the 2D view used for head pitch. Nil / score ≥ 90 → 0 (t=0 of
    /// the Blender clip, upright); score ≤ 30 → 1 (t=50, fully slouched);
    /// linear in between.
    static func slouchRatio(for score: PostureScore?) -> Double {
        guard let value = score?.value else { return 0 }
        let upright: Float = 90
        let floor: Float = 30
        if value >= upright { return 0 }
        if value <= floor { return 1 }
        return Double((upright - value) / (upright - floor))
    }
}
