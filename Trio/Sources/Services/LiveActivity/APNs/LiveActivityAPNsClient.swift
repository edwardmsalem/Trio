import Foundation

/// Which APNs gateway the app's push tokens belong to.
enum APNsEnvironment: Equatable {
    case production
    case sandbox

    var host: String {
        switch self {
        case .production: return "https://api.push.apple.com"
        case .sandbox: return "https://api.sandbox.push.apple.com"
        }
    }

    /// TestFlight and App Store builds are signed with a distribution profile
    /// (`aps-environment` production) or carry no profile at all. Builds run from
    /// Xcode carry a development profile and get sandbox tokens.
    static let current: APNsEnvironment = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url)
        else { return .production }
        return fromProvisioningProfile(data)
    }()

    static func fromProvisioningProfile(_ data: Data) -> APNsEnvironment {
        // The profile is a CMS envelope around a plain XML plist, so the
        // entitlement can be read without decoding the signature.
        let text = String(decoding: data, as: UTF8.self)
        guard let keyRange = text.range(of: "<key>aps-environment</key>") else { return .production }
        let rest = text[keyRange.upperBound...].prefix(200)
        return rest.contains("<string>development</string>") ? .sandbox : .production
    }
}

/// What APNs said about one push.
enum APNsPushResult: Equatable {
    case delivered
    /// 400 BadDeviceToken, 404, 410: the push token is gone or wrong.
    case badDeviceToken(String)
    /// 403: APNs refused the provider token (JWT).
    case providerTokenRejected(String)
    /// 429: too many pushes to this token.
    case rateLimited
    case serverError(Int)
    case failed(String)

    static func classify(status: Int, body: Data) -> APNsPushResult {
        let reason = (try? JSONDecoder().decode(APNsErrorBody.self, from: body))?.reason ?? ""
        switch status {
        case 200: return .delivered
        case 404,
             410: return .badDeviceToken(reason.isEmpty ? "\(status)" : reason)
        case 400 where reason == "BadDeviceToken" || reason == "DeviceTokenNotForTopic":
            return .badDeviceToken(reason)
        case 403: return .providerTokenRejected(reason)
        case 429: return .rateLimited
        case 500 ... 599: return .serverError(status)
        default: return .failed("\(status) \(reason)")
        }
    }

    private struct APNsErrorBody: Decodable {
        let reason: String?
    }
}

protocol APNsTransport {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: APNsTransport {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

/// Builds Live Activity push payloads and requests. Pure, so it can be tested
/// without a network.
enum LiveActivityPushBuilder {
    /// APNs caps a Live Activity payload at 4 KB.
    static let maxPayloadBytes = 4096

    enum BuildError: Error {
        case tooLarge
    }

    /// ActivityKit decodes `content-state` and `attributes` with a default
    /// JSONDecoder, so they are encoded with a default JSONEncoder (dates as
    /// seconds since 2001) and spliced into the payload as raw JSON. Going through
    /// JSONSerialization would turn Decimals into lossy doubles.
    static func startPayload(
        state: LiveActivityAttributes.ContentState,
        attributes: LiveActivityAttributes,
        staleDate: Date,
        now: Date
    ) throws -> Data {
        let attributesJSON = try String(decoding: JSONEncoder().encode(attributes), as: UTF8.self)
        for candidate in pushCandidates(state) {
            let stateJSON = try String(decoding: JSONEncoder().encode(candidate), as: UTF8.self)
            let payload = "{\"aps\":{"
                + "\"timestamp\":\(Int(now.timeIntervalSince1970)),"
                + "\"event\":\"start\","
                + "\"attributes-type\":\"LiveActivityAttributes\","
                + "\"attributes\":\(attributesJSON),"
                + "\"content-state\":\(stateJSON),"
                + "\"stale-date\":\(Int(staleDate.timeIntervalSince1970)),"
                // iOS drops a push-to-start without an alert. Empty and passive
                // keeps the phone and watch quiet (as LoopFollow does).
                + "\"alert\":{\"title\":\"\",\"body\":\"\"},"
                + "\"interruption-level\":\"passive\""
                + "}}"
            let data = Data(payload.utf8)
            if data.count <= maxPayloadBytes { return data }
        }
        throw BuildError.tooLarge
    }

    static func updatePayload(
        state: LiveActivityAttributes.ContentState,
        staleDate: Date,
        now: Date
    ) throws -> Data {
        for candidate in pushCandidates(state) {
            let stateJSON = try String(decoding: JSONEncoder().encode(candidate), as: UTF8.self)
            let payload = "{\"aps\":{"
                + "\"timestamp\":\(Int(now.timeIntervalSince1970)),"
                + "\"event\":\"update\","
                + "\"content-state\":\(stateJSON),"
                + "\"stale-date\":\(Int(staleDate.timeIntervalSince1970))"
                + "}}"
            let data = Data(payload.utf8)
            if data.count <= maxPayloadBytes { return data }
        }
        throw BuildError.tooLarge
    }

    /// The full state first, then lighter versions: forecasts dropped, then the
    /// chart cut to its newest readings. The app replaces the light state with the
    /// full one locally as soon as it adopts the new activity.
    static func pushCandidates(_ state: LiveActivityAttributes.ContentState) -> [LiveActivityAttributes.ContentState] {
        var candidates = [state]
        let detail = state.detailedViewState
        var chartCount = detail.chart.count
        candidates.append(state.replacingDetail(detail.replacing(chart: detail.chart, dropForecasts: true)))
        while chartCount > 0 {
            chartCount /= 2
            let chart = Array(detail.chart.prefix(chartCount))
            candidates.append(state.replacingDetail(detail.replacing(chart: chart, dropForecasts: true)))
        }
        return candidates
    }

