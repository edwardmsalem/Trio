import CryptoKit
import Foundation
import Testing
@testable import Trio

// Every key here is a throwaway generated in the test. The real APNs key is never used.

private func makeState(chartCount: Int, forecastCount: Int = 0, now: Date = Date()) -> LiveActivityAttributes.ContentState {
    let chart = (0 ..< chartCount).map {
        LiveActivityAttributes.ChartItem(value: Decimal(100 + $0 % 50), date: now.addingTimeInterval(-Double($0) * 300))
    }
    let forecast = (0 ..< forecastCount).map { 90 + $0 }
    return LiveActivityAttributes.ContentState(
        unit: "mg/dL",
        bg: "123",
        direction: "→",
        change: "+2",
        date: now,
        highGlucose: 180,
        lowGlucose: 70.5,
        target: 100,
        glucoseColorScheme: "staticColor",
        useDetailedViewIOS: true,
        useDetailedViewWatchOS: false,
        detailedViewState: LiveActivityAttributes.ContentAdditionalState(
            chart: chart,
            rotationDegrees: 0,
            cob: 12,
            iob: Decimal(string: "1.35")!,
            tdd: Decimal(string: "30.25")!,
            eventualBG: "110",
            isOverrideActive: false,
            overrideName: "Override",
            overrideDate: now,
            overrideDuration: 0,
            overrideTarget: 0,
            isTempTargetActive: false,
            tempTargetName: "Temp Target",
            tempTargetDate: now,
            tempTargetDuration: 0,
            tempTargetTarget: 0,
            widgetItems: [.currentGlucoseLarge, .iob, .cob, .updatedLabel],
            minForecast: forecast,
            maxForecast: forecast,
            forecastLines: forecastCount > 0 ? [LiveActivityAttributes.ForecastLine(type: "iob", values: forecast)] : [],
            forecastDisplayType: "cone"
        ),
        isInitialState: false
    )
}

private func base64URLDecode(_ string: String) -> Data? {
    var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    return Data(base64Encoded: s)
}

private func jsonObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private final class MockTransport: APNsTransport {
    var statuses: [Int]
    var body = Data()
    private(set) var requests: [URLRequest] = []

    init(statuses: [Int]) {
        self.statuses = statuses
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let status = statuses.isEmpty ? 200 : statuses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: nil)!
        return (body, response)
    }
}

@Suite("Live Activity APNs JWT") struct LiveActivityJWTTests {
    @Test("Signs a valid ES256 token with kid, iss and iat") func signsToken() throws {
        let key = P256.Signing.PrivateKey()
        let signer = try APNsJWTSigner(keyID: "ABC123DEFG", teamID: "TEAM123456", p8: key.pemRepresentation)
        let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try signer.token(issuedAt: issuedAt)

        let parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        #expect(!token.contains("="))
        #expect(!token.contains("+"))
        #expect(!token.contains("/"))

        let header = try #require(base64URLDecode(parts[0]).flatMap(jsonObject))
        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "ABC123DEFG")

        let claims = try #require(base64URLDecode(parts[1]).flatMap(jsonObject))
        #expect(claims["iss"] as? String == "TEAM123456")
        #expect(claims["iat"] as? Int == 1_800_000_000)

        let signatureData = try #require(base64URLDecode(parts[2]))
        #expect(signatureData.count == 64)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test("Accepts the key body without PEM lines, rejects junk") func parsesKeyForms() throws {
        let key = P256.Signing.PrivateKey()
        let body = key.derRepresentation.base64EncodedString()
        let parsed = try APNsJWTSigner.parsePrivateKey(body)
        #expect(parsed.publicKey.rawRepresentation == key.publicKey.rawRepresentation)

