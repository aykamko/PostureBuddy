import Foundation

/// Launch-time dump of per-directory sizes inside the app sandbox.
/// Useful for catching unexpected disk growth across dev builds — if anything in
/// Documents/ or Library/ is ballooning we'll see it here. iOS also stashes the
/// per-app ANE-compiled Vision model under Library/Caches; that's expected to be
/// tens to hundreds of MB, not GBs.
enum SandboxDiagnostics {
    static func logStorageUsage() {
        let home = NSHomeDirectory()
        let dirs: [(label: String, path: String, expandChildren: Bool)] = [
            ("Documents", "\(home)/Documents", false),
            ("Library", "\(home)/Library", true),         // break down subdirs
            ("Library/Caches", "\(home)/Library/Caches", true),
            ("tmp", "\(home)/tmp", false),
        ]

        var lines = ["[Sandbox] sizes at launch (home=\(home)):"]
        var total: Int64 = 0
        for (label, path, expand) in dirs {
            let size = directorySize(at: path)
            total += size
            lines.append("  \(label): \(format(size))")
            guard expand else { continue }
            for child in childSizes(at: path).sorted(by: { $0.size > $1.size }).prefix(6) {
                lines.append("    ↳ \(child.name): \(format(child.size))")
            }
        }
        lines.append("  — sandbox total: \(format(total))")
        print(lines.joined(separator: "\n"))
    }

    private static func directorySize(at path: String) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        for case let subpath as String in enumerator {
            let full = "\(path)/\(subpath)"
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  let size = attrs[.size] as? NSNumber else { continue }
            total += size.int64Value
        }
        return total
    }

    private static func childSizes(at path: String) -> [(name: String, size: Int64)] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return children.map { (name: $0, size: directorySize(at: "\(path)/\($0)")) }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
