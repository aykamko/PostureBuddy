import Foundation

/// Persists `PostureBaselines` as JSON in Application Support so calibration
/// survives app restarts. Failures (decode error from a schema mismatch, missing
/// file, sandbox issue) are non-fatal — they just mean "no saved baselines"
/// and the user will be prompted to calibrate.
enum BaselinesStore {
    private static let filename = "baselines.json"

    /// `~/Library/Application Support/baselines.json` inside the app sandbox.
    /// Created lazily — directory is mkdir'd on first save.
    private static func fileURL() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return dir.appendingPathComponent(filename)
    }

    static func save(_ baselines: PostureBaselines) {
        do {
            let url = try fileURL()
            let data = try JSONEncoder().encode(baselines)
            try data.write(to: url, options: [.atomic])
            Log.line("[Baselines]", "saved → \(url.lastPathComponent)")
        } catch {
            Log.line("[Baselines]", "save failed: \(error.localizedDescription)")
        }
    }

    /// Returns nil when there's no saved file or it can't be decoded (e.g. the
    /// schema changed across an app update). Callers should treat nil as
    /// "uncalibrated, prompt the user."
    static func load() -> PostureBaselines? {
        do {
            let url = try fileURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let data = try Data(contentsOf: url)
            let baselines = try JSONDecoder().decode(PostureBaselines.self, from: data)
            Log.line("[Baselines]", "loaded ← \(url.lastPathComponent)")
            return baselines
        } catch {
            Log.line("[Baselines]", "load failed (treating as none): \(error.localizedDescription)")
            return nil
        }
    }

    static func clear() {
        guard let url = try? fileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