    static func request(
        deviceToken: String,
        payload: Data,
        jwt: String,
        bundleID: String,
        environment: APNsEnvironment,
        priority: Int,
        expiration: Date?,
        collapseID: String?
    ) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(environment.host)/3/device/\(deviceToken)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        request.setValue("\(bundleID).push-type.liveactivity", forHTTPHeaderField: "apns-topic")
        request.setValue("\(priority)", forHTTPHeaderField: "apns-priority")
        if let expiration {
            request.setValue("\(Int(expiration.timeIntervalSince1970))", forHTTPHeaderField: "apns-expiration")
        }
        if let collapseID {
            request.setValue(collapseID, forHTTPHeaderField: "apns-collapse-id")
        }
        request.httpBody = payload
        return request
    }
}

/// Sends Live Activity pushes straight from the phone to APNs, signed with the
/// build's APNs key. Modelled on LoopFollow's APNSClient.
final class LiveActivityAPNsClient {
    /// Routine updates. Priority 5 does not count against the Live Activity budget.
    static let routinePriority = 5
    /// Push-to-start and anything that must show now. Budgeted, so used sparingly.
    static let urgentPriority = 10

    private let jwtCache: APNsJWTCache
    private let transport: APNsTransport
    private let bundleID: String
    private let environment: APNsEnvironment

    init(
        signer: APNsJWTSigner,
        transport: APNsTransport = URLSession(configuration: .ephemeral),
        bundleID: String = Bundle.main.bundleIdentifier ?? "",
        environment: APNsEnvironment = .current
    ) {
        jwtCache = APNsJWTCache(signer: signer)
        self.transport = transport
        self.bundleID = bundleID
        self.environment = environment
    }

    /// Starts a new Live Activity through the type's push-to-start token.
    func sendStart(
        pushToStartToken: String,
        state: LiveActivityAttributes.ContentState,
        attributes: LiveActivityAttributes,
        staleDate: Date,
        now: Date = Date()
    ) async -> APNsPushResult {
        let payload: Data
        do {
            payload = try LiveActivityPushBuilder.startPayload(
                state: state,
                attributes: attributes,
                staleDate: staleDate,
                now: now
            )
        } catch {
            return .failed("payload: \(error)")
        }
        // A start older than 10 minutes would show stale glucose, so let APNs
        // drop it. The collapse id stops two racing sends making two activities.
        return await send(
            token: pushToStartToken,
            payload: payload,
            priority: Self.urgentPriority,
            expiration: now.addingTimeInterval(10 * 60),
            collapseID: "\(bundleID).la.start",
            now: now
        )
    }

    /// Updates a running Live Activity through its own push token.
    func sendUpdate(
        activityToken: String,
        state: LiveActivityAttributes.ContentState,
        staleDate: Date,
        priority: Int = LiveActivityAPNsClient.routinePriority,
        now: Date = Date()
    ) async -> APNsPushResult {
        let payload: Data
        do {
            payload = try LiveActivityPushBuilder.updatePayload(state: state, staleDate: staleDate, now: now)
        } catch {
            return .failed("payload: \(error)")
        }
        return await send(
            token: activityToken,
            payload: payload,
            priority: priority,
            expiration: now.addingTimeInterval(10 * 60),
            collapseID: nil,
            now: now
        )
    }

    private func send(
        token: String,
        payload: Data,
        priority: Int,
        expiration: Date?,
        collapseID: String?,
        now: Date
    ) async -> APNsPushResult {
        let jwt: String
        do {
            jwt = try jwtCache.token(now: now)
        } catch {
            return .failed("jwt: \(error)")
        }
        let request = LiveActivityPushBuilder.request(
            deviceToken: token,
            payload: payload,
            jwt: jwt,
            bundleID: bundleID,
            environment: environment,
            priority: priority,
            expiration: expiration,
            collapseID: collapseID
        )
        do {
            let (data, response) = try await transport.send(request)
            guard let http = response as? HTTPURLResponse else { return .failed("no HTTP response") }
            let result = APNsPushResult.classify(status: http.statusCode, body: data)
            if case .providerTokenRejected = result {
                jwtCache.invalidate()
            }
            return result
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

extension LiveActivityAttributes.ContentState {
    func replacingDetail(_ detail: LiveActivityAttributes.ContentAdditionalState) -> Self {
        Self(
            unit: unit,
            bg: bg,
            direction: direction,
            change: change,
            date: date,
            highGlucose: highGlucose,
            lowGlucose: lowGlucose,
            target: target,
            glucoseColorScheme: glucoseColorScheme,
            useDetailedViewIOS: useDetailedViewIOS,
            useDetailedViewWatchOS: useDetailedViewWatchOS,
            detailedViewState: detail,
            isInitialState: isInitialState
        )
    }
}

extension LiveActivityAttributes.ContentAdditionalState {
    func replacing(chart: [LiveActivityAttributes.ChartItem], dropForecasts: Bool) -> Self {
        Self(
            chart: chart,
            rotationDegrees: rotationDegrees,
            cob: cob,
            iob: iob,
            tdd: tdd,
            eventualBG: eventualBG,
            isOverrideActive: isOverrideActive,
            overrideName: overrideName,
            overrideDate: overrideDate,
            overrideDuration: overrideDuration,
            overrideTarget: overrideTarget,
            isTempTargetActive: isTempTargetActive,
            tempTargetName: tempTargetName,
            tempTargetDate: tempTargetDate,
            tempTargetDuration: tempTargetDuration,
            tempTargetTarget: tempTargetTarget,
            widgetItems: widgetItems,
            minForecast: dropForecasts ? [] : minForecast,
            maxForecast: dropForecasts ? [] : maxForecast,
            forecastLines: dropForecasts ? [] : forecastLines,
            forecastDisplayType: forecastDisplayType
        )
    }
}
