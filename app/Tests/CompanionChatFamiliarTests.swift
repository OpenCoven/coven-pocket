import XCTest
@testable import CovenPocket

// swiftlint:disable file_length

@MainActor
// swiftlint:disable:next type_body_length
final class CompanionChatFamiliarTests: XCTestCase {
    func testChangingFamiliarKillsOldSessionBeforeLaunchingReplacement() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )
        completeTurn(on: model)

        await model.send(
            prompt: "second",
            projectRoot: "/srv/repo",
            familiarID: "forge"
        )

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage", "forge"])
        XCTAssertEqual(
            client.operationLog,
            ["launch:sage", "kill:session-1", "launch:forge"]
        )
        XCTAssertEqual(model.sessionFamiliarID, "forge")
    }

    func testSameProjectAndFamiliarReuseSession() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        let profile = FamiliarProfileKey.companion(pairing: pairedDaemon())
        let firstPresentation = companionFamiliar(
            id: "sage",
            name: "Sage on A",
            emoji: "🅰️",
            role: "A role"
        )
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage",
            familiar: firstPresentation,
            familiarProfile: profile
        )
        completeTurn(on: model)

        await model.send(
            prompt: "second",
            projectRoot: "/srv/repo",
            familiarID: "sage",
            familiar: companionFamiliar(
                id: "sage",
                name: "Relabeled Sage",
                emoji: "🅱️",
                role: "B role"
            ),
            familiarProfile: profile
        )

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage"])
        XCTAssertEqual(client.sentInputs, ["second"])
        XCTAssertTrue(client.killedSessionIDs.isEmpty)
        XCTAssertEqual(model.sessionFamiliar, firstPresentation)
    }

    func testAddingFamiliarReplacesIdentitylessSession() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        completeTurn(on: model)

        await model.send(
            prompt: "second",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )

        XCTAssertEqual(client.launchedFamiliarIDs, [nil, "sage"])
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
    }

    func testRemovingFamiliarReplacesBoundSession() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )
        completeTurn(on: model)

        await model.send(prompt: "second", projectRoot: "/srv/repo")

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage", nil])
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
    }

    func testFamiliarIDIsTrimmedWithoutChangingCaseAndBlankIsNil() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "  SaGe \n"
        )
        completeTurn(on: model)

        await model.send(
            prompt: "second",
            projectRoot: "/srv/repo",
            familiarID: " \t\n "
        )

        XCTAssertEqual(client.launchedFamiliarIDs, ["SaGe", nil])
        XCTAssertNil(model.sessionFamiliarID)
    }

    func testGateFailureRetryUsesOriginalFamiliar() async {
        let client = FakeCompanionSessionClient(gate: .notPaired)
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)
        let presentation = companionFamiliar(
            id: "sage",
            name: "Sage on A",
            emoji: "🅰️",
            role: "A role"
        )
        let firstSend = Task {
            await model.send(
                prompt: "first",
                projectRoot: "/srv/repo",
                familiarID: "sage",
                familiar: presentation,
                familiarProfile: .companion(pairing: pairedDaemon())
            )
        }
        await fulfillment(of: [client.gateRequested], timeout: 1)
        await model.send(
            prompt: "ignored",
            projectRoot: "/srv/repo",
            familiarID: "forge"
        )
        client.resumeNextGate(with: .notPaired)
        await firstSend.value

        XCTAssertEqual(model.retryFamiliarID, "sage")
        client.suspendsGate = false
        client.gate = .ready(pairedDaemon())
        await model.retry()

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage"])
        XCTAssertEqual(model.sessionFamiliar, presentation)
    }

    func testLaunchFailureRetryUsesOriginalFamiliar() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        client.launchError = .polling
        let model = CompanionChatModel(client: client)
        let presentation = companionFamiliar(
            id: "sage",
            name: "Sage on A",
            emoji: "🅰️",
            role: "A role"
        )
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage",
            familiar: presentation,
            familiarProfile: .companion(
                host: " MAC.TAILNET.TS.NET ",
                port: pairing.port
            )
        )

        XCTAssertEqual(model.retryFamiliarID, "sage")
        XCTAssertEqual(
            model.retryFamiliarPresentation.profile,
            .companion(pairing: pairing)
        )
        client.launchError = nil
        await model.retry {
            CompanionPromptRetrySelection(
                familiarID: "forge",
                familiar: companionFamiliar(
                    id: "forge",
                    name: "Forge on A"
                ),
                profile: .companion(pairing: pairing)
            )
        }

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage", "sage"])
        XCTAssertEqual(model.sessionFamiliar, presentation)
    }

    func testCrossDaemonRetryWithoutValidSelectionRetainsPrompt() async {
        let pairingA = pairedDaemon(host: "a.tailnet.ts.net")
        let pairingB = pairedDaemon(host: "b.tailnet.ts.net")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        client.launchError = .polling
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage",
            familiar: companionFamiliar(id: "sage", name: "Sage on A"),
            familiarProfile: .companion(pairing: pairingA)
        )

        client.launchError = nil
        client.gate = .ready(pairingB)
        await model.retry()

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage"])
        XCTAssertEqual(model.retryPrompt, "first")
        XCTAssertTrue(model.canRetry)
        XCTAssertTrue(
            model.items.contains {
                $0.kind == .error
                    && $0.text.lowercased().contains(
                        "choose a familiar for this daemon"
                    )
            }
        )

        let forgeB = companionFamiliar(id: "forge", name: "Forge on B")
        await model.retry {
            CompanionPromptRetrySelection(
                familiarID: "forge",
                familiar: forgeB,
                profile: .companion(pairing: pairingB)
            )
        }

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage", "forge"])
        XCTAssertEqual(model.sessionFamiliar, forgeB)
        XCTAssertNil(model.retryPrompt)
        XCTAssertFalse(model.canRetry)
    }

    func testCrossDaemonRetryRebindsToCurrentFamiliar() async {
        let pairingA = pairedDaemon(host: "a.tailnet.ts.net")
        let pairingB = pairedDaemon(host: "b.tailnet.ts.net")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        client.launchError = .polling
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage",
            familiar: companionFamiliar(id: "sage", name: "Sage on A"),
            familiarProfile: .companion(pairing: pairingA)
        )
        let forgeB = companionFamiliar(
            id: "forge",
            name: "Forge on B",
            role: "B role"
        )

        client.launchError = nil
        client.gate = .ready(pairingB)
        await model.retry {
            CompanionPromptRetrySelection(
                familiarID: "forge",
                familiar: forgeB,
                profile: .companion(pairing: pairingB)
            )
        }

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage", "forge"])
        XCTAssertEqual(client.launchedPairings, [pairingA, pairingB])
        XCTAssertEqual(model.sessionFamiliarID, "forge")
        XCTAssertEqual(model.sessionFamiliar, forgeB)
    }

    func testCrossDaemonSameIDRetryUsesCurrentEndpointPresentation() async {
        let pairingA = pairedDaemon(host: "a.tailnet.ts.net")
        let pairingB = pairedDaemon(host: "b.tailnet.ts.net")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        client.launchError = .polling
        let model = CompanionChatModel(client: client)
        let sageA = companionFamiliar(
            id: "sage",
            name: "Sage on A",
            role: "A role"
        )
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage",
            familiar: sageA,
            familiarProfile: .companion(pairing: pairingA)
        )
        let sageB = companionFamiliar(
            id: "sage",
            name: "Sage on B",
            role: "B role"
        )

        client.launchError = nil
        client.gate = .ready(pairingB)
        await model.retry {
            CompanionPromptRetrySelection(
                familiarID: "sage",
                familiar: sageB,
                profile: .companion(pairing: pairingB)
            )
        }

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage", "sage"])
        XCTAssertEqual(client.launchedPairings, [pairingA, pairingB])
        XCTAssertEqual(model.sessionFamiliar, sageB)
        XCTAssertNotEqual(model.sessionFamiliar, sageA)
    }

    func testRetryRevalidatesCurrentFamiliarImmediatelyBeforeLaunch() async {
        let pairingA = pairedDaemon(host: "a.tailnet.ts.net")
        let pairingB = pairedDaemon(host: "b.tailnet.ts.net")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        client.launchError = .polling
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage",
            familiar: companionFamiliar(id: "sage", name: "Sage on A"),
            familiarProfile: .companion(pairing: pairingA)
        )
        let forgeB = CompanionPromptRetrySelection(
            familiarID: "forge",
            familiar: companionFamiliar(id: "forge", name: "Forge on B"),
            profile: .companion(pairing: pairingB)
        )
        var selectionReadCount = 0

        client.launchError = nil
        client.gate = .ready(pairingB)
        await model.retry {
            selectionReadCount += 1
            return selectionReadCount == 1 ? forgeB : .empty
        }

        XCTAssertGreaterThanOrEqual(selectionReadCount, 2)
        XCTAssertEqual(client.launchedFamiliarIDs, ["sage"])
        XCTAssertEqual(model.retryPrompt, "first")
        XCTAssertTrue(model.canRetry)
        XCTAssertTrue(
            model.items.contains {
                $0.kind == .error && $0.text == "Polling failed"
            }
        )
        XCTAssertTrue(
            model.items.contains {
                $0.kind == .error
                    && $0.text.lowercased().contains(
                        "choose a familiar for this daemon"
                    )
            }
        )
    }

    func testRetryLaunchUsesRefreshedCurrentFamiliarPresentation() async {
        let pairingA = pairedDaemon(host: "a.tailnet.ts.net")
        let pairingB = pairedDaemon(host: "b.tailnet.ts.net")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        client.launchError = .polling
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage",
            familiar: companionFamiliar(id: "sage", name: "Sage on A"),
            familiarProfile: .companion(pairing: pairingA)
        )
        let staleForge = CompanionPromptRetrySelection(
            familiarID: "forge",
            familiar: companionFamiliar(id: "forge", name: "Old Forge on B"),
            profile: .companion(pairing: pairingB)
        )
        let refreshedForge = CompanionPromptRetrySelection(
            familiarID: "forge",
            familiar: companionFamiliar(
                id: "forge",
                name: "Refreshed Forge on B",
                role: "Updated B role"
            ),
            profile: .companion(pairing: pairingB)
        )
        var selectionReadCount = 0

        client.launchError = nil
        client.gate = .ready(pairingB)
        await model.retry {
            selectionReadCount += 1
            return selectionReadCount == 1 ? staleForge : refreshedForge
        }

        XCTAssertGreaterThanOrEqual(selectionReadCount, 2)
        XCTAssertEqual(client.launchedFamiliarIDs, ["sage", "forge"])
        XCTAssertEqual(model.sessionFamiliar, refreshedForge.familiar)
        XCTAssertFalse(
            model.items.contains {
                $0.text.lowercased().contains(
                    "choose a familiar for this daemon"
                )
            }
        )
    }

    func testEndpointChangeDuringRetryGateRetainsBoundPrompt() async {
        let pairingA = pairedDaemon(host: "a.tailnet.ts.net")
        let pairingB = pairedDaemon(host: "b.tailnet.ts.net")
        let pairingC = pairedDaemon(host: "c.tailnet.ts.net")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        client.launchError = .polling
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage",
            familiar: companionFamiliar(id: "sage", name: "Sage on A"),
            familiarProfile: .companion(pairing: pairingA)
        )
        client.launchError = nil
        client.suspendsGate = true
        let forgeB = companionFamiliar(id: "forge", name: "Forge on B")

        let retry = Task {
            await model.retry {
                CompanionPromptRetrySelection(
                    familiarID: "forge",
                    familiar: forgeB,
                    profile: .companion(pairing: pairingB)
                )
            }
        }
        await fulfillment(of: [client.gateRequested], timeout: 1)
        let refresh = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.secondGateRequested], timeout: 1)
        client.resumeLastGate(with: .ready(pairingC))
        let refreshed = await refresh.value
        XCTAssertTrue(refreshed)
        client.resumeNextGate(with: .ready(pairingB))
        await retry.value

        XCTAssertEqual(model.availability, .ready(pairingC))
        XCTAssertEqual(client.launchedFamiliarIDs, ["sage"])
        XCTAssertEqual(model.retryPrompt, "first")
        XCTAssertTrue(model.canRetry)
    }

    func testEndpointChangeDuringRetryLaunchCleansAndRetainsPrompt() async {
        let pairingA = pairedDaemon(host: "a.tailnet.ts.net")
        let pairingB = pairedDaemon(host: "b.tailnet.ts.net")
        let pairingC = pairedDaemon(host: "c.tailnet.ts.net")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        client.launchError = .polling
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage",
            familiar: companionFamiliar(id: "sage", name: "Sage on A"),
            familiarProfile: .companion(pairing: pairingA)
        )
        client.launchError = nil
        client.gate = .ready(pairingB)
        client.suspendsLaunch = true
        let forgeB = companionFamiliar(id: "forge", name: "Forge on B")

        let retry = Task {
            await model.retry {
                CompanionPromptRetrySelection(
                    familiarID: "forge",
                    familiar: forgeB,
                    profile: .companion(pairing: pairingB)
                )
            }
        }
        await fulfillment(of: [client.launchRequested], timeout: 1)
        client.gate = .ready(pairingC)
        let refreshed = await model.refreshAvailability()
        XCTAssertTrue(refreshed)
        client.resumeLaunch(id: "session-b")
        await retry.value

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage", "forge"])
        XCTAssertEqual(client.launchedPairings, [pairingA, pairingB])
        XCTAssertEqual(client.killedSessionIDs, ["session-b"])
        XCTAssertEqual(client.killPairings, [pairingB])
        XCTAssertNil(model.session)
        XCTAssertEqual(model.retryPrompt, "first")
        XCTAssertTrue(model.canRetry)
    }

    func testPendingCleanupCompletesBeforeCrossDaemonRebindLaunch() async {
        let pairingA = pairedDaemon(host: "a.tailnet.ts.net")
        let pairingB = pairedDaemon(host: "b.tailnet.ts.net")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        let model = CompanionChatModel(client: client)
        let sageA = companionFamiliar(id: "sage", name: "Sage on A")
        await model.send(
            prompt: "first",
            projectRoot: "/srv/one",
            familiarID: "sage",
            familiar: sageA,
            familiarProfile: .companion(pairing: pairingA)
        )
        completeTurn(on: model)
        client.killError = .polling
        await model.send(
            prompt: "second",
            projectRoot: "/srv/two",
            familiarID: "sage",
            familiar: sageA,
            familiarProfile: .companion(pairing: pairingA)
        )
        XCTAssertTrue(model.hasPendingCleanup)
        client.killError = nil
        client.suspendsKill = true
        let forgeB = companionFamiliar(id: "forge", name: "Forge on B")

        let retry = Task {
            await model.retry {
                CompanionPromptRetrySelection(
                    familiarID: "forge",
                    familiar: forgeB,
                    profile: .companion(pairing: pairingB)
                )
            }
        }
        await fulfillment(of: [client.killRequested], timeout: 1)
        client.gate = .ready(pairingB)
        let refreshed = await model.refreshAvailability()
        XCTAssertTrue(refreshed)
        client.resumeKill()
        await retry.value

        XCTAssertFalse(model.hasPendingCleanup)
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
        XCTAssertEqual(client.killPairings.last, pairingA)
        XCTAssertEqual(client.launchedFamiliarIDs, ["sage", "forge"])
        XCTAssertEqual(
            Array(client.operationLog.suffix(2)),
            ["kill:session-1", "launch:forge"]
        )
        XCTAssertEqual(model.sessionFamiliar, forgeB)
    }

    func testPollingRetryIgnoresCurrentFamiliarSelection() async {
        let pairingA = pairedDaemon(host: "a.tailnet.ts.net")
        let pairingB = pairedDaemon(host: "b.tailnet.ts.net")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        let model = CompanionChatModel(client: client)
        let sageA = companionFamiliar(id: "sage", name: "Sage on A")
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage",
            familiar: sageA,
            familiarProfile: .companion(pairing: pairingA)
        )
        model.pollTask?.cancel()
        model.pollTask = nil
        client.eventError = .polling
        await model.refreshOnce()
        client.eventError = nil
        var selectionReadCount = 0

        await model.retry {
            selectionReadCount += 1
            return CompanionPromptRetrySelection(
                familiarID: "forge",
                familiar: companionFamiliar(
                    id: "forge",
                    name: "Forge on B"
                ),
                profile: .companion(pairing: pairingB)
            )
        }

        XCTAssertEqual(selectionReadCount, 0)
        XCTAssertEqual(client.launchedFamiliarIDs, ["sage"])
        XCTAssertEqual(client.eventPairings.last, pairingA)
        XCTAssertEqual(model.sessionFamiliar, sageA)
    }

    func testFamiliarChangeKillFailureBlocksReplacementAndRetriesIdentity() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        let profile = FamiliarProfileKey.companion(pairing: pairedDaemon())
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage",
            familiar: companionFamiliar(id: "sage", name: "Sage on A"),
            familiarProfile: profile
        )
        completeTurn(on: model)
        client.killError = .polling
        let forge = companionFamiliar(
            id: "forge",
            name: "Forge on A",
            emoji: "🔥",
            role: "Implementation"
        )

        await model.send(
            prompt: "second",
            projectRoot: "/srv/repo",
            familiarID: "forge",
            familiar: forge,
            familiarProfile: profile
        )

        XCTAssertTrue(model.hasPendingCleanup)
        XCTAssertEqual(model.retryFamiliarID, "forge")
        XCTAssertEqual(client.launchedFamiliarIDs, ["sage"])

        await model.retry()
        XCTAssertTrue(model.hasPendingCleanup)
        XCTAssertEqual(model.retryFamiliarID, "forge")

        client.killError = nil
        await model.retry()

        XCTAssertFalse(model.hasPendingCleanup)
        XCTAssertEqual(client.launchedFamiliarIDs, ["sage", "forge"])
        XCTAssertEqual(model.sessionFamiliarID, "forge")
        XCTAssertEqual(model.sessionFamiliar, forge)
    }

    func testLaunchPinsDisplayMetadataToVerifiedEndpoint() async {
        let endpointA = pairedDaemon(host: "a.local")
        let endpointB = pairedDaemon(host: "b.local")
        let client = FakeCompanionSessionClient(gate: .ready(endpointA))
        let model = CompanionChatModel(client: client)
        let familiarA = companionFamiliar(
            id: "sage",
            name: "Sage on A",
            emoji: "🅰️",
            role: "A role"
        )
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage",
            familiar: familiarA,
            familiarProfile: .companion(pairing: endpointA)
        )

        client.gate = .ready(endpointB)
        _ = await model.refreshAvailability()
        let seal = FamiliarSealResolver.companion(
            activeFamiliar: model.sessionFamiliar,
            hasActiveSession: model.hasActiveSession,
            selectedFamiliar: companionFamiliar(
                id: "sage",
                name: "Sage on B",
                emoji: "🅱️",
                role: "B role"
            ),
            roster: [
                companionRemoteFamiliar(
                    id: "sage",
                    name: "Sage on B",
                    emoji: "🅱️",
                    role: "B role"
                )
            ]
        )

        XCTAssertEqual(model.sessionFamiliar, familiarA)
        XCTAssertEqual(seal?.displayName, "Sage on A")
        XCTAssertEqual(seal?.glyph, "🅰️")
        XCTAssertEqual(seal?.role, "A role")
    }

    func testMismatchedPresentationProfileFallsBackToRawFamiliarID() async {
        let endpointA = pairedDaemon(host: "a.local")
        let client = FakeCompanionSessionClient(gate: .ready(endpointA))
        let model = CompanionChatModel(client: client)

        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: " SaGe ",
            familiar: companionFamiliar(
                id: "sage",
                name: "Sage on B",
                emoji: "🅱️",
                role: "B role"
            ),
            familiarProfile: .companion(
                host: "b.local",
                port: endpointA.port
            )
        )

        XCTAssertEqual(
            model.sessionFamiliar,
            companionFamiliar(id: "SaGe", name: "SaGe")
        )
    }
}

