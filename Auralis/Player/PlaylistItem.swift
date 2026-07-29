/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Struct `PlaylistItem` is a playable track as an item in a playlist.
*/

import AVFoundation
import Foundation

struct PlaybackSourcePlaylist: Codable, Hashable {
    let id: UInt64
    let name: String
}

private final class RunBlocking<T, Failure: Error> {
    fileprivate var value: Result<T, Failure>? = nil
}

extension RunBlocking where Failure == Never {
    func runBlocking(_ operation: @Sendable @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let task = Task(operation: operation)
            self.value = await task.result
            semaphore.signal()
        }
        semaphore.wait()
        switch value {
        case let .success(value):
            return value
        case .none:
            fatalError("Run blocking not received value")
        }
    }
}

extension RunBlocking where Failure == Error {
    func runBlocking(_ operation: @Sendable @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let task = Task(operation: operation)
            value = await task.result
            semaphore.signal()
        }
        semaphore.wait()
        switch value {
        case let .success(value):
            return value
        case let .failure(error):
            throw error
        case .none:
            fatalError("Run blocking not received value")
        }
    }
}

func runBlocking<T>(@_implicitSelfCapture _ operation: @Sendable @escaping () async -> T) -> T {
    RunBlocking().runBlocking(operation)
}

func runBlocking<T>(@_implicitSelfCapture _ operation: @Sendable @escaping () async throws -> T)
    throws -> T
{
    try RunBlocking().runBlocking(operation)
}

func isLocalURL(_ url: URL) -> Bool {
    return url.scheme == "file"
}

func isRemoteURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme else { return false }
    return ["http", "https", "ftp"].contains(scheme)
}

func downloadFile(url: URL, savePath: URL, ext: String) async -> URL? {
    let fileManager = FileManager.default
    // Check if file already exists
    if fileManager.fileExists(atPath: savePath.path) {
        print("File already exists, no need to download.")
    } else {
        do {
            // TODO: Streaming
            print("Downloading file from \(url) to \(savePath)")
            let (data, _) = try await URLSession.shared.data(from: url)
            try data.write(to: savePath)
        } catch {
            print("Error downloading or saving the file: \(error)")
            return nil
        }
    }
    return savePath
}

func getCachedMusicFile(id: UInt64) -> URL? {
    guard let appMusicFolder = getAuralisFolder() else {
        return nil
    }
    let exts = [
        "mp3", "MP3", "flac", "FLAC", "m4a", "M4A", "aac", "AAC", "wav", "WAV", "ogg", "OGG",
        "alac", "ALAC", "aiff", "AIFF", "caf", "CAF", "opus", "OPUS", "wma", "WMA", "mp4", "MP4",
        "webm", "WEBM", "aax", "AAX", "aa", "AA", "dsd", "DSD", "dff", "DFF", "dsf", "DSF", "pcm",
        "PCM", "flv", "FLV",
    ]
    for ext in exts {
        let localFileUrl = appMusicFolder.appendingPathComponent("\(id).\(ext)")
        if FileManager.default.fileExists(atPath: localFileUrl.path) {
            return localFileUrl
        }
    }
    return nil
}

func getAuralisFolder() -> URL? {
    let fileManager = FileManager.default
    guard
        let musicFolder = fileManager.urls(
            for: .musicDirectory, in: .userDomainMask
        ).first
    else {
        return nil
    }
    let appMusicFolder = musicFolder.appendingPathComponent("Auralis")

    // Create the directory if it does not exist
    if !fileManager.fileExists(atPath: appMusicFolder.path) {
        do {
            try fileManager.createDirectory(
                at: appMusicFolder, withIntermediateDirectories: true)
        } catch {
            print("Failed to create directory: \(error)")
            return nil
        }
    }
    return appMusicFolder
}

func downloadMusicFile(url: URL, id: UInt64, ext: String) async -> URL? {
    guard let appMusicFolder = getAuralisFolder() else {
        return nil
    }

    let localFileUrl = appMusicFolder.appendingPathComponent("\(id).\(ext)")
    return await downloadFile(url: url, savePath: localFileUrl, ext: ext)
}

/// Manages the on-disk music cache at `~/Music/Auralis`, enforcing a size limit
/// via LRU eviction and providing a clean-all entry point used by Settings.
final class MusicCacheManager {
    static let shared = MusicCacheManager()
    private init() {}

    /// Root directory for cached music files (`~/Music/Auralis`).
    var cacheDirectory: URL? { getAuralisFolder() }

