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
    /// Show the debug bone markers (small bright spheres at each joint).
    /// Default off — they're mostly a rig-diagnosis tool.
    var showBones: Bool = false

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
    private static let viewOffset = SIMD3<Float>(0, 0, -0.09)

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

        // Toggle debug bone markers. The helper walks the tree once per
        // update; cheap enough at 30 or so markers and avoids caching state
        // across re-created Coordinators.
        if let root = view.scene?.rootNode {
            Self.setBoneMarkersHidden(on: root, hidden: !showBones)
        }

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
        /// BodyMesh geometry for setting the head-tint shader uniforms each
        /// frame.
        var bodyGeometry: SCNGeometry?
        /// Materials on the BodyMesh geometry — shader-modifier uniforms need
        /// to be set on the material, not the geometry.
        var bodyMaterials: [SCNMaterial] = []

        /// sceneTime we're easing toward (set in updateUIView from score).
        var targetSceneTime: TimeInterval = 0
        /// Render-loop tick from the previous callback for dt.
        var lastTick: TimeInterval = 0
        /// Rate constant in 1/seconds. ~5 reaches 80% of target in ~0.32 s,
        /// matching the ease feel of the body-level animation modifiers.
        let smoothingRate: Double = 5.0

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            let dt = lastTick == 0 ? 0 : (time - lastTick)
            lastTick = time
            guard dt > 0 else { return }
            let current = renderer.sceneTime
            let alpha = 1 - exp(-smoothingRate * dt)
            renderer.sceneTime = current + (targetSceneTime - current) * alpha

            // Drive the head tint from the smoothed scene time so color
            // tracks the visible slouch animation.
            if animationDuration > 0, !bodyMaterials.isEmpty {
                let ratio = max(0, min(1, renderer.sceneTime / animationDuration))
                let tint = headTintColor(ratio: ratio)
                for mat in bodyMaterials {
                    mat.setValue(NSValue(scnVector3: tint), forKey: "u_headTint")
                    mat.setValue(NSNumber(value: ratio),    forKey: "u_tintAmount")
                }
            }
        }

        /// White → yellow at mid-slouch → red at full slouch.
        private func headTintColor(ratio: Double) -> SCNVector3 {
            let yellow = SIMD3<Double>(1.0, 0.85, 0.0)
            let red    = SIMD3<Double>(1.0, 0.20, 0.20)
            // First half of slouch = approach yellow, second half = yellow→red.
            let blend: SIMD3<Double>
            if ratio < 0.5 {
                blend = yellow
            } else {
                let t = (ratio - 0.5) / 0.5
                blend = yellow * (1 - t) + red * t
            }
            return SCNVector3(blend.x, blend.y, blend.z)
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

        // Debug: attach a bright marker at every bone origin so we can see the
        // skeleton regardless of mesh occlusion. Remove once the pose + camera
        // + axes are dialed in.
        highlightBones(in: scene.rootNode)
        addLimbTipMarkers(in: scene.rootNode)

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

        // USD imports the skinned mesh as a grandchild of the 'BodyMesh'
        // group node — look for the first node in the tree that has both a
        // geometry and a skinner attached.
        if let geom = firstSkinnedGeometry(in: scene.rootNode) {
            attachHeadTintShader(to: geom)
            coord.bodyGeometry = geom
            coord.bodyMaterials = geom.materials
        } else {
            Log.line("[Buddy3D]", "WARN: no skinned geometry found; head tint disabled")
        }
    }

    private static func firstSkinnedGeometry(in root: SCNNode) -> SCNGeometry? {
        if root.skinner != nil, let g = root.geometry { return g }
        for c in root.childNodes {
            if let g = firstSkinnedGeometry(in: c) { return g }
        }
        return nil
    }

    /// Two-stage shader modifier:
    ///   - .geometry: computes a 0..1 mask from the vertex's object-space height
    ///     (Blender exports Z-up, so model-space `position.z` is vertical), with
    ///     a smooth ramp picking up only the head sphere.
    ///   - .surface: mixes the surface diffuse toward `u_headTint` by
    ///     `u_tintAmount * mask`.
    /// Coordinator sets both uniforms each frame from the current sceneTime.
    private static func attachHeadTintShader(to geometry: SCNGeometry) {
        // Surface-stage modifier that transforms the view-space position back
        // to object space via `u_inverseModelViewTransform`, then masks by Z
        // (Blender's up axis for this export). Only head vertices — Z above
        // the threshold — receive the tint. GLSL-style uniforms (known to
        // work on this project's Metal-backed SceneKit).
        // Both the `#pragma varyings` directive and the plain `varying`
        // keyword compile as magenta in this build (Metal-backed SceneKit on
        // iOS). Trick: pipe the mask through the first UV set. The geometry
        // stage writes `_geometry.color.r` into `_geometry.texcoords[0].x`,
        // which SceneKit already interpolates across fragments and exposes
        // to the surface stage as `_surface.diffuseTexcoord`. No custom
        // varying needed. Material has no diffuse texture so we're not
        // stomping anything useful.
        let geomMod = """
        #pragma body
        _geometry.texcoords[0] = vec2(_geometry.color.r, 0.0);
        """
        let surfMod = """
        uniform vec3  u_headTint;
        uniform float u_tintAmount;

        #pragma body
        float mask = _surface.diffuseTexcoord.x;
        _surface.diffuse.rgb = mix(_surface.diffuse.rgb,
                                   u_headTint,
                                   mask * u_tintAmount);
        """
        for mat in geometry.materials {
            mat.shaderModifiers = [
                .geometry: geomMod,
                .surface:  surfMod,
            ]
            mat.setValue(NSValue(scnVector3: SCNVector3(1, 1, 1)), forKey: "u_headTint")
            mat.setValue(NSNumber(value: 0.0),                     forKey: "u_tintAmount")
        }
    }

    /// Recursively hide / show any node we added during bone-marker setup
    /// (prefixes `_boneMarker_` and `_tipMarker_`).
    private static func setBoneMarkersHidden(on node: SCNNode, hidden: Bool) {
        if let name = node.name,
           name.hasPrefix("_boneMarker_") || name.hasPrefix("_tipMarker_") {
            node.isHidden = hidden
        }
        for c in node.childNodes {
            setBoneMarkersHidden(on: c, hidden: hidden)
        }
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

    private static func firstSkinner(in root: SCNNode) -> SCNSkinner? {
        if let s = root.skinner { return s }
        for c in root.childNodes {
            if let s = firstSkinner(in: c) { return s }
        }
        return nil
    }

    /// Attach a bright emissive sphere at every skeleton bone's origin so the
    /// rig is visible through the mesh. Uses `SCNSkinner.bones` (30 bones
    /// confirmed via startup log) as the authoritative list instead of walking
    /// the hierarchy by name. Constant lighting model so markers pop even in
    /// dim scenes. Color-coded by chain via a simple name-prefix check to make
    /// screenshots easier to reason about:
    ///   - Spine_* + Head → magenta  (the chain we rotate for forward-head)
    ///   - Leg_*           → cyan    (hip + knee for sitting)
    ///   - Arm_* / Elbow   → yellow
    ///   - Hand / Foot     → green
    ///   - everything else → white
    private static func highlightBones(in root: SCNNode) {
        guard let skinner = firstSkinner(in: root) else {
            Log.line("[Buddy3D]", "WARN: no skinner found; skipping bone highlight")
            return
        }
        let shown = skinner.bones.filter { shouldHighlight($0.name ?? "") }
        Log.line("[Buddy3D]", "highlighting \(shown.count)/\(skinner.bones.count) bones")
        for bone in shown {
            let marker = SCNNode()
            marker.name = "_boneMarker_\(bone.name ?? "?")"
            marker.geometry = SCNSphere(radius: 0.05)
            let mat = SCNMaterial()
            mat.lightingModel = .constant
            let color = boneMarkerColor(for: bone.name ?? "")
            mat.diffuse.contents = color
            mat.emission.contents = color
            // Draw through the mesh: disable depth test + put markers after
            // the skin in the render order so they always appear on top.
            mat.readsFromDepthBuffer = false
            mat.writesToDepthBuffer = false
            marker.geometry?.firstMaterial = mat
            marker.renderingOrder = 100
            bone.addChildNode(marker)
        }
    }

    /// Show primary joints only. Each limb is split into 5 bendy-bone
    /// subdivisions (`_002…_005`); we show just `_002` (the limb root) so each
    /// joint reads as one marker rather than a cluster of four. The spine
    /// chain keeps all `Spine_B_*` segments so we can see the slouch arc.
    private static func shouldHighlight(_ name: String) -> Bool {
        if name.contains("_Bend") { return false }
        let isLimbSegment = name.hasPrefix("UpperArm") || name.hasPrefix("LowerArm")
                         || name.hasPrefix("UpperLeg") || name.hasPrefix("LowerLeg")
        if isLimbSegment {
            if name.hasSuffix("_003") || name.hasSuffix("_004") || name.hasSuffix("_005") {
                return false
            }
        }
        return true
    }

    /// Attach markers at the tip of each forearm and shin so we can eyeball
    /// wrist / ankle positions. Blender bones have local +Y as the tail
    /// direction, so an offset of `(0, boneLen, 0)` in the bone's frame lands
    /// at the tip. Lengths are first-pass guesses for this model (~8.9 units
    /// tall, Blender default proportions) — iterate if they land off-body.
    private static func addLimbTipMarkers(in root: SCNNode) {
        guard let skinner = firstSkinner(in: root) else { return }
        // Bendy-bone subdivision: each limb is split into 5 segments, with
        // `_005` being the tip-most one. Marker at a small +Y offset from the
        // tip bone's origin lands near the wrist / ankle.
        let tips: [(bone: String, length: Float)] = [
            ("LowerArm_L_005", 0.15),
            ("LowerArm_R_005", 0.15),
            ("LowerLeg_L_005", 0.15),
            ("LowerLeg_R_005", 0.15),
        ]
        for t in tips {
            guard let bone = skinner.bones.first(where: { $0.name == t.bone }) else { continue }
            let marker = SCNNode()
            marker.name = "_tipMarker_\(t.bone)"
            marker.simdPosition = SIMD3(0, t.length, 0)
            marker.geometry = SCNSphere(radius: 0.05)
            let mat = SCNMaterial()
            mat.lightingModel = .constant
            mat.diffuse.contents = UIColor.green
            mat.emission.contents = UIColor.green
            mat.readsFromDepthBuffer = false
            mat.writesToDepthBuffer = false
            marker.geometry?.firstMaterial = mat
            marker.renderingOrder = 100
            bone.addChildNode(marker)
        }
    }

    private static func boneMarkerColor(for name: String) -> UIColor {
        if name == "Head" || name.hasPrefix("Spine") { return .systemPink }
        if name.contains("Leg") { return .cyan }
        if name.contains("Arm") { return .yellow }
        return .white
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