        #expect(throws: APNsJWTSigner.SignerError.emptyKey) { try APNsJWTSigner.parsePrivateKey("") }
        #expect(throws: APNsJWTSigner.SignerError.notBase64) { try APNsJWTSigner.parsePrivateKey("not base64 !!") }
        #expect(throws: APNsJWTSigner.SignerError.invalidKey) {
            try APNsJWTSigner.parsePrivateKey(Data("hello".utf8).base64EncodedString())
        }
    }

    @Test("Cache reuses a token under 50 minutes and refreshes after") func cacheLifetime() throws {
        let signer = APNsJWTSigner(keyID: "K", teamID: "T", privateKey: P256.Signing.PrivateKey())
        let cache = APNsJWTCache(signer: signer)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try cache.token(now: start)
        #expect(try cache.token(now: start.addingTimeInterval(49 * 60)) == first)

        let refreshed = try cache.token(now: start.addingTimeInterval(50 * 60))
        #expect(refreshed != first)

        cache.invalidate()
        #expect(try cache.token(now: start.addingTimeInterval(51 * 60)) != refreshed)
    }
}

@Suite("Live Activity APNs client") struct LiveActivityAPNsClientTests {
    @Test("Environment comes from the provisioning profile") func environment() {
        let dev = Data("junk<key>aps-environment</key>\n\t\t<string>development</string>junk".utf8)
        let prod = Data("junk<key>aps-environment</key>\n\t\t<string>production</string>junk".utf8)
        #expect(APNsEnvironment.fromProvisioningProfile(dev) == .sandbox)
        #expect(APNsEnvironment.fromProvisioningProfile(prod) == .production)
        #expect(APNsEnvironment.fromProvisioningProfile(Data("no push".utf8)) == .production)
        #expect(APNsEnvironment.production.host == "https://api.push.apple.com")
        #expect(APNsEnvironment.sandbox.host == "https://api.sandbox.push.apple.com")
    }

