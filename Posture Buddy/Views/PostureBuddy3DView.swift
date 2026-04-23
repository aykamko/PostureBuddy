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

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.isUserInteractionEnabled = false
        view.autoenablesDefaultLighting = false
        // SceneKit only needs to redraw when we mutate state; no per-frame animation.
        view.rendersContinuously = false

        if let scene = Self.makeScene() {
            view.scene = scene
            Self.cacheDriveNodes(scene: scene, into: context.coordinator)
            Self.dumpHierarchyOnce(scene: scene)
        }
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let leanDeg = Self.leanDegrees(for: score)
        let leanRad = Float(leanDeg) * .pi / 180

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.4
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        // Head pitch. The `axis` here is along the bone's local X; if the figure
        // pitches sideways instead of forward, we adjust to [0,1,0] or [0,0,1]
        // after eyeballing on device.
        if let head = context.coordinator.headNode {
            let delta = simd_quatf(angle: leanRad, axis: [1, 0, 0])
            head.simdOrientation = context.coordinator.headRest * delta
        }

        // Mirror — flip around the rig's up axis based on dominantEar.
        // `.left` triggers the flip, matching the empirically-confirmed 2D mapping.
        if let flipNode = context.coordinator.flipNode {
            let angle: Float = dominantEar == .left ? .pi : 0
            let rot = simd_quatf(angle: angle, axis: [0, 1, 0])  // SceneKit is Y-up after USD import
            flipNode.simdOrientation = context.coordinator.flipRest * rot
        }

        SCNTransaction.commit()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var headNode: SCNNode?
        var headRest = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        /// The scene-tree ancestor we rotate 180° around when mirroring.
        var flipNode: SCNNode?
        var flipRest = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
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

        // Pose arms down from T-pose to a relaxed side-hanging pose. The rig
        // shares one skeleton across all skinned meshes, so rotating the upper-
        // arm bones (`Arm_L_1`, `Arm_R_1` under the Spine_4 chain) deforms the
        // bound arm spheres via SCNSkinner. ~70° around the Z axis brings the
        // arms from horizontal to roughly along the torso.
        poseArmsDown(in: scene.rootNode)

        // Log post-setup bounds so we know what we're framing.
        let (minB, maxB) = container.boundingBox
        Log.line("[Buddy3D]", String(format: "container bounds: min=(%.2f,%.2f,%.2f) max=(%.2f,%.2f,%.2f)",
            minB.x, minB.y, minB.z, maxB.x, maxB.y, maxB.z))

        // Camera — side view at the figure's right, framed around torso height.
        // Pulled back so the full body fits comfortably; slight elevation so
        // we're looking down at the head's forward-lean arc rather than up.
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 45
        cam.camera?.zNear = 0.1
        cam.camera?.zFar = 50
        cam.simdPosition = SIMD3(2.5, 0.8, 0)
        cam.simdLook(at: SIMD3(0, 0.7, 0), up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
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

    /// Walk the imported scene tree to find the node we rotate to drive the head
    /// lean and the node we rotate 180° around Y to mirror. The rig has two
    /// nodes named "Head": a deep bone (`Armature_001/Root/Spine_1/.../Spine_4/Head`)
    /// with no mesh, and a shallow `Armature/Head` that parents the visible
    /// sphere mesh. If skinning is present we prefer the bone (deforms the mesh
    /// via SCNSkinner); otherwise we target the mesh parent directly (rigid
    /// sub-mesh transform).
    private static func cacheDriveNodes(scene: SCNScene, into coord: Coordinator) {
        let hasSkinning = firstSkinner(in: scene.rootNode) != nil
        let head: SCNNode? = hasSkinning
            ? scene.rootNode.childNode(withName: "Head", recursively: true)
            : firstHeadWithMeshChild(in: scene.rootNode)

        if let head {
            coord.headNode = head
            coord.headRest = head.simdOrientation
            Log.line("[Buddy3D]", "head drive node: \(head.name ?? "?") (skinning=\(hasSkinning))")
        } else {
            Log.line("[Buddy3D]", "WARN: head drive node not found; head won't animate")
        }
        if let container = scene.rootNode.childNode(withName: "buddyContainer", recursively: false) {
            coord.flipNode = container
            coord.flipRest = container.simdOrientation
        }
    }

    private static func firstSkinner(in root: SCNNode) -> SCNSkinner? {
        if let s = root.skinner { return s }
        for c in root.childNodes {
            if let s = firstSkinner(in: c) { return s }
        }
        return nil
    }

    /// Rotate the upper-arm bones from T-pose down toward the torso. The arms
    /// are bones named `Arm_L_1` / `Arm_R_1` nested under the `Spine_4` chain
    /// (not the shallow same-named mesh parents). We find them by path through
    /// the deep bone hierarchy.
    private static func poseArmsDown(in root: SCNNode) {
        guard let spine4 = root.childNode(withName: "Spine_4", recursively: true) else {
            Log.line("[Buddy3D]", "WARN: Spine_4 not found; arms stay in T-pose")
            return
        }
        // The bones' local axes come from Blender — rotating ~±70° around Z
        // brings the arm from horizontal to roughly alongside the torso.
        let down: Float = 70 * .pi / 180
        if let armL = spine4.childNode(withName: "Arm_L_1", recursively: false) {
            armL.simdOrientation = armL.simdOrientation * simd_quatf(angle: -down, axis: [0, 0, 1])
        }
        if let armR = spine4.childNode(withName: "Arm_R_1", recursively: false) {
            armR.simdOrientation = armR.simdOrientation * simd_quatf(angle: down, axis: [0, 0, 1])
        }
    }

    private static func firstHeadWithMeshChild(in root: SCNNode) -> SCNNode? {
        if root.name == "Head" && root.childNodes.contains(where: { $0.geometry != nil }) {
            return root
        }
        for c in root.childNodes {
            if let m = firstHeadWithMeshChild(in: c) { return m }
        }
        return nil
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

    // MARK: - Score → degrees

    /// Linear ramp: nil/score ≥ 90 → 0°, ≤ 30 → 35°, linear in between.
    /// Matches the 2D PostureBuddyView exactly — same transfer function so the
    /// user-visible lean magnitude doesn't change when they compare the views.
    static func leanDegrees(for score: PostureScore?) -> Double {
        guard let value = score?.value else { return 0 }
        let upright: Float = 90
        let floor: Float = 30
        let maxLean: Double = 35
        if value >= upright { return 0 }
        if value <= floor { return maxLean }
        let t = Double((upright - value) / (upright - floor))
        return t * maxLean
    }
}
