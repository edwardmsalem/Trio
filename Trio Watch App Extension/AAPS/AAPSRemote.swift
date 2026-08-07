import Foundation

/// Talks to the relay so a bolus can be asked for with the phone nowhere nearby.
///
/// The watch never decides how much insulin to give. It asks, AAPS answers with the
/// amount it is actually willing to deliver after applying the user's limits, and only
/// that answered figure can be confirmed. So the number on the confirm screen is always
/// the number that will be delivered — never the number that was dialled.
actor AAPSRemote {
    static let shared = AAPSRemote()

    private let baseURL = URL(string: "https://codex-proxy.ticketunity.com")!

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        // A watch on cellular is slower and flakier than a phone; give it room, but not
        // so much that a dead relay leaves the user staring at a spinner.
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    struct Quote {
        let insulin: Double
        let carbs: Int
        let requested: Double
        let message: String
        let refused: String?

        /// True when AAPS is giving less than was asked for, which the user must see.
        var wasTrimmed: Bool { refused == nil && requested > 0 && insulin < requested - 0.0001 }
    }

    struct Outcome {
        let status: String
        let message: String
    }

    enum RemoteError: LocalizedError {
        case http(Int)
        case malformed
        case timedOut

        var errorDescription: String? {
            switch self {
            case let .http(code): return "Relay error (\(code))"
            case .malformed: return "Unexpected reply from relay"
            case .timedOut: return "Phone did not answer"
            }
        }
    }

    // MARK: - Sending

    /// Asks AAPS to price a bolus. Returns the command id used to follow it up.
    func requestBolus(insulin: Double, carbs: Int) async throws -> String {
        let body: [String: Any] = ["kind": "bolus_request", "insulin": insulin, "carbs": carbs]
        let json = try await post("/aaps/command", body)
        guard let id = json["id"] as? String else { throw RemoteError.malformed }
        return id
    }

    /// Approves a specific earlier request. The id is required by the phone, so a
    /// confirmation cannot land on a different request than the one that was read.
    func confirmBolus(confirming requestId: String) async throws {
        _ = try await post("/aaps/command", [
            "kind": "bolus_confirm",
            "confirms": requestId
        ])
    }

    func cancel() async {
        _ = try? await post("/aaps/command", ["kind": "cancel"])
    }

    // MARK: - Waiting

    /// Waits for AAPS to say what it will give. Gives up rather than hanging forever.
    func awaitQuote(for id: String, timeout: TimeInterval = 15) async throws -> Quote {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let json = try await get("/aaps/status?id=\(id)")
            if let q = json["quote"] as? [String: Any] {
                return Quote(
                    insulin: q["insulin"] as? Double ?? 0,
                    carbs: q["carbs"] as? Int ?? 0,
                    requested: q["requested_insulin"] as? Double ?? 0,
                    message: q["message"] as? String ?? "",
                    refused: q["refused"] as? String
                )
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        throw RemoteError.timedOut
    }

    func awaitOutcome(for id: String, timeout: TimeInterval = 20) async -> Outcome? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let json = try? await get("/aaps/status?id=\(id)"),
               let r = json["result"] as? [String: Any]
            {
                return Outcome(
                    status: r["status"] as? String ?? "unknown",
                    message: r["message"] as? String ?? ""
                )
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        return nil
    }

    // MARK: - Transport

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(AAPSDevKeys.relaySecret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request)
    }

    private func get(_ path: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        request.setValue("Bearer \(AAPSDevKeys.relaySecret)", forHTTPHeaderField: "Authorization")
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteError.malformed }
        guard (200 ..< 300).contains(http.statusCode) else { throw RemoteError.http(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteError.malformed
        }
        return json
    }
}