    @Test("Status codes map to token, JWT and rate-limit outcomes") func classify() {
        let reason = { (r: String) in Data(#"{"reason":"\#(r)"}"#.utf8) }
        #expect(APNsPushResult.classify(status: 200, body: Data()) == .delivered)
        #expect(APNsPushResult.classify(status: 410, body: reason("ExpiredToken")) == .badDeviceToken("ExpiredToken"))
        #expect(APNsPushResult.classify(status: 404, body: Data()) == .badDeviceToken("404"))
        #expect(APNsPushResult.classify(status: 400, body: reason("BadDeviceToken")) == .badDeviceToken("BadDeviceToken"))
        #expect(
            APNsPushResult.classify(status: 403, body: reason("ExpiredProviderToken")) ==
                .providerTokenRejected("ExpiredProviderToken")
        )
        #expect(APNsPushResult.classify(status: 429, body: reason("TooManyRequests")) == .rateLimited)
        #expect(APNsPushResult.classify(status: 503, body: Data()) == .serverError(503))
        #expect(APNsPushResult.classify(status: 400, body: reason("PayloadTooLarge")) == .failed("400 PayloadTooLarge"))
    }

    @Test("Request carries the Live Activity headers") func requestHeaders() {
        let request = LiveActivityPushBuilder.request(
            deviceToken: "abcd",
            payload: Data("{}".utf8),
            jwt: "jwt",
            bundleID: "org.nightscout.TEAM.trio",
            environment: .production,
            priority: 5,
            expiration: Date(timeIntervalSince1970: 1000),
            collapseID: nil
        )
        #expect(request.url?.absoluteString == "https://api.push.apple.com/3/device/abcd")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "authorization") == "bearer jwt")
        #expect(request.value(forHTTPHeaderField: "apns-push-type") == "liveactivity")
        #expect(request.value(forHTTPHeaderField: "apns-topic") == "org.nightscout.TEAM.trio.push-type.liveactivity")
        #expect(request.value(forHTTPHeaderField: "apns-priority") == "5")
        #expect(request.value(forHTTPHeaderField: "apns-expiration") == "1000")
        #expect(request.value(forHTTPHeaderField: "apns-collapse-id") == nil)
    }

    @Test("Start payload decodes back into the same content state") func startPayloadRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = makeState(chartCount: 12, now: now)
        let attributes = LiveActivityAttributes(startDate: now)
        let data = try LiveActivityPushBuilder.startPayload(
            state: state,
            attributes: attributes,
            staleDate: now.addingTimeInterval(360),
            now: now
        )
        let aps = try #require(jsonObject(data)?["aps"] as? [String: Any])
        #expect(aps["event"] as? String == "start")
        #expect(aps["attributes-type"] as? String == "LiveActivityAttributes")
        #expect(aps["timestamp"] as? Int == 1_800_000_000)
        #expect(aps["stale-date"] as? Int == 1_800_000_360)
        #expect((aps["alert"] as? [String: Any]) != nil)

        // Decode the way ActivityKit does: a default JSONDecoder on the raw JSON.
        let stateData = try JSONSerialization.data(withJSONObject: try #require(aps["content-state"]))
        let decoded = try JSONDecoder().decode(LiveActivityAttributes.ContentState.self, from: stateData)
        #expect(decoded.bg == state.bg)
        #expect(decoded.date == state.date)
        #expect(decoded.detailedViewState.chart.count == 12)
        let attributesData = try JSONSerialization.data(withJSONObject: try #require(aps["attributes"]))
        let decodedAttributes = try JSONDecoder().decode(LiveActivityAttributes.self, from: attributesData)
        #expect(decodedAttributes.startDate == now)
    }

    @Test("Decimals survive the payload exactly") func decimalsExact() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = makeState(chartCount: 2, now: now)
        let data = try LiveActivityPushBuilder.updatePayload(state: state, staleDate: now, now: now)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"iob\":1.35"))
        #expect(text.contains("\"lowGlucose\":70.5"))
        #expect(text.contains("\"event\":\"update\""))
    }

    @Test("A full day chart with forecasts is trimmed to fit 4 KB, newest readings kept") func fitsPayloadLimit() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = makeState(chartCount: 288, forecastCount: 48, now: now)
        let full = try JSONEncoder().encode(state)
        #expect(full.count > LiveActivityPushBuilder.maxPayloadBytes)

        let data = try LiveActivityPushBuilder.startPayload(
            state: state,
            attributes: LiveActivityAttributes(startDate: now),
            staleDate: now,
            now: now
        )
        #expect(data.count <= LiveActivityPushBuilder.maxPayloadBytes)
        let aps = try #require(jsonObject(data)?["aps"] as? [String: Any])
        let stateData = try JSONSerialization.data(withJSONObject: try #require(aps["content-state"]))
        let decoded = try JSONDecoder().decode(LiveActivityAttributes.ContentState.self, from: stateData)
        #expect(decoded.detailedViewState.minForecast.isEmpty)
        #expect(!decoded.detailedViewState.chart.isEmpty)
        #expect(decoded.detailedViewState.chart.first?.date == now)
        #expect(decoded.bg == "123")
    }

    @Test("Client sends to the token and drops a rejected JWT") func clientSendsAndInvalidates() async throws {
        let transport = MockTransport(statuses: [403, 200])
        let client = LiveActivityAPNsClient(
            signer: APNsJWTSigner(keyID: "K", teamID: "T", privateKey: P256.Signing.PrivateKey()),
            transport: transport,
            bundleID: "org.example.trio",
            environment: .sandbox
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = makeState(chartCount: 4, now: now)

        let first = await client.sendStart(
            pushToStartToken: "feed",
            state: state,
            attributes: LiveActivityAttributes(startDate: now),
            staleDate: now,
            now: now
        )
        #expect(first == .providerTokenRejected(""))
        let second = await client.sendUpdate(activityToken: "beef", state: state, staleDate: now, now: now)
        #expect(second == .delivered)

        #expect(transport.requests.count == 2)
        let start = transport.requests[0]
        #expect(start.url?.absoluteString == "https://api.sandbox.push.apple.com/3/device/feed")
        #expect(start.value(forHTTPHeaderField: "apns-priority") == "10")
        #expect(start.value(forHTTPHeaderField: "apns-collapse-id") == "org.example.trio.la.start")
        #expect(start.value(forHTTPHeaderField: "apns-topic") == "org.example.trio.push-type.liveactivity")
        let update = transport.requests[1]
        #expect(update.url?.absoluteString == "https://api.sandbox.push.apple.com/3/device/beef")
        #expect(update.value(forHTTPHeaderField: "apns-priority") == "5")
        // 403 cleared the cached JWT, so the second request was signed afresh.
        #expect(start.value(forHTTPHeaderField: "authorization") != update.value(forHTTPHeaderField: "authorization"))
    }
}