@MainActor
final class CompanionChatFamiliarAuthorityTests: XCTestCase {
    func testMissingFamiliarEchoFailsLaunchAndCleansRemoteSession() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.echoesRequestedFamiliarID = false
        let model = CompanionChatModel(client: client)

        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )

        XCTAssertNil(model.session)
        XCTAssertNil(model.sessionFamiliarID)
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
        XCTAssertTrue(model.canRetry)
        XCTAssertTrue(
            model.items.contains {
                $0.kind == .error
                    && $0.text.contains("did not confirm the selected familiar")
            }
        )

        client.echoesRequestedFamiliarID = true
        await model.retry()

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage", "sage"])
        XCTAssertEqual(model.sessionFamiliarID, "sage")
    }

    func testMismatchedFamiliarEchoAndCleanupFailureBlockTraffic() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.echoesRequestedFamiliarID = false
        client.launchResponseFamiliarID = "forge"
        client.killError = .polling
        let model = CompanionChatModel(client: client)

        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )

        XCTAssertTrue(model.hasPendingCleanup)
        XCTAssertEqual(model.retryFamiliarID, "sage")
        XCTAssertTrue(
            model.items.contains {
                $0.kind == .error
                    && $0.text.contains("did not confirm the selected familiar")
            }
        )

        await model.send(
            prompt: "blocked",
            projectRoot: "/srv/repo",
            familiarID: "forge"
        )

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage"])
        XCTAssertTrue(client.sentInputs.isEmpty)
    }

    func testCancelledFamiliarMismatchCleanupEscapesSendCancellation() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.echoesRequestedFamiliarID = false
        client.suspendsKill = true
        client.killChecksCancellation = true
        let model = CompanionChatModel(client: client)

        let send = Task {
            await model.send(
                prompt: "first",
                projectRoot: "/srv/repo",
                familiarID: "sage"
            )
        }
        await fulfillment(of: [client.killRequested], timeout: 1)

        send.cancel()
        client.resumeKill()
        await send.value

        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
        XCTAssertNil(model.session)
        XCTAssertNil(model.sessionFamiliarID)
        XCTAssertFalse(model.hasPendingCleanup)
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.canRetry)
        XCTAssertFalse(model.items.contains { $0.kind == .error })
    }

    func testNilFamiliarEchoIsValidForNilRequest() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)

        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiar: companionFamiliar(id: "sage", name: "Sage"),
            familiarProfile: .companion(pairing: pairedDaemon())
        )

        XCTAssertNotNil(model.session)
        XCTAssertNil(model.sessionFamiliarID)
        XCTAssertNil(model.sessionFamiliar)
        XCTAssertTrue(client.killedSessionIDs.isEmpty)
        XCTAssertFalse(model.items.contains { $0.kind == .error })
    }

    func testDeadSessionRetryRelaunchesWithOriginalFamiliar() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )
        completeTurn(on: model)
        client.sendInputError = .sessionNotLive

        await model.send(
            prompt: "second",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )

        XCTAssertEqual(model.retryFamiliarID, "sage")
        client.sendInputError = nil
        await model.retry()

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage", "sage"])
        XCTAssertEqual(model.sessionFamiliarID, "sage")
    }

    func testAbandonSessionClearsFamiliarBinding() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )

        model.abandonSession()

        XCTAssertNil(model.session)
        XCTAssertNil(model.sessionFamiliarID)
        XCTAssertNil(model.sessionFamiliar)
    }

    func testStaleCleanupCompletionCannotOverwriteNewFamiliarBinding() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsKill = true
        let model = CompanionChatModel(client: client)
        let staleSession = remoteSession(id: "stale", familiarID: "sage")
        model.operationGeneration = 1

        let cleanup = Task {
            await model.beginCleanup(
                of: staleSession,
                pairing: pairedDaemon(),
                completionText: nil
            )
        }
        await fulfillment(of: [client.killRequested], timeout: 1)
        model.operationGeneration = 2
        model.session = remoteSession(id: "current", familiarID: "forge")
        model.sessionFamiliarID = "forge"

        client.resumeKill()
        await cleanup.value

        XCTAssertEqual(model.session?.id, "current")
        XCTAssertEqual(model.sessionFamiliarID, "forge")
    }

    func testStopInvalidatesSuspendedCleanupRetryBeforeItCanRelaunch() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )
        completeTurn(on: model)
        client.killError = .polling
        await model.send(
            prompt: "second",
            projectRoot: "/srv/repo",
            familiarID: "forge"
        )
        client.killError = nil
        client.suspendsGate = true

        let retry = Task { await model.retry() }
        await fulfillment(of: [client.gateRequested], timeout: 1)
        let gateCallsDuringRetry = client.gateCallCount
        let generation = model.operationGeneration
        let stop = Task { await model.stop() }
        while model.operationGeneration == generation {
            await Task.yield()
        }
        XCTAssertEqual(client.gateCallCount, gateCallsDuringRetry)

        client.resumeNextGate(with: .ready(pairedDaemon()))
        while client.gateCallCount == gateCallsDuringRetry {
            await Task.yield()
        }
        client.resumeNextGate(with: .ready(pairedDaemon()))
        await stop.value
        await retry.value

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage"])
        XCTAssertNil(model.session)
        XCTAssertNil(model.retryFamiliarID)
    }
}

private func companionFamiliar(
    id: String,
    name: String,
    emoji: String? = nil,
    role: String? = nil
) -> FamiliarIdentity {
    FamiliarIdentity(
        id: id,
        displayName: name,
        emoji: emoji,
        role: role
    )
}

private func companionRemoteFamiliar(
    id: String,
    name: String,
    emoji: String? = nil,
    role: String? = nil
) -> RemoteFamiliar {
    RemoteFamiliar(
        id: id,
        displayName: name,
        emoji: emoji,
        role: role,
        description: nil,
        pronouns: nil,
        icon: nil
    )
}

// swiftlint:enable file_length
