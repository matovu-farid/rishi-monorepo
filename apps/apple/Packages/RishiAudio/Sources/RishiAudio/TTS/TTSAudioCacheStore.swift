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
    ///
    /// A 0-byte committed entry is treated as a MISS (and evicted): an empty
    /// audio file yields no decoder buffer and permanently halts playback on
    /// every cache hit. Re-synthesising is the only recovery, so we never serve
    /// (or keep) an empty entry. Guards the observed `tts.cache.hit bytes=0`
    /// read-aloud stall.
    public func read(key: String) -> URL? {
        let url = finalURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else {
            try? fileManager.removeItem(at: url)
            Log.event("tts.cache.empty_evicted", level: .info, data: ["key_prefix": String(key.prefix(8))])
            return nil
        }
        do {
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        } catch {
            // Touch is best-effort — LRU ordering may be stale but read still succeeds.
            Log.event("tts.cache.touch.failed", level: .debug, data: ["error": "\(error)"])
        }
        return url
    }

    // MARK: - Write (tee path)

    /// Opens an INDEPENDENT `.partial` URL for the given key and returns it. Each
    /// call gets a unique path (`<key>.<token>.mp3.partial`) so two concurrent
    /// writers for the SAME key (e.g. the engine playing a passage while the
    /// prewarmer re-warms it) never share — and therefore never clobber — each
    /// other's in-flight file. Caller writes bytes then calls `commit(key:partial:)`
    /// on success or `discard(partial:)` on cancel/error.
    public func beginWrite(key: String) throws -> URL {
        let partial = uniquePartialURL(for: key)
        // Create empty file so caller can open a write handle immediately.
        fileManager.createFile(atPath: partial.path, contents: nil)
        return partial
    }

    /// Atomically promotes the given `.partial` to `<key>.mp3`. Runs LRU eviction
    /// after. Throws `CocoaError(.fileNoSuchFile)` if the partial is gone.
    public func commit(key: String, partial: URL) throws {
        let final = finalURL(for: key)
        guard fileManager.fileExists(atPath: partial.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        _ = try fileManager.replaceItemAt(final, withItemAt: partial)
        evictIfOver()
    }

    /// Removes the given `.partial`. Does NOT touch the `.mp3`. Used on
    /// cancel/error; safe to call when the partial does not exist. Only removes
    /// the specific file passed in, so a sibling writer's partial is untouched.
    public func discard(partial: URL) {
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

    /// Per-writer partial path. The token keeps concurrent same-key writers on
    /// independent files; the `.mp3.partial` suffix keeps them out of the LRU
    /// scan (which only counts `.mp3`) and invisible to `read`.
    private func uniquePartialURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).\(UUID().uuidString).mp3.partial", isDirectory: false)
    }
}
