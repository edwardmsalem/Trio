import Foundation

// Coach talks to the SAME codex-proxy as the AI Meal Advisor (same host, same
// shared secret) — only the route differs (/coach/chat). Deriving from
// MealScanDevKeys means the keys CI already generates cover Coach too, so there
// is no separate secret to manage and nothing gitignored that could break CI.
enum CoachDevKeys {
    static let coachProxyURL = MealScanDevKeys.codexProxyURL
    static let coachProxySecret = MealScanDevKeys.codexProxySecret
}
