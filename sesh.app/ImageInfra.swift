// ImageInfra.swift
//
// Egress + bandwidth plumbing for every remote image in the app. Three levers,
// all aimed at the same problem: with a small user base we were still blowing
// past Supabase's egress quota because the same photos were re-downloaded on
// every launch, at full resolution, to be shown in tiny views.
//
//   1. SeshImageCache — a PERSISTENT on-disk cache of already-downsampled
//      images. The in-memory NSCache is wiped every launch / under memory
//      pressure; this survives, so a given image is fetched + shrunk at most
//      once per device, then read from disk forever.
//   2. Upload-time thumbnails — StorageUploader writes a ~512px sibling next to
//      each original, so lists / grids / map pins pull a few dozen KB instead
//      of a multi-MB original. Legacy content with no thumb falls back to the
//      original (once), and the miss is remembered so we don't re-probe.
//   3. Long Cache-Control + a big URLCache — so the CDN and the OS HTTP cache
//      both hold onto objects instead of re-serving them.

import UIKit
import Foundation
import CryptoKit
import Supabase

// MARK: - Downscaling

enum ImageDownscale {
    /// Re-encode `data` as a JPEG no larger than `maxDim` on its long edge.
    /// Used for avatars (small originals) and every thumbnail.
    static func jpeg(_ data: Data, maxDim: CGFloat, quality: CGFloat) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let longest = max(img.size.width, img.size.height)
        guard longest > 0 else { return nil }
        let scale = longest > maxDim ? maxDim / longest : 1
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.opaque = true
        let out = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
        return out.jpegData(compressionQuality: quality)
    }
}

// MARK: - Persistent downsampled-image cache

/// On-disk store of downsampled images (keyed by URL + target pixel size) plus
/// a tiny negative cache for thumbnails that don't exist on legacy content.
enum SeshImageCache {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("sesh-img", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func hashed(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func fileURL(_ key: String) -> URL {
        dir.appendingPathComponent(hashed(key)).appendingPathExtension("jpg")
    }

    static func image(for key: String) -> UIImage? {
        let u = fileURL(key)
        guard let data = try? Data(contentsOf: u) else { return nil }
        // Bump mtime so the trimmer treats recently-used images as hot.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
        return UIImage(data: data)
    }

    static func store(_ image: UIImage, for key: String) {
        guard let data = image.jpegData(compressionQuality: 0.82) else { return }
        try? data.write(to: fileURL(key), options: .atomic)
    }

    // Negative cache: a zero-byte marker so a legacy image whose thumbnail 404s
    // is only probed once per device.
    private static func negURL(_ key: String) -> URL {
        dir.appendingPathComponent(hashed("neg:" + key)).appendingPathExtension("neg")
    }
    static func isThumbMissing(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: negURL(key).path)
    }
    static func markThumbMissing(_ key: String) {
        try? Data().write(to: negURL(key), options: .atomic)
    }

    /// Evict the least-recently-used files when the cache grows past `maxBytes`.
    /// Cheap; runs off the main thread at launch.
    static func trimInBackground(maxBytes: Int = 400 * 1024 * 1024) {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            guard let items = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys) else { return }
            var files: [(url: URL, size: Int, date: Date)] = items.compactMap { u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                return (u, v?.fileSize ?? 0, v?.contentModificationDate ?? .distantPast)
            }
            var total = files.reduce(0) { $0 + $1.size }
            guard total > maxBytes else { return }
            files.sort { $0.date < $1.date }   // oldest first
            for f in files {
                if total <= maxBytes { break }
                try? fm.removeItem(at: f.url)
                total -= f.size
            }
        }
    }
}

// MARK: - Thumbnail path / URL helpers

extension URL {
    /// Buckets that carry an upload-time `_thumb` sibling.
    private static let seshThumbBuckets = ["recap-photos", "session-snaps", "event-covers", "stories"]

    /// Whether this storage URL points at a bucket that has thumbnails.
    var hasSeshThumbnails: Bool {
        let s = absoluteString
        return URL.seshThumbBuckets.contains { s.contains("/\($0)/") }
    }

    /// Sibling thumbnail URL: inserts `_thumb` before the file extension of the
    /// object path, preserving any cache-busting query.
    var seshThumbURL: URL? {
        guard var comps = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        let path = comps.path
        guard let dot = path.lastIndex(of: "."),
              path[path.index(after: dot)...].allSatisfy({ $0 != "/" }) else { return nil }
        comps.path = path.replacingCharacters(in: dot..<dot, with: "_thumb")
        return comps.url
    }
}

// MARK: - Uploads (long cache + thumbnail sibling)

enum StorageUploader {
    /// One year — objects are content-addressed (unique paths) or version-busted
    /// with a `?v=` query, so they can be cached aggressively.
    static let longCacheSeconds = "31536000"

    /// Upload image `data` to `bucket/path` with a long cache TTL and, unless
    /// disabled, a ~512px `_thumb` sibling for cheap list/grid loads. Callers
    /// fetch the public URL themselves afterwards, exactly as before.
    static func uploadImage(
        bucket: String,
        path: String,
        data: Data,
        upsert: Bool = false,
        thumbnail: Bool = true,
        thumbMaxDim: CGFloat = 512
    ) async throws {
        _ = try await supabase.storage.from(bucket).upload(
            path, data: data,
            options: FileOptions(cacheControl: longCacheSeconds,
                                 contentType: "image/jpeg", upsert: upsert)
        )
        if thumbnail, let thumb = ImageDownscale.jpeg(data, maxDim: thumbMaxDim, quality: 0.55) {
            _ = try? await supabase.storage.from(bucket).upload(
                thumbPath(path), data: thumb,
                options: FileOptions(cacheControl: longCacheSeconds,
                                     contentType: "image/jpeg", upsert: true)
            )
        }
    }

    static func thumbPath(_ path: String) -> String {
        guard let dot = path.lastIndex(of: ".") else { return path + "_thumb" }
        var p = path
        p.insert(contentsOf: "_thumb", at: dot)
        return p
    }
}

// MARK: - Launch config

enum ImageInfra {
    /// Called once at launch: enlarge the shared HTTP cache (so plain AsyncImage
    /// + URLSession downloads survive relaunches) and trim the disk cache.
    static func configure() {
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,     // 64 MB
            diskCapacity: 512 * 1024 * 1024        // 512 MB
        )
        SeshImageCache.trimInBackground()
    }
}
