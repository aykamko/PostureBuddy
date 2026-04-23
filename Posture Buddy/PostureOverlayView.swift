import SwiftUI
import Vision

struct PostureOverlayView: View {
    let detectedPose: DetectedPose?

    private static let connections: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
        // Head
        (.nose, .leftEye), (.nose, .rightEye),
        (.leftEye, .leftEar), (.rightEye, .rightEar),
        // Neck to head and shoulders
        (.neck, .nose),
        (.neck, .leftShoulder), (.neck, .rightShoulder),
        // Ears to shoulders (side-profile spine line — the one used for scoring)
        (.leftEar, .leftShoulder), (.rightEar, .rightShoulder),
        (.leftShoulder, .rightShoulder),
    ]

    private static let staleColor = Color(red: 0.7, green: 0.4, blue: 1.0)  // purple

    var body: some View {
        Canvas { context, size in
            guard let pose = detectedPose else { return }
            let kp = pose.keypoints
            let lineColor = pose.score?.grade.swiftUIColor ?? .white.opacity(0.6)

            // Body skeleton. A connection is purple if either endpoint is stale
            // (live frame didn't detect it; using last-known position) so the user
            // can tell when the overlay is partially extrapolated.
            for (a, b) in Self.connections {
                guard let kpA = kp[a], let kpB = kp[b] else { continue }
                let color = (kpA.isStale || kpB.isStale) ? Self.staleColor : lineColor
                var path = Path()
                path.move(to: visionToCanvas(kpA.location, in: size))
                path.addLine(to: visionToCanvas(kpB.location, in: size))
                context.stroke(path, with: .color(color), lineWidth: 3)
            }
            for (_, keypoint) in kp {
                let color: Color = keypoint.isStale ? Self.staleColor : .white
                drawDot(at: visionToCanvas(keypoint.location, in: size), radius: 5, color: color, in: &context)
            }

            // Face landmarks (debug overlay — cyan to stand out from the white body dots)
            if let face = pose.faceLandmarks {
                // Bounding box
                let bb = face.boundingBox
                let topLeft = visionToCanvas(CGPoint(x: bb.minX, y: bb.maxY), in: size)
                let bottomRight = visionToCanvas(CGPoint(x: bb.maxX, y: bb.minY), in: size)
                var boxPath = Path()
                boxPath.addRect(CGRect(
                    x: topLeft.x,
                    y: topLeft.y,
                    width: bottomRight.x - topLeft.x,
                    height: bottomRight.y - topLeft.y
                ))
                context.stroke(boxPath, with: .color(.cyan.opacity(0.6)), lineWidth: 1)

                for point in face.points {
                    drawDot(at: visionToCanvas(point, in: size), radius: 1.5, color: .cyan, in: &context)
                }
            }
        }
    }

    private func drawDot(at center: CGPoint, radius: CGFloat, color: Color, in context: inout GraphicsContext) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect), with: .color(color))
    }

    private func visionToCanvas(_ pt: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: pt.x * size.width, y: (1.0 - pt.y) * size.height)
    }
}