@Suite("Live Activity renewal timing") struct LiveActivityRenewalPolicyTests {
    typealias Policy = LiveActivityRenewalPolicy
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func decide(
        at offset: TimeInterval,
        active: Bool = false,
        token: Bool = true,
        state: Policy.State = Policy.State()
    ) -> (Policy.Decision, Policy.State) {
        Policy.decide(
            activityStart: start,
            now: start.addingTimeInterval(offset),
            appIsActive: active,
            hasPushToStartToken: token,
            state: state
        )
    }

    @Test("Renews at 7.5 hours in the background, not before") func renewalWindow() {
        #expect(decide(at: 7.5 * 3600 - 60).0 == .notDue)
        #expect(decide(at: 7.5 * 3600).0 == .pushToStart)
        #expect(decide(at: 9 * 3600).0 == .pushToStart)
        #expect(decide(at: 7.5 * 3600, active: true).0 == .foreground)
        #expect(decide(at: 7.5 * 3600, token: false).0 == .noToken)
    }

    @Test("Waits for the pushed activity, then counts a no-show as a failure") func adoptionTimeout() {
        let due = start.addingTimeInterval(7.5 * 3600)
        let sent = Policy.record(.sent, state: Policy.State(), now: due)
        #expect(decide(at: 7.5 * 3600 + 60, state: sent).0 == .waitingForAdoption)

        let (decision, state) = decide(at: 7.5 * 3600 + Policy.adoptionTimeout, state: sent)
        #expect(decision == .backingOff(until: due.addingTimeInterval(Policy.adoptionTimeout + Policy.baseBackoff)))
        #expect(state.pendingSince == nil)
        #expect(state.consecutiveFailures == 1)

        #expect(Policy.adopted() == Policy.State())
    }

    @Test("Backoff doubles from 5 minutes to a 60 minute cap, then retries") func backoff() {
        let now = start.addingTimeInterval(7.5 * 3600)
        var state = Policy.State()
        var steps: [TimeInterval] = []
        for _ in 0 ..< 6 {
            state = Policy.record(.rateLimited, state: state, now: now)
            steps.append(state.backoff)
        }
        #expect(steps == [300, 600, 1200, 2400, 3600, 3600])

        state = Policy.record(.failed, state: Policy.State(), now: now)
        #expect(decide(at: 7.5 * 3600 + 299, state: state).0 == .backingOff(until: now.addingTimeInterval(300)))
        #expect(decide(at: 7.5 * 3600 + 300, state: state).0 == .pushToStart)
    }

    @Test("A bad push-to-start token waits for a new token without backoff") func tokenInvalid() {
        let now = start.addingTimeInterval(7.5 * 3600)
        let state = Policy.record(.tokenInvalid, state: Policy.State(), now: now)
        #expect(state.backoffUntil == nil)
        #expect(decide(at: 7.5 * 3600 + 1, token: false, state: state).0 == .noToken)
        #expect(decide(at: 7.5 * 3600 + 1, token: true, state: state).0 == .pushToStart)
    }

    @Test("State survives being saved and loaded") func stateCodable() throws {
        let state = Policy.record(.failed, state: Policy.State(), now: start)
        let decoded = try JSONDecoder().decode(Policy.State.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }
}
