import CellBase
import DiMyMintClient
import DiMyPaymentTypes
import XCTest
@testable import DiMyCellProtocolCells

private actor SuspendedIssueMintClient: MintClient {
    private let base = InMemoryMintClient()
    private var issueStarted = false
    private var issueStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    func issue(_ request: IssueRequest) async throws -> IssueResponse {
        issueStarted = true
        let waiters = issueStartWaiters
        issueStartWaiters.removeAll()
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            if releaseRequested {
                continuation.resume()
            } else {
                releaseContinuation = continuation
            }
        }
        return try await base.issue(request)
    }

    func redeem(_ request: RedeemRequest) async throws -> RedeemResponse {
        try await base.redeem(request)
    }

    func waitUntilIssueStarts() async {
        if issueStarted {
            return
        }
        await withCheckedContinuation { continuation in
            issueStartWaiters.append(continuation)
        }
    }

    func releaseIssue() {
        if let continuation = releaseContinuation {
            releaseContinuation = nil
            continuation.resume()
        } else {
            releaseRequested = true
        }
    }
}

final class DiMyRuntimeBindingTests: XCTestCase {
    func testFreshAndDecodedRuntimeCellsExposeImmediateStrictContractsAndStableBindings() async throws {
        let previousDebugAccess = CellBase.debugValidateAccessForEverything
        let previousExploreMode = CellBase.exploreContractEnforcementMode
        let previousVault = CellBase.defaultIdentityVault
        let vault = EphemeralIdentityVault()
        CellBase.debugValidateAccessForEverything = false
        CellBase.exploreContractEnforcementMode = .strict
        CellBase.defaultIdentityVault = vault
        defer {
            CellBase.debugValidateAccessForEverything = previousDebugAccess
            CellBase.exploreContractEnforcementMode = previousExploreMode
            CellBase.defaultIdentityVault = previousVault
        }

        let owner = try await makeIdentity(in: vault, context: "dimy-strict-readiness")
        let freshAccess = await DiMyAccessRuntimeCell(owner: owner)
        let freshPricing = await DiMyPricingPolicyCell(owner: owner)
        let freshWallet = await DiMyWalletRuntimeCell(owner: owner)

        try await assertExactManifest(freshAccess, requester: owner, expected: accessOperations)
        try await assertExactManifest(freshPricing, requester: owner, expected: pricingOperations)
        try await assertExactManifest(freshWallet, requester: owner, expected: walletOperations)

        let decodedAccess = try roundTrip(freshAccess)
        let decodedPricing = try roundTrip(freshPricing)
        let decodedWallet = try roundTrip(freshWallet)

        // Host discovery is the first access after decode. No manual ensure is
        // allowed before these keys/manifests and real state reads.
        let accessKeys = try await decodedAccess.keys(requester: owner)
        let pricingKeys = try await decodedPricing.keys(requester: owner)
        let walletKeys = try await decodedWallet.keys(requester: owner)
        XCTAssertEqual(Set(accessKeys), Set(["state", "merchantID", "verifyAndRedeem", "receipt"]))
        XCTAssertEqual(Set(pricingKeys), Set(["state", "setPrice", "removePrice", "quote"]))
        XCTAssertEqual(Set(walletKeys), Set(["state", "issue", "spend", "rollback", "depositCoins"]))
        try await assertExactManifest(decodedAccess, requester: owner, expected: accessOperations)
        try await assertExactManifest(decodedPricing, requester: owner, expected: pricingOperations)
        try await assertExactManifest(decodedWallet, requester: owner, expected: walletOperations)

        try await assertObjectState(decodedAccess, requester: owner)
        try await assertObjectState(decodedPricing, requester: owner)
        try await assertObjectState(decodedWallet, requester: owner)

        let merchantResult = try await decodedAccess.set(
            keypath: "merchantID",
            value: .object(["value": .string("merchant.persisted")]),
            requester: owner
        )
        XCTAssertEqual(merchantResult, .string("merchant.persisted"))
        let pricingResult = try await decodedPricing.set(
            keypath: "setPrice",
            value: .object([
                "resourceID": .string("resource.persisted"),
                "priceMinorUnits": .integer(17)
            ]),
            requester: owner
        )
        XCTAssertEqual(integer(pricingResult, key: "priceMinorUnits"), 17)
        guard case .object? = try await decodedWallet.set(
            keypath: "depositCoins",
            value: .list([]),
            requester: owner
        ) else {
            return XCTFail("Strict wallet deposit should return state without minting value")
        }

        let templatesBefore = try [decodedAccess, decodedPricing, decodedWallet].map(stableAgreementTemplateData)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for cell in [decodedAccess, decodedPricing, decodedWallet] as [DiMyRuntimeBindingCell] {
                for _ in 0..<40 {
                    group.addTask {
                        try await cell.ensureRuntimeReady()
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(try [decodedAccess, decodedPricing, decodedWallet].map(stableAgreementTemplateData), templatesBefore)

        let reloadedAccess = try roundTrip(decodedAccess)
        let reloadedPricing = try roundTrip(decodedPricing)
        let reloadedWallet = try roundTrip(decodedWallet)
        let reloadedMerchant = try await reloadedAccess.get(keypath: "merchantID", requester: owner)
        let reloadedPricingState = try await reloadedPricing.get(keypath: "state", requester: owner)
        let reloadedWalletState = try await reloadedWallet.get(keypath: "state", requester: owner)
        XCTAssertEqual(reloadedMerchant, .string("merchant.persisted"))
        XCTAssertEqual(integer(reloadedPricingState, key: "count"), 1)
        XCTAssertEqual(integer(reloadedWalletState, key: "balanceMinorUnits"), 0)
        try await assertExactManifest(reloadedAccess, requester: owner, expected: accessOperations)
        try await assertExactManifest(reloadedPricing, requester: owner, expected: pricingOperations)
        try await assertExactManifest(reloadedWallet, requester: owner, expected: walletOperations)
    }

    func testStrictWalletSpendAccessRedeemAndPersistedReceiptRoundTrip() async throws {
        let previousDebugAccess = CellBase.debugValidateAccessForEverything
        let previousExploreMode = CellBase.exploreContractEnforcementMode
        let previousVault = CellBase.defaultIdentityVault
        let vault = EphemeralIdentityVault()
        let mint = InMemoryMintClient()
        CellBase.debugValidateAccessForEverything = false
        CellBase.exploreContractEnforcementMode = .strict
        CellBase.defaultIdentityVault = vault
        await MintClientRegistry.shared.setFactory { mint }
        defer {
            CellBase.debugValidateAccessForEverything = previousDebugAccess
            CellBase.exploreContractEnforcementMode = previousExploreMode
            CellBase.defaultIdentityVault = previousVault
        }

        do {
            let owner = try await makeIdentity(in: vault, context: "dimy-strict-functional")
            let wallet = try roundTrip(await DiMyWalletRuntimeCell(owner: owner))
            let access = try roundTrip(await DiMyAccessRuntimeCell(owner: owner))

            let issued = try await wallet.set(
                keypath: "issue",
                value: .object(["amountMinorUnits": .integer(15)]),
                requester: owner
            )
            XCTAssertEqual(integer(issued, nestedObjectKey: "state", key: "balanceMinorUnits"), 15)

            let spend = try await wallet.set(
                keypath: "spend",
                value: .object([
                    "priceMinorUnits": .integer(10),
                    "resourceID": .string("cell://strict/runtime-resource")
                ]),
                requester: owner
            )
            guard case .object? = spend else {
                await MintClientRegistry.shared.useEnvironmentDefault()
                return XCTFail("Expected a strict spend bundle")
            }

            let redeemed = try await access.set(
                keypath: "verifyAndRedeem",
                value: spend ?? .null,
                requester: owner
            )
            let receiptHash = try XCTUnwrap(string(redeemed, nestedObjectKey: "receipt", key: "bundleHash"))
            XCTAssertEqual(string(redeemed, nestedObjectKey: "grant", key: "resourceID"), "cell://strict/runtime-resource")

            let reloadedAccess = try roundTrip(access)
            let reloadedState = try await reloadedAccess.get(keypath: "state", requester: owner)
            XCTAssertEqual(integer(reloadedState, key: "receiptCount"), 1)
            let receipt = try await reloadedAccess.set(
                keypath: "receipt",
                value: .object(["bundleHash": .string(receiptHash)]),
                requester: owner
            )
            XCTAssertEqual(string(receipt, key: "bundleHash"), receiptHash)

            let replay = try await reloadedAccess.set(
                keypath: "verifyAndRedeem",
                value: spend ?? .null,
                requester: owner
            )
            XCTAssertTrue(string(replay)?.hasPrefix("error:") == true)
            let stateAfterReplay = try await reloadedAccess.get(keypath: "state", requester: owner)
            XCTAssertEqual(integer(stateAfterReplay, key: "receiptCount"), 1)
            await MintClientRegistry.shared.useEnvironmentDefault()
        } catch {
            await MintClientRegistry.shared.useEnvironmentDefault()
            throw error
        }
    }

    func testDecodedWalletSerializesConcurrentFirstIssuesAndPersistsExactBalance() async throws {
        let previousDebugAccess = CellBase.debugValidateAccessForEverything
        let previousExploreMode = CellBase.exploreContractEnforcementMode
        let previousVault = CellBase.defaultIdentityVault
        let vault = EphemeralIdentityVault()
        let mint = InMemoryMintClient()
        CellBase.debugValidateAccessForEverything = false
        CellBase.exploreContractEnforcementMode = .strict
        CellBase.defaultIdentityVault = vault
        await MintClientRegistry.shared.setFactory { mint }
        defer {
            CellBase.debugValidateAccessForEverything = previousDebugAccess
            CellBase.exploreContractEnforcementMode = previousExploreMode
            CellBase.defaultIdentityVault = previousVault
        }

        do {
            let owner = try await makeIdentity(in: vault, context: "dimy-concurrent-issue")
            let wallet = try roundTrip(await DiMyWalletRuntimeCell(owner: owner))
            let issueCount = 40

            let successfulIssues = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for _ in 0..<issueCount {
                    group.addTask {
                        guard let result = try? await wallet.set(
                            keypath: "issue",
                            value: .object(["amountMinorUnits": .integer(1)]),
                            requester: owner
                        ) else {
                            return false
                        }
                        return self.object(result) != nil
                    }
                }

                var successes = 0
                for await succeeded in group where succeeded {
                    successes += 1
                }
                return successes
            }

            XCTAssertEqual(successfulIssues, issueCount)
            let state = try await wallet.get(keypath: "state", requester: owner)
            XCTAssertEqual(integer(state, key: "balanceMinorUnits"), issueCount)

            let reloaded = try roundTrip(wallet)
            let reloadedState = try await reloaded.get(keypath: "state", requester: owner)
            XCTAssertEqual(integer(reloadedState, key: "balanceMinorUnits"), issueCount)
            XCTAssertEqual(integer(reloadedState, key: "coinCount"), issueCount)
            await MintClientRegistry.shared.useEnvironmentDefault()
        } catch {
            await MintClientRegistry.shared.useEnvironmentDefault()
            throw error
        }
    }

    func testDecodedWalletAllowsOnlyOneConcurrentFullBalanceSpendAndPersistsBundleAtomically() async throws {
        let previousDebugAccess = CellBase.debugValidateAccessForEverything
        let previousExploreMode = CellBase.exploreContractEnforcementMode
        let previousVault = CellBase.defaultIdentityVault
        let vault = EphemeralIdentityVault()
        let mint = InMemoryMintClient()
        CellBase.debugValidateAccessForEverything = false
        CellBase.exploreContractEnforcementMode = .strict
        CellBase.defaultIdentityVault = vault
        await MintClientRegistry.shared.setFactory { mint }
        defer {
            CellBase.debugValidateAccessForEverything = previousDebugAccess
            CellBase.exploreContractEnforcementMode = previousExploreMode
            CellBase.defaultIdentityVault = previousVault
        }

        do {
            let owner = try await makeIdentity(in: vault, context: "dimy-concurrent-spend")
            let source = await DiMyWalletRuntimeCell(owner: owner)
            _ = try await source.set(
                keypath: "issue",
                value: .object(["amountMinorUnits": .integer(10)]),
                requester: owner
            )
            let wallet = try roundTrip(source)

            let successfulSpends = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for index in 0..<2 {
                    group.addTask {
                        guard let result = try? await wallet.set(
                            keypath: "spend",
                            value: .object([
                                "priceMinorUnits": .integer(10),
                                "resourceID": .string("cell://concurrent/spend/\(index)")
                            ]),
                            requester: owner
                        ) else {
                            return false
                        }
                        return self.object(result) != nil
                    }
                }

                var successes = 0
                for await succeeded in group where succeeded {
                    successes += 1
                }
                return successes
            }

            XCTAssertEqual(successfulSpends, 1)
            let state = try await wallet.get(keypath: "state", requester: owner)
            XCTAssertEqual(integer(state, key: "balanceMinorUnits"), 0)
            XCTAssertEqual(integer(state, key: "pendingBundles"), 1)

            let reloaded = try roundTrip(wallet)
            let reloadedState = try await reloaded.get(keypath: "state", requester: owner)
            XCTAssertEqual(integer(reloadedState, key: "balanceMinorUnits"), 0)
            XCTAssertEqual(integer(reloadedState, key: "pendingBundles"), 1)
            await MintClientRegistry.shared.useEnvironmentDefault()
        } catch {
            await MintClientRegistry.shared.useEnvironmentDefault()
            throw error
        }
    }

    func testWalletRollbackRequiresExactPendingBundleAndCannotReplayOrDuplicateDeposit() async throws {
        let previousDebugAccess = CellBase.debugValidateAccessForEverything
        let previousExploreMode = CellBase.exploreContractEnforcementMode
        let previousVault = CellBase.defaultIdentityVault
        let vault = EphemeralIdentityVault()
        let mint = InMemoryMintClient()
        CellBase.debugValidateAccessForEverything = false
        CellBase.exploreContractEnforcementMode = .strict
        CellBase.defaultIdentityVault = vault
        await MintClientRegistry.shared.setFactory { mint }
        defer {
            CellBase.debugValidateAccessForEverything = previousDebugAccess
            CellBase.exploreContractEnforcementMode = previousExploreMode
            CellBase.defaultIdentityVault = previousVault
        }

        do {
            let owner = try await makeIdentity(in: vault, context: "dimy-rollback-replay")
            let wallet = try roundTrip(await DiMyWalletRuntimeCell(owner: owner))
            let issued = try await wallet.set(
                keypath: "issue",
                value: .object(["amountMinorUnits": .integer(10)]),
                requester: owner
            )
            let issuedCoins = try XCTUnwrap(object(issued)?["issuedCoins"])
            let spend = try await wallet.set(
                keypath: "spend",
                value: .object([
                    "priceMinorUnits": .integer(10),
                    "resourceID": .string("cell://rollback/exact")
                ]),
                requester: owner
            )
            let bundle = try XCTUnwrap(ValueTypeCodableBridge.decode(SpendBundle.self, from: try XCTUnwrap(spend)))
            let manipulated = SpendBundle(
                coins: [],
                requestID: bundle.requestID,
                resourceID: "cell://rollback/manipulated",
                createdAt: bundle.createdAt
            )
            let timestampManipulated = SpendBundle(
                coins: bundle.coins,
                requestID: bundle.requestID,
                resourceID: bundle.resourceID,
                createdAt: bundle.createdAt.addingTimeInterval(1)
            )

            let pendingDeposit = try await wallet.set(
                keypath: "depositCoins",
                value: ValueTypeCodableBridge.encode(bundle.coins),
                requester: owner
            )
            XCTAssertTrue(string(pendingDeposit)?.contains("already reserved") == true)

            let mismatch = try await wallet.set(
                keypath: "rollback",
                value: ValueTypeCodableBridge.encode(manipulated),
                requester: owner
            )
            XCTAssertTrue(string(mismatch)?.contains("does not match") == true)
            var state = try await wallet.get(keypath: "state", requester: owner)
            XCTAssertEqual(integer(state, key: "balanceMinorUnits"), 0)
            XCTAssertEqual(integer(state, key: "pendingBundles"), 1)

            let timestampMismatch = try await wallet.set(
                keypath: "rollback",
                value: ValueTypeCodableBridge.encode(timestampManipulated),
                requester: owner
            )
            XCTAssertTrue(string(timestampMismatch)?.contains("does not match") == true)

            guard case .object? = try await wallet.set(
                keypath: "rollback",
                value: try XCTUnwrap(spend),
                requester: owner
            ) else {
                await MintClientRegistry.shared.useEnvironmentDefault()
                return XCTFail("Expected exact pending rollback")
            }
            let replay = try await wallet.set(
                keypath: "rollback",
                value: try XCTUnwrap(spend),
                requester: owner
            )
            XCTAssertTrue(string(replay)?.contains("already rolled back") == true)

            _ = try await wallet.set(keypath: "depositCoins", value: issuedCoins, requester: owner)
            _ = try await wallet.set(keypath: "depositCoins", value: issuedCoins, requester: owner)
            state = try await wallet.get(keypath: "state", requester: owner)
            XCTAssertEqual(integer(state, key: "balanceMinorUnits"), 10)
            XCTAssertEqual(integer(state, key: "pendingBundles"), 0)

            let reloaded = try roundTrip(wallet)
            let reloadedState = try await reloaded.get(keypath: "state", requester: owner)
            XCTAssertEqual(integer(reloadedState, key: "balanceMinorUnits"), 10)
            XCTAssertEqual(integer(reloadedState, key: "pendingBundles"), 0)
            await MintClientRegistry.shared.useEnvironmentDefault()
        } catch {
            await MintClientRegistry.shared.useEnvironmentDefault()
            throw error
        }
    }

    func testEncodingDuringSuspendedIssueObservesConsistentPreAndPostSnapshots() async throws {
        let previousDebugAccess = CellBase.debugValidateAccessForEverything
        let previousExploreMode = CellBase.exploreContractEnforcementMode
        let previousVault = CellBase.defaultIdentityVault
        let vault = EphemeralIdentityVault()
        let mint = SuspendedIssueMintClient()
        CellBase.debugValidateAccessForEverything = false
        CellBase.exploreContractEnforcementMode = .strict
        CellBase.defaultIdentityVault = vault
        await MintClientRegistry.shared.setFactory { mint }
        defer {
            CellBase.debugValidateAccessForEverything = previousDebugAccess
            CellBase.exploreContractEnforcementMode = previousExploreMode
            CellBase.defaultIdentityVault = previousVault
        }

        do {
            let owner = try await makeIdentity(in: vault, context: "dimy-encode-action")
            let wallet = try roundTrip(await DiMyWalletRuntimeCell(owner: owner))
            let issueTask = Task {
                try await wallet.set(
                    keypath: "issue",
                    value: .object(["amountMinorUnits": .integer(10)]),
                    requester: owner
                )
            }

            await mint.waitUntilIssueStarts()
            let preActionSnapshot = try roundTrip(wallet)
            await mint.releaseIssue()
            guard case .object? = try await issueTask.value else {
                await MintClientRegistry.shared.useEnvironmentDefault()
                return XCTFail("Expected issued wallet result")
            }
            let postActionSnapshot = try roundTrip(wallet)

            let preState = try await preActionSnapshot.get(keypath: "state", requester: owner)
            let postState = try await postActionSnapshot.get(keypath: "state", requester: owner)
            XCTAssertEqual(integer(preState, key: "balanceMinorUnits"), 0)
            XCTAssertEqual(integer(preState, key: "pendingBundles"), 0)
            XCTAssertEqual(integer(postState, key: "balanceMinorUnits"), 10)
            XCTAssertEqual(integer(postState, key: "pendingBundles"), 0)
            await MintClientRegistry.shared.useEnvironmentDefault()
        } catch {
            await mint.releaseIssue()
            await MintClientRegistry.shared.useEnvironmentDefault()
            throw error
        }
    }

    func testReloadedAccessRejectsPersistedReceiptReplayWithFreshMintRuntime() async throws {
        let previousDebugAccess = CellBase.debugValidateAccessForEverything
        let previousExploreMode = CellBase.exploreContractEnforcementMode
        let previousVault = CellBase.defaultIdentityVault
        let vault = EphemeralIdentityVault()
        let originalMint = InMemoryMintClient()
        CellBase.debugValidateAccessForEverything = false
        CellBase.exploreContractEnforcementMode = .strict
        CellBase.defaultIdentityVault = vault
        await MintClientRegistry.shared.setFactory { originalMint }
        defer {
            CellBase.debugValidateAccessForEverything = previousDebugAccess
            CellBase.exploreContractEnforcementMode = previousExploreMode
            CellBase.defaultIdentityVault = previousVault
        }

        do {
            let owner = try await makeIdentity(in: vault, context: "dimy-access-replay-reload")
            let wallet = try roundTrip(await DiMyWalletRuntimeCell(owner: owner))
            let access = try roundTrip(await DiMyAccessRuntimeCell(owner: owner))
            _ = try await wallet.set(
                keypath: "issue",
                value: .object(["amountMinorUnits": .integer(10)]),
                requester: owner
            )
            let spend = try await wallet.set(
                keypath: "spend",
                value: .object([
                    "priceMinorUnits": .integer(10),
                    "resourceID": .string("cell://persisted/replay")
                ]),
                requester: owner
            )
            guard let spend else {
                await MintClientRegistry.shared.useEnvironmentDefault()
                return XCTFail("Expected spend bundle")
            }
            guard case .object? = try await access.set(
                keypath: "verifyAndRedeem",
                value: spend,
                requester: owner
            ) else {
                await MintClientRegistry.shared.useEnvironmentDefault()
                return XCTFail("Expected first redemption")
            }

            let legacyPersistedAccess = try removingTopLevelJSONValues(
                from: access,
                keys: [
                    "persistenceSchemaVersion",
                    "redeemedBundleHashes",
                    "redeemedCoinSerials",
                    "replayHistoryMigrationRequired"
                ]
            )
            let legacyAccess = try JSONDecoder().decode(
                DiMyAccessRuntimeCell.self,
                from: legacyPersistedAccess
            )
            let legacyReplay = try await legacyAccess.set(
                keypath: "verifyAndRedeem",
                value: spend,
                requester: owner
            )
            XCTAssertTrue(string(legacyReplay)?.contains("requires migration") == true)
            let legacyState = try await legacyAccess.get(keypath: "state", requester: owner)
            XCTAssertEqual(integer(legacyState, key: "receiptCount"), 1)

            var inconsistentV2Object = try topLevelJSONObject(access)
            inconsistentV2Object["redeemedCoinSerials"] = [String]()
            inconsistentV2Object["replayHistoryMigrationRequired"] = false
            let inconsistentV2 = try JSONDecoder().decode(
                DiMyAccessRuntimeCell.self,
                from: JSONSerialization.data(withJSONObject: inconsistentV2Object, options: [.sortedKeys])
            )
            let inconsistentReplay = try await inconsistentV2.set(
                keypath: "verifyAndRedeem",
                value: spend,
                requester: owner
            )
            XCTAssertTrue(string(inconsistentReplay)?.contains("requires migration") == true)

            let reloaded = try roundTrip(access)
            _ = try await reloaded.set(
                keypath: "merchantID",
                value: .string("merchant.changed"),
                requester: owner
            )
            let merchantChanged = try roundTrip(reloaded)
            let freshMint = InMemoryMintClient()
            await MintClientRegistry.shared.setFactory { freshMint }
            let replay = try await merchantChanged.set(
                keypath: "verifyAndRedeem",
                value: spend,
                requester: owner
            )
            XCTAssertTrue(string(replay)?.contains("replayedBundle") == true)

            let originalBundle = try XCTUnwrap(ValueTypeCodableBridge.decode(SpendBundle.self, from: spend))
            let reframedBundle = SpendBundle(
                coins: originalBundle.coins,
                requestID: UUID(),
                resourceID: originalBundle.resourceID,
                createdAt: Date()
            )
            let coinReplay = try await merchantChanged.set(
                keypath: "verifyAndRedeem",
                value: ValueTypeCodableBridge.encode(reframedBundle),
                requester: owner
            )
            XCTAssertTrue(string(coinReplay)?.contains("replayedCoin") == true)

            let state = try await merchantChanged.get(keypath: "state", requester: owner)
            XCTAssertEqual(integer(state, key: "receiptCount"), 1)
            await MintClientRegistry.shared.useEnvironmentDefault()
        } catch {
            await MintClientRegistry.shared.useEnvironmentDefault()
            throw error
        }
    }

    func testMalformedPersistedPaymentStateFailsDecodeInsteadOfResettingValue() async throws {
        let vault = EphemeralIdentityVault()
        let owner = try await makeIdentity(in: vault, context: "dimy-corrupt-persistence")
        let wallet = await DiMyWalletRuntimeCell(owner: owner)
        let access = await DiMyAccessRuntimeCell(owner: owner)
        let pricing = await DiMyPricingPolicyCell(owner: owner)

        let corruptWallet = try replacingTopLevelJSONValue(
            in: wallet,
            key: "storedCoins",
            value: "not-a-coin-list"
        )
        XCTAssertThrowsError(try JSONDecoder().decode(DiMyWalletRuntimeCell.self, from: corruptWallet))

        let corruptAccess = try replacingTopLevelJSONValue(
            in: access,
            key: "receiptCache",
            value: ["not-a-receipt"]
        )
        XCTAssertThrowsError(try JSONDecoder().decode(DiMyAccessRuntimeCell.self, from: corruptAccess))

        let corruptPricing = try replacingTopLevelJSONValue(
            in: pricing,
            key: "pricesByResource",
            value: ["resource": "not-an-integer"]
        )
        XCTAssertThrowsError(try JSONDecoder().decode(DiMyPricingPolicyCell.self, from: corruptPricing))

        for requiredWalletKey in ["storedCoins", "cachedBundles", "mintKeyID"] {
            let missingWalletField = try removingTopLevelJSONValues(
                from: wallet,
                keys: [requiredWalletKey]
            )
            XCTAssertThrowsError(
                try JSONDecoder().decode(DiMyWalletRuntimeCell.self, from: missingWalletField)
            )
        }
        for requiredAccessKey in [
            "receiptCache",
            "merchantID",
            "redeemedBundleHashes",
            "redeemedCoinSerials",
            "replayHistoryMigrationRequired"
        ] {
            let missingAccessField = try removingTopLevelJSONValues(
                from: access,
                keys: [requiredAccessKey]
            )
            XCTAssertThrowsError(
                try JSONDecoder().decode(DiMyAccessRuntimeCell.self, from: missingAccessField)
            )
        }
        let missingPricingState = try removingTopLevelJSONValues(
            from: pricing,
            keys: ["pricesByResource"]
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(DiMyPricingPolicyCell.self, from: missingPricingState)
        )

        let legacyEmptyAccess = try removingTopLevelJSONValues(
            from: access,
            keys: [
                "persistenceSchemaVersion",
                "redeemedBundleHashes",
                "redeemedCoinSerials",
                "replayHistoryMigrationRequired"
            ]
        )
        XCTAssertNoThrow(
            try JSONDecoder().decode(DiMyAccessRuntimeCell.self, from: legacyEmptyAccess)
        )
    }

    func testWalletRejectsForgedDepositAndSemanticallyCorruptPersistedValue() async throws {
        let previousDebugAccess = CellBase.debugValidateAccessForEverything
        let previousExploreMode = CellBase.exploreContractEnforcementMode
        let previousVault = CellBase.defaultIdentityVault
        let vault = EphemeralIdentityVault()
        let mint = InMemoryMintClient()
        CellBase.debugValidateAccessForEverything = false
        CellBase.exploreContractEnforcementMode = .strict
        CellBase.defaultIdentityVault = vault
        await MintClientRegistry.shared.setFactory { mint }
        defer {
            CellBase.debugValidateAccessForEverything = previousDebugAccess
            CellBase.exploreContractEnforcementMode = previousExploreMode
            CellBase.defaultIdentityVault = previousVault
        }

        do {
            let owner = try await makeIdentity(in: vault, context: "dimy-wallet-semantic-corruption")
            let wallet = try roundTrip(await DiMyWalletRuntimeCell(owner: owner))
            let forged = Coin(
                denomMinorUnits: 1_000_000,
                serial: "forged-runtime-serial",
                mintKeyID: "dev-mint-key-1",
                keyEpoch: 1,
                signature: "forged-signature"
            )
            let deposit = try await wallet.set(
                keypath: "depositCoins",
                value: ValueTypeCodableBridge.encode([forged]),
                requester: owner
            )
            XCTAssertTrue(string(deposit)?.contains("invalidCoinSignature") == true)
            var state = try await wallet.get(keypath: "state", requester: owner)
            XCTAssertEqual(integer(state, key: "balanceMinorUnits"), 0)

            _ = try await wallet.set(
                keypath: "issue",
                value: .object(["amountMinorUnits": .integer(10)]),
                requester: owner
            )
            let availableObject = try topLevelJSONObject(wallet)
            let availableCoins = try XCTUnwrap(availableObject["storedCoins"] as? [Any])
            var duplicateObject = availableObject
            duplicateObject["storedCoins"] = availableCoins + availableCoins
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    DiMyWalletRuntimeCell.self,
                    from: JSONSerialization.data(withJSONObject: duplicateObject, options: [.sortedKeys])
                )
            )

            let spend = try await wallet.set(
                keypath: "spend",
                value: .object([
                    "priceMinorUnits": .integer(10),
                    "resourceID": .string("cell://persisted/semantic-integrity")
                ]),
                requester: owner
            )
            guard case .object? = spend else {
                await MintClientRegistry.shared.useEnvironmentDefault()
                return XCTFail("Expected pending spend bundle")
            }
            let pendingObject = try topLevelJSONObject(wallet)
            let cachedBundles = try XCTUnwrap(pendingObject["cachedBundles"] as? [String: Any])
            let cachedEntry = try XCTUnwrap(cachedBundles.first)
            let bundleObject = try XCTUnwrap(cachedEntry.value as? [String: Any])
            let pendingCoins = try XCTUnwrap(bundleObject["coins"] as? [Any])

            var overlapObject = pendingObject
            overlapObject["storedCoins"] = pendingCoins
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    DiMyWalletRuntimeCell.self,
                    from: JSONSerialization.data(withJSONObject: overlapObject, options: [.sortedKeys])
                )
            )

            var mismatchedKeyObject = pendingObject
            mismatchedKeyObject["cachedBundles"] = [UUID().uuidString: cachedEntry.value]
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    DiMyWalletRuntimeCell.self,
                    from: JSONSerialization.data(withJSONObject: mismatchedKeyObject, options: [.sortedKeys])
                )
            )

            let reloaded = try roundTrip(wallet)
            state = try await reloaded.get(keypath: "state", requester: owner)
            XCTAssertEqual(integer(state, key: "balanceMinorUnits"), 0)
            XCTAssertEqual(integer(state, key: "pendingBundles"), 1)
            await MintClientRegistry.shared.useEnvironmentDefault()
        } catch {
            await MintClientRegistry.shared.useEnvironmentDefault()
            throw error
        }
    }

    func testAccessRejectsInvalidPersistedReceiptAndCoinReplayHistory() async throws {
        let vault = EphemeralIdentityVault()
        let owner = try await makeIdentity(in: vault, context: "dimy-access-semantic-corruption")
        let access = await DiMyAccessRuntimeCell(owner: owner)
        let hash = String(repeating: "0", count: 64)
        let invalidReceipt = SpendReceipt(
            bundleHash: hash,
            merchantCreditRef: "forged",
            merchantID: "merchant.default",
            mintKeyID: "dev-mint-key-1",
            keyEpoch: 1,
            issuedAt: Date(),
            signature: "forged-signature"
        )
        let receiptObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(invalidReceipt))
        let corruptReceipt = try replacingTopLevelJSONValue(
            in: access,
            key: "receiptCache",
            value: [hash: receiptObject]
        )
        XCTAssertThrowsError(try JSONDecoder().decode(DiMyAccessRuntimeCell.self, from: corruptReceipt))

        let corruptSerialHistory = try replacingTopLevelJSONValue(
            in: access,
            key: "redeemedCoinSerials",
            value: [""]
        )
        XCTAssertThrowsError(try JSONDecoder().decode(DiMyAccessRuntimeCell.self, from: corruptSerialHistory))
    }

    func testReadinessInstallationNeverAuthorizesPublicOwnerOutsiderOrWrongKey() async throws {
        let previousDebugAccess = CellBase.debugValidateAccessForEverything
        let previousExploreMode = CellBase.exploreContractEnforcementMode
        let previousVault = CellBase.defaultIdentityVault
        let ownerVault = EphemeralIdentityVault()
        CellBase.debugValidateAccessForEverything = false
        CellBase.exploreContractEnforcementMode = .strict
        CellBase.defaultIdentityVault = ownerVault
        defer {
            CellBase.debugValidateAccessForEverything = previousDebugAccess
            CellBase.exploreContractEnforcementMode = previousExploreMode
            CellBase.defaultIdentityVault = previousVault
        }

        let owner = try await makeIdentity(in: ownerVault, context: "dimy-runtime-owner")
        let source = await DiMyPricingPolicyCell(owner: owner)
        let decoded = try roundTrip(source)
        let outsider = try await makeIdentity(in: EphemeralIdentityVault(), context: "dimy-runtime-outsider")
        let wrongKey = try await makeIdentity(
            in: EphemeralIdentityVault(),
            context: "dimy-runtime-wrong-key",
            uuid: owner.uuid
        )
        let publicOwner = try JSONDecoder().decode(Identity.self, from: JSONEncoder().encode(owner))
        XCTAssertNotEqual(owner.signingPublicKeyFingerprint, wrongKey.signingPublicKeyFingerprint)

        // An unrelated caller may trigger instance-scoped binding installation,
        // but Explore metadata is not an Agreement, proof or action grant.
        try await assertExactManifest(decoded, requester: outsider, expected: pricingOperations)
        let templateAfterInstall = try stableAgreementTemplateData(decoded)

        await assertDenied { _ = try await decoded.get(keypath: "state", requester: outsider) }
        await assertDenied { _ = try await decoded.get(keypath: "state", requester: publicOwner) }
        await assertDenied {
            _ = try await decoded.set(
                keypath: "setPrice",
                value: .object(["resourceID": .string("forbidden"), "priceMinorUnits": .integer(99)]),
                requester: wrongKey
            )
        }
        let ownerStateAfterDenials = try await decoded.get(keypath: "state", requester: owner)
        XCTAssertEqual(integer(ownerStateAfterDenials, key: "count"), 0)

        do {
            _ = try await decoded.set(keypath: "unknownAction", value: .null, requester: owner)
            XCTFail("Unknown actions must remain unavailable after readiness")
        } catch {
            XCTAssertTrue(String(describing: error).contains("notFound"))
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    try await decoded.ensureRuntimeBindings(requester: index.isMultiple(of: 2) ? outsider : wrongKey)
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(try stableAgreementTemplateData(decoded), templateAfterInstall)
        let ownerStateAfterConcurrency = try await decoded.get(keypath: "state", requester: owner)
        XCTAssertEqual(integer(ownerStateAfterConcurrency, key: "count"), 0)

        let ownerResult = try await decoded.set(
            keypath: "setPrice",
            value: .object(["resourceID": .string("allowed"), "priceMinorUnits": .integer(7)]),
            requester: owner
        )
        XCTAssertEqual(integer(ownerResult, key: "priceMinorUnits"), 7)
    }

    func testReadOnlySetQueriesHonorExactOwnerSignedReadContracts() async throws {
        let previousDebugAccess = CellBase.debugValidateAccessForEverything
        let previousExploreMode = CellBase.exploreContractEnforcementMode
        let previousVault = CellBase.defaultIdentityVault
        let ownerVault = EphemeralIdentityVault()
        let readerVault = EphemeralIdentityVault()
        let mint = InMemoryMintClient()
        CellBase.debugValidateAccessForEverything = false
        CellBase.exploreContractEnforcementMode = .strict
        CellBase.defaultIdentityVault = ownerVault
        await MintClientRegistry.shared.setFactory { mint }
        defer {
            CellBase.debugValidateAccessForEverything = previousDebugAccess
            CellBase.exploreContractEnforcementMode = previousExploreMode
            CellBase.defaultIdentityVault = previousVault
        }

        do {
            let owner = try await makeIdentity(in: ownerVault, context: "dimy-read-contract-owner")
            let reader = try await makeIdentity(
                in: readerVault,
                context: "dimy-read-contract-reader",
                uuid: UUID().uuidString
            )
            let wallet = try roundTrip(await DiMyWalletRuntimeCell(owner: owner))
            let access = try roundTrip(await DiMyAccessRuntimeCell(owner: owner))
            let pricing = try roundTrip(await DiMyPricingPolicyCell(owner: owner))

            let issued = try await wallet.set(
                keypath: "issue",
                value: .object(["amountMinorUnits": .integer(15)]),
                requester: owner
            )
            XCTAssertEqual(integer(issued, nestedObjectKey: "state", key: "balanceMinorUnits"), 15)
            let spend = try await wallet.set(
                keypath: "spend",
                value: .object([
                    "priceMinorUnits": .integer(10),
                    "resourceID": .string("cell://strict/read-contract-resource")
                ]),
                requester: owner
            )
            let redeemed = try await access.set(
                keypath: "verifyAndRedeem",
                value: try XCTUnwrap(spend),
                requester: owner
            )
            let receiptHash = try XCTUnwrap(string(redeemed, nestedObjectKey: "receipt", key: "bundleHash"))

            _ = try await pricing.set(
                keypath: "setPrice",
                value: .object([
                    "resourceID": .string("resource.read-contract"),
                    "priceMinorUnits": .integer(23)
                ]),
                requester: owner
            )
            let accessStateBefore = try await access.get(keypath: "state", requester: owner)
            let pricingStateBefore = try await pricing.get(keypath: "state", requester: owner)

            try await admitReadContract(on: access, keypath: "receipt", owner: owner, subject: reader)
            try await admitReadContract(on: pricing, keypath: "quote", owner: owner, subject: reader)

            let resolver = CellResolver.sharedInstance
            let accessEndpoint = "DiMyAccessReadContract-\(UUID().uuidString)"
            let pricingEndpoint = "DiMyPricingReadContract-\(UUID().uuidString)"
            try await resolver.registerNamedEmitCell(
                name: accessEndpoint,
                emitCell: access,
                scope: .scaffoldUnique,
                identity: owner
            )
            try await resolver.registerNamedEmitCell(
                name: pricingEndpoint,
                emitCell: pricing,
                scope: .scaffoldUnique,
                identity: owner
            )
            defer {
                Task {
                    await resolver.unregisterEmitCell(uuid: access.uuid)
                    await resolver.unregisterEmitCell(uuid: pricing.uuid)
                }
            }

            let receipt = try await access.set(
                keypath: "receipt",
                value: .object(["bundleHash": .string(receiptHash)]),
                requester: reader
            )
            XCTAssertEqual(string(receipt, key: "bundleHash"), receiptHash)
            let resolverReceipt = try await resolver.set(
                value: .object(["bundleHash": .string(receiptHash)]),
                into: try XCTUnwrap(URL(string: "cell:///\(accessEndpoint)/receipt")),
                requester: reader
            )
            XCTAssertEqual(string(resolverReceipt, key: "bundleHash"), receiptHash)
            let quote = try await pricing.set(
                keypath: "quote",
                value: .object(["resourceID": .string("resource.read-contract")]),
                requester: reader
            )
            XCTAssertEqual(integer(quote, key: "priceMinorUnits"), 23)
            let resolverQuote = try await resolver.set(
                value: .object(["resourceID": .string("resource.read-contract")]),
                into: try XCTUnwrap(URL(string: "cell:///\(pricingEndpoint)/quote")),
                requester: reader
            )
            XCTAssertEqual(integer(resolverQuote, key: "priceMinorUnits"), 23)

            await assertDenied { _ = try await access.get(keypath: "state", requester: reader) }
            await assertDenied { _ = try await access.get(keypath: "merchantID", requester: reader) }
            await assertDenied {
                _ = try await access.set(keypath: "merchantID", value: .string("forbidden"), requester: reader)
            }
            await assertDenied { _ = try await pricing.get(keypath: "state", requester: reader) }
            await assertDenied {
                _ = try await pricing.set(
                    keypath: "setPrice",
                    value: .object(["resourceID": .string("forbidden"), "priceMinorUnits": .integer(99)]),
                    requester: reader
                )
            }
            await assertDenied {
                _ = try await pricing.set(
                    keypath: "removePrice",
                    value: .object(["resourceID": .string("resource.read-contract")]),
                    requester: reader
                )
            }

            let accessStateAfter = try await access.get(keypath: "state", requester: owner)
            let pricingStateAfter = try await pricing.get(keypath: "state", requester: owner)
            XCTAssertEqual(
                integer(accessStateAfter, key: "receiptCount"),
                integer(accessStateBefore, key: "receiptCount")
            )
            XCTAssertEqual(
                string(accessStateAfter, key: "merchantID"),
                string(accessStateBefore, key: "merchantID")
            )
            XCTAssertEqual(
                integer(pricingStateAfter, key: "count"),
                integer(pricingStateBefore, key: "count")
            )
            await MintClientRegistry.shared.useEnvironmentDefault()
        } catch {
            await MintClientRegistry.shared.useEnvironmentDefault()
            throw error
        }
    }

    func testEveryRuntimeOperationRejectsOutsiderAndWrongKeyWithoutMutation() async throws {
        let previousDebugAccess = CellBase.debugValidateAccessForEverything
        let previousExploreMode = CellBase.exploreContractEnforcementMode
        let previousVault = CellBase.defaultIdentityVault
        let ownerVault = EphemeralIdentityVault()
        CellBase.debugValidateAccessForEverything = false
        CellBase.exploreContractEnforcementMode = .strict
        CellBase.defaultIdentityVault = ownerVault
        defer {
            CellBase.debugValidateAccessForEverything = previousDebugAccess
            CellBase.exploreContractEnforcementMode = previousExploreMode
            CellBase.defaultIdentityVault = previousVault
        }

        let owner = try await makeIdentity(in: ownerVault, context: "dimy-operation-owner")
        let outsider = try await makeIdentity(in: EphemeralIdentityVault(), context: "dimy-operation-outsider")
        let wrongKey = try await makeIdentity(
            in: EphemeralIdentityVault(),
            context: "dimy-operation-wrong-key",
            uuid: owner.uuid
        )
        let publicOwner = try JSONDecoder().decode(Identity.self, from: JSONEncoder().encode(owner))
        let wallet = try roundTrip(await DiMyWalletRuntimeCell(owner: owner))
        let access = try roundTrip(await DiMyAccessRuntimeCell(owner: owner))
        let pricing = try roundTrip(await DiMyPricingPolicyCell(owner: owner))

        // Install all schemas from an unrelated caller before checking access,
        // so this gate rejects metadata-as-authority regressions.
        try await assertExactManifest(wallet, requester: outsider, expected: walletOperations)
        try await assertExactManifest(access, requester: outsider, expected: accessOperations)
        try await assertExactManifest(pricing, requester: outsider, expected: pricingOperations)
        let templatesBefore = try [wallet, access, pricing].map(stableAgreementTemplateData)

        for requester in [outsider, wrongKey, publicOwner] {
            await assertDenied { _ = try await wallet.get(keypath: "state", requester: requester) }
            await assertDenied {
                _ = try await wallet.set(
                    keypath: "issue",
                    value: .object(["amountMinorUnits": .integer(15)]),
                    requester: requester
                )
            }
            await assertDenied {
                _ = try await wallet.set(
                    keypath: "spend",
                    value: .object(["priceMinorUnits": .integer(1), "resourceID": .string("forbidden")]),
                    requester: requester
                )
            }
            await assertDenied {
                _ = try await wallet.set(
                    keypath: "rollback",
                    value: .object(["requestID": .string(UUID().uuidString)]),
                    requester: requester
                )
            }
            await assertDenied {
                _ = try await wallet.set(keypath: "depositCoins", value: .list([]), requester: requester)
            }

            await assertDenied { _ = try await access.get(keypath: "state", requester: requester) }
            await assertDenied { _ = try await access.get(keypath: "merchantID", requester: requester) }
            await assertDenied {
                _ = try await access.set(keypath: "merchantID", value: .string("forbidden"), requester: requester)
            }
            await assertDenied {
                _ = try await access.set(keypath: "verifyAndRedeem", value: .object([:]), requester: requester)
            }
            await assertDenied {
                _ = try await access.set(keypath: "receipt", value: .string("known-hash-is-not-authority"), requester: requester)
            }

            await assertDenied { _ = try await pricing.get(keypath: "state", requester: requester) }
            await assertDenied {
                _ = try await pricing.set(
                    keypath: "setPrice",
                    value: .object(["resourceID": .string("forbidden"), "priceMinorUnits": .integer(99)]),
                    requester: requester
                )
            }
            await assertDenied {
                _ = try await pricing.set(
                    keypath: "removePrice",
                    value: .object(["resourceID": .string("forbidden")]),
                    requester: requester
                )
            }
            await assertDenied {
                _ = try await pricing.set(
                    keypath: "quote",
                    value: .object(["resourceID": .string("forbidden")]),
                    requester: requester
                )
            }
        }

        let walletState = try await wallet.get(keypath: "state", requester: owner)
        let accessState = try await access.get(keypath: "state", requester: owner)
        let pricingState = try await pricing.get(keypath: "state", requester: owner)
        XCTAssertEqual(integer(walletState, key: "balanceMinorUnits"), 0)
        XCTAssertEqual(integer(walletState, key: "coinCount"), 0)
        XCTAssertEqual(string(accessState, key: "merchantID"), "merchant.default")
        XCTAssertEqual(integer(accessState, key: "receiptCount"), 0)
        XCTAssertEqual(integer(pricingState, key: "count"), 0)
        XCTAssertEqual(try [wallet, access, pricing].map(stableAgreementTemplateData), templatesBefore)
    }

    private var walletOperations: [String: [String]] {
        [
            "get:state": ["r---"],
            "set:issue": ["rw--"],
            "set:spend": ["rw--"],
            "set:rollback": ["rw--"],
            "set:depositCoins": ["rw--"]
        ]
    }

    private var accessOperations: [String: [String]] {
        [
            "get:state": ["r---"],
            "get:merchantID": ["r---"],
            "set:merchantID": ["rw--"],
            "set:verifyAndRedeem": ["rw--"],
            "set:receipt": ["r---"]
        ]
    }

    private var pricingOperations: [String: [String]] {
        [
            "get:state": ["r---"],
            "set:setPrice": ["rw--"],
            "set:removePrice": ["rw--"],
            "set:quote": ["r---"]
        ]
    }

    private func assertExactManifest(
        _ cell: GeneralCell,
        requester: Identity,
        expected: [String: [String]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let manifest = try await cell.exploreManifest(requester: requester)
        XCTAssertEqual(
            Set(manifest.operations.map { "\($0.method):\($0.key)" }),
            Set(expected.keys),
            file: file,
            line: line
        )
        XCTAssertEqual(manifest.operations.count, expected.count, file: file, line: line)
        for operation in manifest.operations {
            let operationID = "\(operation.method):\(operation.key)"
            XCTAssertEqual(operation.permissions, expected[operationID], file: file, line: line)
            XCTAssertNotEqual(operation.summary, "*", file: file, line: line)
            XCTAssertNotEqual(operation.inputType, "unknown", file: file, line: line)
            XCTAssertNotEqual(operation.returnType, "unknown", file: file, line: line)
        }
    }

    private func assertObjectState(
        _ cell: GeneralCell,
        requester: Identity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let state = try await cell.get(keypath: "state", requester: requester)
        guard case .object = state else {
            return XCTFail("Expected object state for \(type(of: cell)), got \(state)", file: file, line: line)
        }
    }

    private func assertDenied(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected Cell authorization denial", file: file, line: line)
        } catch {
            XCTAssertTrue(String(describing: error).contains("denied"), "Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func makeIdentity(
        in vault: EphemeralIdentityVault,
        context: String,
        uuid: String? = nil
    ) async throws -> Identity {
        if let uuid {
            var identity = Identity(uuid, displayName: context, identityVault: vault)
            await vault.addIdentity(identity: &identity, for: context)
            return identity
        }
        let identity = await vault.identity(for: "\(context)-\(UUID().uuidString)", makeNewIfNotFound: true)
        return try XCTUnwrap(identity)
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func replacingTopLevelJSONValue<T: Encodable>(
        in value: T,
        key: String,
        value replacement: Any
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object[key] = replacement
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func topLevelJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoded = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    }

    private func removingTopLevelJSONValues<T: Encodable>(
        from value: T,
        keys: [String]
    ) throws -> Data {
        var object = try topLevelJSONObject(value)
        for key in keys {
            object.removeValue(forKey: key)
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func stableAgreementTemplateData(_ cell: GeneralCell) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(cell.agreementTemplate)
    }

    private func admitReadContract(
        on cell: GeneralCell,
        keypath: String,
        owner: Identity,
        subject: Identity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let agreement = Agreement(owner: owner)
        agreement.addGrant("r---", for: keypath)
        let state = await cell.addAgreement(agreement, for: subject, authorizedBy: owner)
        XCTAssertEqual(state, .signed, file: file, line: line)
        let accessAllowed = await cell.validateAccess("r---", at: keypath, for: subject)
        XCTAssertTrue(accessAllowed, file: file, line: line)
    }

    private func object(_ value: ValueType?) -> Object? {
        guard case let .object(object)? = value else { return nil }
        return object
    }

    private func integer(_ value: ValueType?, key: String) -> Int? {
        guard case let .integer(integer)? = object(value)?[key] else { return nil }
        return integer
    }

    private func integer(_ value: ValueType?, nestedObjectKey: String, key: String) -> Int? {
        guard case let .object(nested)? = object(value)?[nestedObjectKey] else { return nil }
        guard case let .integer(integer)? = nested[key] else { return nil }
        return integer
    }

    private func string(_ value: ValueType?) -> String? {
        guard case let .string(string)? = value else { return nil }
        return string
    }

    private func string(_ value: ValueType?, key: String) -> String? {
        guard case let .string(string)? = object(value)?[key] else { return nil }
        return string
    }

    private func string(_ value: ValueType?, nestedObjectKey: String, key: String) -> String? {
        guard case let .object(nested)? = object(value)?[nestedObjectKey] else { return nil }
        guard case let .string(string)? = nested[key] else { return nil }
        return string
    }
}
