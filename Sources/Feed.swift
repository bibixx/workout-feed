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
    case http(Int, String, String?)
    case transport(String, String)
    case notHTTP(String)
    case notAManifest
    case badItemURL(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add a feed first."
        case .badURL(let url):
            return "“\(url)” isn't a valid URL."
        case .http(let code, let what, let body):
            let base = "The feed returned HTTP \(code) for \(what)"
            guard let body else { return base + "." }
            return base + " — \(body)"
        case .transport(let what, let reason):
            return "Couldn't load \(what) — \(reason)."
        case .notHTTP(let what):
            return "The feed returned a non-HTTP response for \(what)."
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
        let what = url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FeedError.transport(what, reason(for: error, url: url))
        }
        guard let http = response as? HTTPURLResponse else { throw FeedError.notHTTP(what) }
        guard (200..<300).contains(http.statusCode) else {
            throw FeedError.http(http.statusCode, what, bodySnippet(data, response: http))
        }
        return data
    }

    private static func reason(for error: Error, url: URL) -> String {
        guard let urlError = error as? URLError else { return withoutTrailingPeriod(error.localizedDescription) }
        switch urlError.code {
        case .appTransportSecurityRequiresSecureConnection:
            return "iOS blocked the insecure connection — use “https”"
        case .timedOut:
            return "the request timed out"
        case .notConnectedToInternet:
            return "no internet connection"
        case .networkConnectionLost:
            return "the connection was lost"
        case .cannotFindHost, .dnsLookupFailed:
            return "couldn't find the server \(url.host ?? "")"
        case .cannotConnectToHost:
            return "couldn't connect to \(url.host ?? "the server")"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "secure connection failed"
        default:
            return withoutTrailingPeriod(urlError.localizedDescription)
        }
    }

    /// The transport message appends its own "." — Foundation's descriptions bring one too.
    private static func withoutTrailingPeriod(_ text: String) -> String {
        let trimmed = text.trimmed
        return trimmed.hasSuffix(".") && !trimmed.hasSuffix("...") ? String(trimmed.dropLast()) : trimmed
    }

    /// Error bodies are echoed verbatim — any feed can say anything, so no parsing or field
    /// extraction — but only textual ones; never dump a binary body into the UI.
    private static func bodySnippet(_ data: Data, response: HTTPURLResponse) -> String? {
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard contentType.contains("json") || contentType.contains("text") else { return nil }
        guard let text = String(data: data, encoding: .utf8)?.trimmed, !text.isEmpty else { return nil }
        return text.count > 140 ? String(text.prefix(140)) + "…" : text
    }
}