    /// Total size in bytes of all cached music files.
    func cacheSizeBytes() -> Int64 {
        guard let dir = cacheDirectory,
              let enumerator = FileManager.default.enumerator(
                  at: dir, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Removes every file in the cache directory. Returns true on success.
    @discardableResult
    func clearAll() -> Bool {
        guard let dir = cacheDirectory else { return false }
        guard FileManager.default.fileExists(atPath: dir.path) else { return true }
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
            for url in contents {
                try? FileManager.default.removeItem(at: url)
            }
            return true
        } catch {
            print("MusicCacheManager clearAll error: \(error)")
            return false
        }
    }

    /// Enforces the configured size limit by deleting the least-recently-used
    /// cached files (oldest modification date first). Files whose song id is in
    /// `excluding` (e.g. the currently playing track) are never removed.
    /// A `limitGB` of 0 means unlimited. The limit is passed in (rather than
    /// read from `AppSettings.shared`) to avoid a singleton-init cycle:
    /// `AppSettings.init` -> `maxCacheSizeGB.didSet` -> `enforceLimit` ->
    /// `AppSettings.shared` would deadlock `dispatch_once`.
    func enforceLimit(limitGB: Int, excluding excludedIds: Set<UInt64> = []) {
        guard limitGB > 0 else { return }
        let limitBytes = Int64(limitGB) * 1024 * 1024 * 1024

        guard let dir = cacheDirectory,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return }

        var entries: [(url: URL, modDate: Date, size: Int64, id: UInt64?)] = []
        var total: Int64 = 0
        for url in contents {
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = Int64(values?.fileSize ?? 0)
            let modDate = values?.contentModificationDate ?? Date.distantPast
            let id = UInt64(url.deletingPathExtension().lastPathComponent)
            total += size
            entries.append((url, modDate, size, id))
        }

        guard total > limitBytes else { return }

        // Least recently used (oldest) first.
        entries.sort { $0.modDate < $1.modDate }
        for entry in entries {
            if total <= limitBytes { break }
            if let id = entry.id, excludedIds.contains(id) { continue }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
    }

    /// Marks a cached file as recently used by bumping its modification date,
    /// so the LRU policy keeps frequently-played songs around.
    func touchCachedFile(id: UInt64) {
        guard let file = getCachedMusicFile(id: id) else { return }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: file.path)
    }
}

class PlaylistItem: Identifiable, Codable, Equatable {
    static func == (lhs: PlaylistItem, rhs: PlaylistItem) -> Bool {
        return lhs.id == rhs.id
    }

    let id: UInt64

    /// URL of the local file containing the track's audio.
    var url: URL?

    /// An error that prevents the track from playing.
    let error: Error?

    /// The title of the track.
    let title: String

    /// The artist heard on the track.
    let artist: String

    /// The ext name
    var ext: String?

    /// The duration of the audio file.
    let duration: CMTime

    let albumId: UInt64

    var artworkUrl: URL?

    let nsSong: CloudMusicApi.Song?

    var sourcePlaylist: PlaybackSourcePlaylist?

    /// Initializes a valid item.
    init(
        id: UInt64, url: URL?, title: String, artist: String, albumId: UInt64, ext: String?,
        duration: CMTime,
        artworkUrl: URL?,
        nsSong: CloudMusicApi.Song?,
        sourcePlaylist: PlaybackSourcePlaylist? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.ext = ext
        self.albumId = albumId
        self.duration = duration
        self.error = nil
        self.artworkUrl = artworkUrl
        self.nsSong = nsSong
        self.sourcePlaylist = sourcePlaylist
    }

    enum CodingKeys: String, CodingKey {
        case id, url, title, artist, ext, duration, albumId, artworkUrl, nsSong, sourcePlaylist
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UInt64.self, forKey: .id)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        ext = try container.decodeIfPresent(String.self, forKey: .ext)
        let seconds = try container.decode(Double.self, forKey: .duration)
        duration = CMTime(seconds: seconds, preferredTimescale: 1000)
        albumId = try container.decode(UInt64.self, forKey: .albumId)
        artworkUrl = try container.decodeIfPresent(URL.self, forKey: .artworkUrl)
        nsSong = try container.decodeIfPresent(CloudMusicApi.Song.self, forKey: .nsSong)
        sourcePlaylist = try container.decodeIfPresent(PlaybackSourcePlaylist.self, forKey: .sourcePlaylist)
        error = nil  // This should be handled according to your application logic
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encodeIfPresent(ext, forKey: .ext)
        // Encode CMTime as a Double representing total seconds
        let durationSeconds = CMTimeGetSeconds(duration)
        try container.encode(durationSeconds, forKey: .duration)
        try container.encode(albumId, forKey: .albumId)
        try container.encodeIfPresent(artworkUrl, forKey: .artworkUrl)
        try container.encodeIfPresent(nsSong, forKey: .nsSong)
        try container.encodeIfPresent(sourcePlaylist, forKey: .sourcePlaylist)
    }

    func getLocalUrl() async -> URL? {
        if let url = await self.getUrl(), isLocalURL(url) {
            return url
        }
        return nil
    }

    func getPotentialLocalUrl() -> URL? {
        guard let appMusicFolder = getAuralisFolder() else {
            return nil
        }

        if let ext = self.ext {
            let localFileUrl = appMusicFolder.appendingPathComponent("\(id).\(ext)")
            return localFileUrl
        }
        return nil
    }

    func getArtworkUrl() async -> URL? {
        #if DEBUG
        let timestamp = Date().timeIntervalSince1970
        print("🎨 PlaylistItem: getArtworkUrl called for '\(title)' (ID: \(id)) at \(timestamp)")
        #endif
        
        if let artworkUrl = self.artworkUrl {
            #if DEBUG
            print("🎨 PlaylistItem: Artwork URL found: \(artworkUrl.absoluteString)")
            #endif
            return artworkUrl
        }
        
        #if DEBUG
        print("🎨 PlaylistItem: No artwork URL available for '\(title)' (ID: \(id))")
        #endif
        return nil
    }

    func getUrl() async -> URL? {
        if let cachedFile = getCachedMusicFile(id: id) {
            return cachedFile
        }
        if let url = self.url {
            return url
        }
        if let songData = await CloudMusicApi().song_url_v1(
            id: [id], level: AppSettings.shared.audioQuality.rawValue
        ),
            let songData = songData.first,
            let urlString = songData.url
        {
            let responseExtension = songData.type?.nilIfEmpty ?? songData.encodeType?.nilIfEmpty
            if let responseExtension {
                self.ext = responseExtension
            }
            if let url = URL(string: urlString.https) {
                return url
            }
        }
        print("Failed to get URL")
        return nil
    }
}
