import XCTest
@testable import CovenPocket

@MainActor
final class CompanionChatLaunchRaceTests: XCTestCase {
    // swiftlint:disable:next function_body_length
    func testInvalidatedLaunchFinalizerCannotDiscardNewerAdoptedSession() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        client.suspendsLaunch = true
        client.suspendsKill = true
        let model = CompanionChatModel(client: client)
        let familiar = FamiliarIdentity(
            id: "forge",
            displayName: "Forge",
            emoji: nil,
            role: "Builder"
        )

        let sendA = Task {
            await model.send(
                prompt: "stale",
                projectRoot: "/srv/a",
                familiarID: "sage"
            )
        }
        await fulfillment(of: [client.launchRequested], timeout: 1)

        let refreshed = await model.refreshAvailability()
        XCTAssertTrue(refreshed)
        client.launchResponseID = "session-b"
        client.resumeLaunch(id: "session-a", projectRoot: "/srv/a")
        await fulfillment(of: [client.killRequested], timeout: 1)

        var sendB: Task<Void, Never>?
        let observation = model.$isBusy
            .dropFirst()
            .filter { !$0 }
            .prefix(1)
            .sink { _ in
                sendB = Task {
                    await model.send(
                        prompt: "current",
                        projectRoot: "/srv/b",
                        familiarID: familiar.id,
                        familiar: familiar,
                        familiarProfile: .companion(pairing: pairing)
                    )
                }
            }

        client.resumeKill()
        await fulfillment(of: [client.secondLaunchRequested], timeout: 1)
        await sendB?.value
        await sendA.value

        XCTAssertEqual(model.session?.id, "session-b")
        XCTAssertEqual(model.sessionProjectRoot, "/srv/b")
        XCTAssertEqual(model.sessionFamiliarID, familiar.id)
        XCTAssertEqual(model.sessionFamiliar, familiar)
        XCTAssertEqual(model.pairing, pairing)
        XCTAssertEqual(model.sessionVerifiedPairing?.pairing, pairing)
        XCTAssertEqual(
            model.sessionVerifiedPairing?.availabilityGeneration,
            model.availabilityGeneration
        )
        XCTAssertTrue(model.hasActivePollTask)
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.canRetry)
        XCTAssertNil(model.retryPrompt)
        XCTAssertNil(model.retryFamiliarID)
        XCTAssertEqual(model.items.map(\.text), ["current"])
        XCTAssertFalse(model.items.contains { $0.kind == .error })
        XCTAssertEqual(client.killedSessionIDs, ["session-a"])
        withExtendedLifetime(observation) {}

        await model.reset()
    }
}
