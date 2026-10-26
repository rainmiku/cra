import Foundation

enum AppPaths {
    static let supportDir: URL = {
        // CRA_DATA_DIR runs a second, independent Cra (testing next to the installed one).
        let base = ProcessInfo.processInfo.environment["CRA_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("io.github.rainmiku.cra", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    static var chromiumCache: URL { supportDir.appendingPathComponent("Chromium", isDirectory: true) }
    static var favicons: URL {
        let u = supportDir.appendingPathComponent("Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var log: URL { supportDir.appendingPathComponent("chromium.log") }
    static func file(_ name: String) -> URL { supportDir.appendingPathComponent(name) }
}

/// One JSON file, loaded once, saved with a short debounce. Writes are atomic
/// and the previous version is kept as `<name>.bak`, which is what Arc does
/// with its timestamped Storable*.json copies, minus the pile-up.
final class JSONStore<T: Codable> {
    let url: URL
    private var pending: DispatchWorkItem?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(_ name: String) { url = AppPaths.file(name) }

    func load(or fallback: () -> T) -> T {
        guard let data = try? Data(contentsOf: url) else { return fallback() }
        if let v = try? decoder.decode(T.self, from: data) { return v }
        // Corrupt file: keep it aside for forensics and start fresh.
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
        return fallback()
    }

    func save(_ value: T, delay: TimeInterval = 0.4) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow(value) }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func saveNow(_ value: T) {
        pending?.cancel()
        pending = nil
        guard let data = try? encoder.encode(value) else { return }
        let fm = FileManager.default
        let bak = url.appendingPathExtension("bak")
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: bak)
            try? fm.copyItem(at: url, to: bak)
        }
        try? data.write(to: url, options: .atomic)
    }
}
