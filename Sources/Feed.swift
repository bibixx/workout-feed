import Foundation

/// The feed contract (version 1):
/// `{ "version": 1, "workouts": [{ "id"?, "date", "url", "type"?, "title"? }] }`
/// - `date` — local wall-clock ISO-8601 (`2026-07-27` or `2026-07-27T07:00:00`).
/// - `url` — relative to the manifest, or absolute.
/// - `type` — `"workout"` (Apple WorkoutKit binary). Missing → inferred from the URL extension.
///   Unknown types are skipped, not errors — the forward-compat door for e.g. `.fit`.
struct FeedManifest: Decodable {
    let version: Int?
    let workouts: [FeedItem]
}

struct FeedItem: Decodable {
    let id: String?
    let date: String
    let url: String
    let type: String?
    let title: String?
}

enum FeedItemKind: Equatable {
    case appleWorkout
    case unsupported(String)
}

enum FeedError: LocalizedError {
    case notConfigured
    case badURL(String)
    case http(Int, String)
    case notAManifest
    case badItemURL(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add a feed first."
        case .badURL(let url):
            return "“\(url)” isn't a valid URL."
        case .http(let code, let what):
            return "The feed returned HTTP \(code) for \(what)."
        case .notAManifest:
            return "This doesn't look like a workout feed (missing or malformed “workouts” list)."
        case .badItemURL(let label):
            return "Workout “\(label)” has an invalid URL."
        }
    }
}

enum FeedClient {
    /// A trailing slash means "point at a folder" → look for index.json inside it.
    static func manifestURL(from raw: String) -> URL? {
        let trimmed = raw.trimmed
        guard !trimmed.isEmpty else { return nil }
        let full = trimmed.hasSuffix("/") ? trimmed + "index.json" : trimmed
        guard let url = URL(string: full), url.scheme?.hasPrefix("http") == true, url.host != nil else { return nil }
        return url
    }

    static func kind(of item: FeedItem) -> FeedItemKind {
        if let type = item.type?.trimmed.lowercased(), !type.isEmpty {
            return type == "workout" ? .appleWorkout : .unsupported(type)
        }
        let path = item.url.lowercased()
        if path.hasSuffix(".workout") { return .appleWorkout }
        let ext = (path as NSString).pathExtension
        return .unsupported(ext.isEmpty ? "unknown" : ext)
    }

    static func label(of item: FeedItem) -> String {
        item.title ?? item.id ?? item.url
    }

    static func fetchManifest(config: AppConfig) async throws -> (manifest: FeedManifest, url: URL, raw: Data) {
        guard let url = manifestURL(from: config.feedURL) else { throw FeedError.badURL(config.feedURL) }
        let data = try await fetch(url, config: config, manifestURL: url)
        do {
            let manifest = try JSONDecoder().decode(FeedManifest.self, from: data)
            return (manifest, url, data)
        } catch {
            throw FeedError.notAManifest
        }
    }

    static func fetchItemData(_ item: FeedItem, manifestURL: URL, config: AppConfig) async throws -> Data {
        guard let url = URL(string: item.url, relativeTo: manifestURL)?.absoluteURL else {
            throw FeedError.badItemURL(label(of: item))
        }
        return try await fetch(url, config: config, manifestURL: manifestURL)
    }

    private static func fetch(_ url: URL, config: AppConfig, manifestURL: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        // Send the Authorization value only to the manifest's own origin — never to a
        // third-party file host that a manifest might reference with an absolute URL.
        if let auth = config.authHeader, !auth.isEmpty, url.host == manifestURL.host, url.port == manifestURL.port {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let what = url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
            throw FeedError.http(status, what)
        }
        return data
    }
}
