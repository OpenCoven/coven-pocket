import XCTest
@testable import CovenPocket

final class SpikeViewTests: XCTestCase {
    func testCleanupActionIsAccessibleAndIndependentOfAccountRows() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: appRoot.appendingPathComponent(
                "Sources/Views/SpikeView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains(
                """
                providerSection
                                authenticationCleanupSection
                                promptSection
                """
            )
        )
        let cleanupStart = try XCTUnwrap(
            source.range(of: "private var authenticationCleanupSection")
        )
        let cleanupEnd = try XCTUnwrap(
            source.range(
                of: "private var promptSection",
                range: cleanupStart.upperBound..<source.endIndex
            )
        )
        let cleanupSource = source[
            cleanupStart.lowerBound..<cleanupEnd.lowerBound
        ]

        XCTAssertTrue(
            cleanupSource.contains(
                "if client.authenticationCleanupRequired"
            )
        )
        XCTAssertTrue(cleanupSource.contains("Button(\"Finish sign out\")"))
        XCTAssertTrue(
            cleanupSource.contains("client.retryAuthenticationCleanup()")
        )
        XCTAssertTrue(
            cleanupSource.contains(
                """
                .accessibilityHint(
                                    "Retries removal of persisted Codex credentials."
                                )
                """
            )
        )
        XCTAssertFalse(cleanupSource.contains("client.codexAccount"))
    }
}
