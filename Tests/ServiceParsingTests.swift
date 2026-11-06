import Foundation
import XCTest

@MainActor
final class ServiceParsingTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testRejectsUnknownUsageSchemas() {
        for raw in ["{}", "{\"error\":\"temporary failure\"}", "{\"new_schema\":42}"] {
            XCTAssertThrowsError(try ClaudeClient.parseUsage(data(raw)), raw)
            XCTAssertThrowsError(try ChatGPTClient.parseUsage(data(raw)), raw)
        }
        XCTAssertThrowsError(try ClaudeClient.parseOrganizations(data("{}")))
        XCTAssertThrowsError(try ChatGPTClient.parseSession(data("{\"error\":\"unavailable\"}")))
        XCTAssertNil(try ChatGPTClient.parseSession(data("{}")))
    }

    func testNumericInputRejectsBooleansAndNonfiniteValues() {
        XCTAssertNil(JSONValue.number(NSNumber(value: true)))
        XCTAssertNil(JSONValue.number(NSNumber(value: false)))
        XCTAssertNil(JSONValue.number(Double.infinity))
        for value in ["NaN", "Infinity", "-Infinity", "1e100", "-1", "101"] {
            let claude = "{\"five_hour\":{\"utilization\":\"\(value)\"}}"
            let chatgpt = "{\"rate_limit\":{\"primary_window\":{\"used_percent\":\"\(value)\"}}}"
            XCTAssertThrowsError(try ClaudeClient.parseUsage(data(claude)), value)
            XCTAssertThrowsError(try ChatGPTClient.parseUsage(data(chatgpt)), value)
        }
        XCTAssertThrowsError(try ClaudeClient.parseUsage(data("{\"five_hour\":{\"utilization\":true}}")))
        XCTAssertEqual(JSONValue.number(" 42.5% "), 42.5)
    }

    func testClaudeLegacyAndScopedModelWindowsAndExtraUsage() throws {
        let result = try ClaudeClient.parseUsage(data("""
        {
          "five_hour": {"utilization": "37.5", "resets_at": "2026-11-06T12:30:00.000Z"},
          "seven_day": {"utilization": 62, "resets_at": "2026-11-10T12:30:00Z"},
          "seven_day_sonnet": {"utilization": 25},
          "limits": [{"kind": "weekly_scoped", "percent": 41,
                      "scope": {"model": {"display_name": "Sonnet"}}}],
          "extra_usage": {"is_enabled": true, "monthly_limit": 2000, "used_credits": 420, "currency": "USD"}
        }
        """))
        XCTAssertEqual(result.primary?.percent, 37.5)
        XCTAssertNotNil(result.primary?.resetsAt)
        XCTAssertNotNil(result.secondary?.resetsAt)
        XCTAssertEqual(result.models.count, 1)
        XCTAssertEqual(result.models.first?.percent, 41)
        XCTAssertEqual(result.extra?.used, 4.2)
        XCTAssertEqual(result.extra?.limit, 20)
    }

    func testExplicitEmptyWindowsAreValid() throws {
        let claude = try ClaudeClient.parseUsage(data("{\"five_hour\":null,\"seven_day\":null}"))
        XCTAssertNil(claude.primary)
        XCTAssertNil(claude.secondary)
        let chatgpt = try ChatGPTClient.parseUsage(data("{\"rate_limit\":{\"primary_window\":null,\"secondary_window\":null}}"))
        XCTAssertNil(chatgpt.primary)
        XCTAssertNil(chatgpt.secondary)
        XCTAssertNoThrow(try ChatGPTClient.parseUsage(data("{\"plan_type\":\"free\",\"rate_limit\":null}")))
        XCTAssertThrowsError(try ChatGPTClient.parseUsage(data("{\"rate_limit\":{}}")))
        XCTAssertThrowsError(try ClaudeClient.parseUsage(data("{\"five_hour\":{}}")))
    }

    func testChatGPTResetRepresentationsAndCustomWindow() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for at in ["1700003600", "1700003600000"] {
            let result = try ChatGPTClient.parseUsage(data("""
            {"plan_type":"plus","rate_limit":{"primary_window":{
              "used_percent":12,"reset_at":\(at),"limit_window_seconds":2592000
            },"secondary_window":null}}
            """), now: now)
            XCTAssertEqual(result.primary?.resetsAt, now.addingTimeInterval(3600))
            XCTAssertEqual(result.primary?.seconds, 2_592_000)
            XCTAssertEqual(result.plan, "Plus")
        }
        let fallback = try ChatGPTClient.parseUsage(data("""
        {"rate_limit":{"primary_window":{"used_percent":0,"reset_at":0,"reset_after_seconds":600}}}
        """), now: now)
        XCTAssertEqual(fallback.primary?.resetsAt, now.addingTimeInterval(600))
        XCTAssertEqual(fallback.primary?.seconds, UsageWindow.fiveHours)
    }

    func testRejectsMalformedWindowsAndMoney() {
        for field in ["\"limit_window_seconds\":0", "\"limit_window_seconds\":-1",
                      "\"limit_window_seconds\":true", "\"reset_at\":\"NaN\"", "\"reset_after_seconds\":-1"] {
            XCTAssertThrowsError(try ChatGPTClient.parseUsage(data("""
            {"rate_limit":{"primary_window":{"used_percent":5,\(field)}}}
            """)), field)
        }
        XCTAssertThrowsError(try ClaudeClient.parseUsage(data("""
        {"five_hour":{"utilization":5,"resets_at":"not-a-date"}}
        """)))
        XCTAssertThrowsError(try ClaudeClient.parseUsage(data("""
        {"extra_usage":{"is_enabled":true,"monthly_limit":1000,"used_credits":-1}}
        """)))
    }

    func testAuthenticationFailuresDistinguishForbiddenChallenge() throws {
        let client = ClaudeClient()
        XCTAssertThrowsError(try client.check(401)) { error in
            guard case ServiceError.loggedOut = error else { return XCTFail("Expected expired session") }
        }
        XCTAssertThrowsError(try client.check(403, body: data("<html>challenge</html>"))) { error in
            guard case ServiceError.http(_, 403) = error else { return XCTFail("Challenge must retain cached data") }
        }
        XCTAssertThrowsError(try client.check(403, body: data("{\"error\":{\"type\":\"authentication_error\"}}"))) { error in
            guard case ServiceError.loggedOut = error else { return XCTFail("Expected explicit authentication error") }
        }
        XCTAssertNoThrow(try client.check(200))
    }
}
