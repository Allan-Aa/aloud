import XCTest
@testable import Aloud

final class NoExternalCredentialAccessTests: XCTestCase {
    func testCompositionNamesEveryInjectedExternalBoundaryIndependently() {
        let expected: Set<String> = [
            "keychainRead", "keychainUpdate", "keychainAdd", "keychainDelete",
            "onePassword", "miniMaxHTTP", "openAIHTTP", "geminiHTTP",
            "accountCatalog", "systemSpeechCatalog", "systemSpeechWrite",
            "player", "wavProcess", "storeRead", "storeWrite",
            "systemPasteboard", "screenshot", "clock", "diagnostics",
            "browserLogin", "cliLogin", "chatGPTSession", "geminiSession",
        ]
        XCTAssertEqual(Set(ExternalServiceName.allCases.map(\.rawValue)), expected)
    }

    func testFakeReleaseExternalServicesAreTripwiresWithContentFreeNames() {
        let tripwire = ExternalServiceTripwire()
        for service in ExternalServiceName.allCases { XCTAssertThrowsError(try tripwire.call(service)) }
        XCTAssertEqual(tripwire.calls, Set(ExternalServiceName.allCases))
    }

    func testProductionCompositionDeclaresEveryForbiddenExternalBoundaryAsTripwireable() throws {
        let source = try String(contentsOf: projectRoot().appendingPathComponent("Sources/Aloud/AppCompositionRoot.swift"), encoding: .utf8)
        for service in ExternalServiceName.allCases {
            XCTAssertTrue(source.contains("case \(service.rawValue)"), "missing boundary \(service.rawValue)")
        }
        XCTAssertFalse(source.contains("secret:"))
        XCTAssertFalse(source.contains("apiKey:"))
    }

    func testCompositionHasOneDependencyOnlyBuilderAndKeepsLiveConstructorsOutsideIt() throws {
        let source = try String(contentsOf: projectRoot().appendingPathComponent("Sources/Aloud/AppCompositionRoot.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("static func build(dependencies:"))
        let builder = try XCTUnwrap(source.range(of: "static func build(dependencies:"))
        let live = try XCTUnwrap(source.range(of: "static func liveDependencies"))
        let body = String(source[builder.lowerBound..<live.lowerBound])
        for forbidden in [
            "SecurityKeychainClient(", "ProcessOnePasswordLauncher(",
            "URLSessionMiniMaxHTTPClient(", "URLSessionOpenAIHTTPClient(",
            "URLSessionGeminiHTTPClient(", "Player.shared", "FoundationWAVProcessDriver(",
            "NSPasteboard.general", "DirectoryScreenshotSink(", "Date()", "Diag.record("
        ] {
            XCTAssertFalse(body.contains(forbidden), forbidden)
        }
        for dependency in [
            "credentialStore", "onePassword", "miniMaxHTTP", "openAIHTTP", "geminiHTTP",
            "accountSnapshot", "player", "wavProcessDriver", "storeOperations", "pasteboard",
            "screenshot", "clock", "diagnostics"
        ] {
            XCTAssertTrue(source.contains("let \(dependency)"), dependency)
        }
    }

    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
