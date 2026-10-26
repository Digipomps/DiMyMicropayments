import XCTest
import DiMyMintClient
import DiMyPaymentTypes
import DiMyWalletCell

private actor ForgedIssueMintClient: MintClient {
    func issue(_ request: IssueRequest) async throws -> IssueResponse {
        IssueResponse(
            signatures: request.requests.map {
                BlindSignature(
                    denomMinorUnits: $0.denomMinorUnits,
                    blindedSignature: "forged-signature",
                    mintKeyID: $0.mintKeyID,
                    keyEpoch: 1
                )
            },
            debitedMinorUnits: request.requests.reduce(0) { $0 + $1.denomMinorUnits },
            issuedAt: Date()
        )
    }

    func redeem(_ request: RedeemRequest) async throws -> RedeemResponse {
        .rejected(.unknown)
    }
}

private actor RecordingMintClient: MintClient {
    private var issueCalls = 0

    func issue(_ request: IssueRequest) async throws -> IssueResponse {
        issueCalls += 1
        throw MintClientError.notImplemented
    }

    func redeem(_ request: RedeemRequest) async throws -> RedeemResponse {
        throw MintClientError.notImplemented
    }

    func issueCallCount() -> Int {
        issueCalls
    }
}

final class WalletCellTests: XCTestCase {
    func testIssueAndSpendReducesBalance() async throws {
        let mintClient = InMemoryMintClient()
        let wallet = WalletCell(mintClient: mintClient)

        _ = try await wallet.issue(amountMinorUnits: 37, strategy: .oneTwoFive)
        let initialBalance = await wallet.balanceMinorUnits()
        XCTAssertEqual(initialBalance, 37)

        let bundle = try await wallet.spend(priceMinorUnits: 12, resourceID: "cell://demo/resource")
        XCTAssertEqual(bundle.totalMinorUnits, 12)

        let remaining = await wallet.balanceMinorUnits()
        XCTAssertEqual(remaining, 25)
    }

    func testRollbackRestoresSpentCoins() async throws {
        let mintClient = InMemoryMintClient()
        let wallet = WalletCell(mintClient: mintClient)

        _ = try await wallet.issue(amountMinorUnits: 15, strategy: .oneTwoFive)
        let bundle = try await wallet.spend(priceMinorUnits: 10, resourceID: "cell://demo/resource")
        try await wallet.rollback(bundle: bundle)

        let balance = await wallet.balanceMinorUnits()
        XCTAssertEqual(balance, 15)
    }

    func testDepositAndRollbackAreIdempotentByCoinSerial() async throws {
        let mintClient = InMemoryMintClient()
        let wallet = WalletCell(mintClient: mintClient)

        let issued = try await wallet.issue(amountMinorUnits: 10)
        try await wallet.deposit(issued)
        try await wallet.deposit(issued)
        let balanceAfterDeposits = await wallet.balanceMinorUnits()
        XCTAssertEqual(balanceAfterDeposits, 10)

        let bundle = try await wallet.spend(
            priceMinorUnits: 10,
            resourceID: "cell://idempotent/rollback"
        )
        try await wallet.rollback(bundle: bundle)
        try await wallet.rollback(bundle: bundle)
        let balanceAfterRollbacks = await wallet.balanceMinorUnits()
        let inventoryAfterRollbacks = await wallet.coinInventory()
        XCTAssertEqual(balanceAfterRollbacks, 10)
        XCTAssertEqual(inventoryAfterRollbacks.count, issued.count)
    }

    func testIssuedCoinsCarryKeyEpoch() async throws {
        let mintClient = InMemoryMintClient(signingKeyEpoch: 42)
        let wallet = WalletCell(mintClient: mintClient)

        let issued = try await wallet.issue(amountMinorUnits: 6, strategy: .oneTwoFive)

        XCTAssertFalse(issued.isEmpty)
        XCTAssertTrue(issued.allSatisfy { $0.keyEpoch == 42 })
    }

    func testUnitStrategySupportsChangingMicropaymentPricesWithoutExactChangeFailure() async throws {
        let mintClient = InMemoryMintClient()
        let wallet = WalletCell(mintClient: mintClient)

        let issued = try await wallet.issue(amountMinorUnits: 30, strategy: .unit)
        XCTAssertEqual(issued.count, 30)
        XCTAssertTrue(issued.allSatisfy { $0.denomMinorUnits == 1 })

        _ = try await wallet.spend(priceMinorUnits: 10, resourceID: "cell://music/first")
        _ = try await wallet.spend(priceMinorUnits: 7, resourceID: "cell://music/second")
        _ = try await wallet.spend(priceMinorUnits: 5, resourceID: "cell://music/floor")
        let remainingBalance = await wallet.balanceMinorUnits()
        XCTAssertEqual(remainingBalance, 8)
    }

    func testDepositRejectsForgedCoinAndSerialCollisionWithoutMutatingBalance() async throws {
        let mintClient = InMemoryMintClient()
        let wallet = WalletCell(mintClient: mintClient)
        let issued = try await wallet.issue(amountMinorUnits: 1)
        let original = try XCTUnwrap(issued.first)

        let forged = Coin(
            denomMinorUnits: 1_000_000,
            serial: "forged-unique-serial",
            mintKeyID: original.mintKeyID,
            keyEpoch: original.keyEpoch,
            signature: "forged-signature"
        )
        do {
            try await wallet.deposit([forged])
            XCTFail("Expected forged signature rejection")
        } catch WalletCellError.invalidCoinSignature(let serial) {
            XCTAssertEqual(serial, forged.serial)
        }

        let collision = Coin(
            denomMinorUnits: original.denomMinorUnits + 1,
            serial: original.serial,
            mintKeyID: original.mintKeyID,
            keyEpoch: original.keyEpoch,
            signature: original.signature
        )
        do {
            try await wallet.deposit([collision])
            XCTFail("Expected serial collision rejection")
        } catch WalletCellError.coinSerialCollision(let serial) {
            XCTAssertEqual(serial, original.serial)
        }

        let balance = await wallet.balanceMinorUnits()
        let inventory = await wallet.coinInventory()
        XCTAssertEqual(balance, 1)
        XCTAssertEqual(inventory, issued)
    }

    func testIssueRejectsForgedMintResponseWithoutMutatingBalance() async throws {
        let wallet = WalletCell(mintClient: ForgedIssueMintClient())

        do {
            _ = try await wallet.issue(amountMinorUnits: 10)
            XCTFail("Expected forged mint response rejection")
        } catch WalletCellError.invalidCoinSignature {
            // Expected.
        }

        let balance = await wallet.balanceMinorUnits()
        let inventory = await wallet.coinInventory()
        XCTAssertEqual(balance, 0)
        XCTAssertTrue(inventory.isEmpty)
    }

    func testIssueRejectsMissingVerificationKeyBeforeCallingMint() async throws {
        let mint = RecordingMintClient()
        let wallet = WalletCell(
            mintKeyID: "mint-unconfigured",
            mintClient: mint,
            verificationRegistry: .development
        )

        do {
            _ = try await wallet.issue(amountMinorUnits: 10)
            XCTFail("Expected missing verification key rejection")
        } catch WalletCellError.missingVerificationKey(let keyID) {
            XCTAssertEqual(keyID, "mint-unconfigured")
        }

        let callCount = await mint.issueCallCount()
        XCTAssertEqual(callCount, 0)
    }
}
