import Foundation

/// Streaming HTTP client for the Trio Coach.
///
/// Mirrors the SSE streaming core of `BaseClaudeNutritionService` (the AI Meal
/// Advisor). It talks to the same codex-proxy bridge but to the Coach-specific
/// routes, which the proxy relays to the `trio-coach` OpenClaw agent:
///   POST /coach/chat   — streamed advisory chat (text/event-stream)
///   GET  /coach/notes  — the coach's notes feed (read-only JSON)
///
/// The proxy holds the gateway token and the read-only Nightscout token, so
/// neither ever reaches the phone. This client only ever sends the chat bearer.
///
/// ADVISORY ONLY: there is no apply/dose path anywhere in this module.
final class CoachService {
    private let proxyURL: String
    private let proxySecret: String

    /// The coach is a research agent: it can spend 30-90s thinking and pulling
    /// sources before the gateway returns its (single, non-incremental) reply.
    /// `URLSession.shared` defaults to a 60s request timeout, which silently
    /// killed slow replies and surfaced as "something went wrong". A dedicated
    /// session with generous timeouts is what keeps long answers from failing.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    /// Thread id for the active coach conversation. Persisted by `CoachInbox`
    /// so the coach keeps cross-session memory (the OpenClaw agent replays full
    /// context server-side when the same id is sent back).
    var threadId: String?

    init() {
        proxyURL = CoachDevKeys.coachProxyURL
        proxySecret = CoachDevKeys.coachProxySecret
    }

    // MARK: - Chat

    /// Sends one user turn and streams the coach's reply token-by-token.
    ///
    /// The proxy emits the same SSE envelope as the Meal Advisor `/chat` route:
    ///   data: {"type":"text_delta","text":"..."}
    ///   data: {"type":"done","thread_id":"<id>"}
    ///   data: {"type":"error","message":"..."}
    func send(_ text: String) async throws -> AsyncStream<String> {
        var request = URLRequest(url: try buildURL("/coach/chat"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(proxySecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180

        var body: [String: Any] = [
            "messages": [["role": "user", "content": text]]
        ]
        if let tid = threadId {
            body["thread_id"] = tid
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200 ... 299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CoachServiceError.apiError(statusCode: code)
        }

        return AsyncStream { continuation in
            Task {
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonString = String(line.dropFirst(6))
                        guard let jsonData = jsonString.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                        else { continue }

                        let type = event["type"] as? String ?? ""

                        switch type {
                        case "text_delta":
                            if let text = event["text"] as? String, !text.isEmpty {
                                continuation.yield(text)
                            }
                        case "done":
                            if let tid = event["thread_id"] as? String {
                                await MainActor.run { self.threadId = tid }
                            }
                            continuation.finish()
                            return
                        case "error":
                            let msg = event["message"] as? String ?? "stream error"
                            debug(.default, "[coach-proxy] error: \(msg)")
                            continuation.finish()
                            return
                        default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    debug(.default, "[coach-proxy] stream failed: \(error.localizedDescription)")
                    continuation.finish()
                }
            }
        }
    }

    func resetThread() {
        threadId = nil
    }

    // MARK: - Notes feed

    /// Reads the coach's notes feed. `since` is an opaque cursor returned by a
    /// previous call; pass nil for the full current feed. Read-only — the phone
    /// never sees the volume filesystem, only the JSON the proxy returns.
    func fetchNotes(since: String?) async throws -> (notes: [CoachNote], cursor: String?) {
        var components = URLComponents(url: try buildURL("/coach/notes"), resolvingAgainstBaseURL: false)
        if let since, !since.isEmpty {
            components?.queryItems = [URLQueryItem(name: "since", value: since)]
        }
        guard let url = components?.url else {
            throw CoachServiceError.apiError(statusCode: -1)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(proxySecret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200 ... 299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CoachServiceError.apiError(statusCode: code)
        }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoachServiceError.parseError
        }

        let cursor = payload["cursor"] as? String
        let rawNotes = (payload["notes"] as? [[String: Any]]) ?? []

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        let notes: [CoachNote] = rawNotes.compactMap { dict in
            guard let id = dict["id"] as? String else { return nil }
            let title = (dict["title"] as? String) ?? ""
            let bodyText = (dict["body"] as? String) ?? ""

            var date = Date()
            if let dateString = dict["date"] as? String {
                date = iso.date(from: dateString) ?? isoPlain.date(from: dateString) ?? Date()
            } else if let epoch = dict["date"] as? Double {
                date = Date(timeIntervalSince1970: epoch)
            }

            return CoachNote(id: id, date: date, title: title, body: bodyText)
        }

        return (notes, cursor)
    }

    // MARK: - Helpers

    private func buildURL(_ path: String) throws -> URL {
        let base = proxyURL.hasSuffix("/") ? String(proxyURL.dropLast()) : proxyURL
        guard let url = URL(string: base + path) else {
            throw CoachServiceError.apiError(statusCode: -1)
        }
        return url
    }
}

// MARK: - Errors

enum CoachServiceError: LocalizedError {
    case apiError(statusCode: Int)
    case parseError

    var errorDescription: String? {
        switch self {
        case let .apiError(code): return "Coach proxy error (code: \(code))"
        case .parseError: return "Couldn't read the coach's response."
        }
    }
}
