import Foundation
import RishiLogging

/// File-backed LRU cache for synthesised TTS MP3 bytes.
///
/// Layout (under `directory`):
///   `<hexkey>.mp3`         — committed cache entry (visible to `read`)
///   `<hexkey>.mp3.partial` — in-flight write, invisible to `read`
///
/// Default `directory` is `~/Library/Caches/Rishi/TTS/`. The OS can purge it under
/// disk pressure, which is the right semantic for a cache.
public actor TTSAudioCacheStore {
    private let directory: URL
    private let capBytes: Int
    private let fileManager = FileManager.default

    /// Default production root: `<systemCaches>/Rishi/TTS/`.
    public static func defaultDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("Rishi/TTS", isDirectory: true)
    }

    /// - Parameters:
    ///   - directory: Root directory for cached `.mp3` files. Created if missing.
    ///   - capBytes: Maximum total bytes before LRU eviction kicks in. Default 200 MB.
    public init(directory: URL = TTSAudioCacheStore.defaultDirectory(),
                capBytes: Int = 200 * 1024 * 1024) throws {
        self.directory = directory
        self.capBytes = capBytes
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Read

    /// Returns the URL of the cached `.mp3` if it exists, else nil.
    /// Touches the file's modification date so LRU treats it as recently used.
    /// Never returns a `.partial` file.
    public func read(key: String) -> URL? {
        let url = finalURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        } catch {
            // Touch is best-effort — LRU ordering may be stale but read still succeeds.
            Log.event("tts.cache.touch.failed", level: .debug, data: ["error": "\(error)"])
        }
        return url
    }

    // MARK: - Write (tee path)

    /// Returns the `.partial` URL for the given key. Removes any pre-existing `.partial`
    /// at that path so callers can start clean. Caller is responsible for writing bytes
    /// and calling `commit(key:)` on success or `discard(key:)` on cancel/error.
    public func beginWrite(key: String) throws -> URL {
        let partial = partialURL(for: key)
        try? fileManager.removeItem(at: partial)
        // Create empty file so caller can open a write handle immediately.
        fileManager.createFile(atPath: partial.path, contents: nil)
        return partial
    }

    /// Atomically promotes `<key>.mp3.partial` to `<key>.mp3`. Runs LRU eviction after.
    public func commit(key: String) throws {
        let partial = partialURL(for: key)
        let final = finalURL(for: key)
        guard fileManager.fileExists(atPath: partial.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        _ = try fileManager.replaceItemAt(final, withItemAt: partial)
        evictIfOver()
    }

    /// Removes the `.partial` for the given key. Does NOT touch the `.mp3`.
    /// Used on cancel/error to clean up; safe to call even when `.partial` does not exist.
    public func discard(key: String) {
        let partial = partialURL(for: key)
        try? fileManager.removeItem(at: partial)
    }

    // MARK: - LRU

    /// Scans the cache directory and removes oldest `.mp3` files (by modification date)
    /// until total size <= capBytes. Excludes `.partial` from BOTH the size sum and the
    /// eviction candidates — `.partial` files are tracked separately and never count
    /// against the cap (they're in-flight, not yet committed).
    public func evictIfOver() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, size: Int, mtime: Date)] = []
        var total = 0
        for url in urls where url.pathExtension == "mp3" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            let mtime = values.contentModificationDate ?? .distantPast
            entries.append((url, size, mtime))
            total += size
        }

        guard total > capBytes else { return }

        // Sort oldest-first; delete until under cap.
        entries.sort { $0.mtime < $1.mtime }
        for entry in entries {
            guard total > capBytes else { break }
            if (try? fileManager.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
    }

    // MARK: - URL helpers

    private func finalURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).mp3", isDirectory: false)
    }

    private func partialURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).mp3.partial", isDirectory: false)
    }
}
