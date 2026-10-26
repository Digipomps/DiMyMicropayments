import XCTest
import DiMyAccessCell
import DiMyMintClient
import DiMyPaymentTypes
import DiMyWalletCell

final class AccessCellTests: XCTestCase {
    func testRedeemAcceptsFirstSpendAndRejectsSecondSpend() async throws {
        let mintClient = InMemoryMintClient()
        let wallet = WalletCell(mintClient: mintClient)
        let accessCellA = AccessCell(merchantID: "merchant-A", mintClient: mintClient)
        let accessCellB = AccessCell(merchantID: "merchant-B", mintClient: mintClient)

        _ = try await wallet.issue(amountMinorUnits: 15, strategy: .oneTwoFive)
        let bundle = try await wallet.spend(priceMinorUnits: 10, resourceID: "cell://demo/resource")

        let grant = try await accessCellA.verifyAndRedeem(bundle: bundle)
        XCTAssertEqual(grant.resourceID, "cell://demo/resource")

        do {
            _ = try await accessCellB.verifyAndRedeem(bundle: bundle)
            XCTFail("Expected double-spend rejection")
        } catch AccessCellError.redemptionRejected(let reason) {
            XCTAssertEqual(reason, .doubleSpend)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRedeemRejectsTamperedCoinSignature() async throws {
        let mintClient = InMemoryMintClient()
        let wallet = WalletCell(mintClient: mintClient)
        let accessCell = AccessCell(merchantID: "merchant-A", mintClient: mintClient)

        _ = try await wallet.issue(amountMinorUnits: 15, strategy: .oneTwoFive)
        let original = try await wallet.spend(priceMinorUnits: 10, resourceID: "cell://demo/resource")
        let firstCoin = try XCTUnwrap(original.coins.first)

        let tamperedCoin = Coin(
            denomMinorUnits: firstCoin.denomMinorUnits,
            serial: firstCoin.serial,
            mintKeyID: firstCoin.mintKeyID,
            signature: "ed25519:\(firstCoin.mintKeyID):AAAA"
        )
        let tamperedBundle = SpendBundle(
            coins: [tamperedCoin] + Array(original.coins.dropFirst()),
            requestID: original.requestID,
            resourceID: original.resourceID,
            createdAt: original.createdAt
        )

        do {
            _ = try await accessCell.verifyAndRedeem(bundle: tamperedBundle)
            XCTFail("Expected invalid signature rejection")
        } catch AccessCellError.invalidCoinSignature(let serial) {
            XCTAssertEqual(serial, firstCoin.serial)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testConcurrentRedeemOfSameBundleIsRejectedAsLocalReplay() async throws {
        let mintClient = InMemoryMintClient()
        let wallet = WalletCell(mintClient: mintClient)
        let access = AccessCell(merchantID: "merchant.concurrent", mintClient: mintClient)
        _ = try await wallet.issue(amountMinorUnits: 10)
        let bundle = try await wallet.spend(
            priceMinorUnits: 10,
            resourceID: "cell://concurrent/redeem"
        )

        let outcomes = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try await access.verifyAndRedeem(bundle: bundle)
                        return "accepted"
                    } catch {
                        return String(describing: error)
                    }
                }
            }

            var values: [String] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(outcomes.filter { $0 == "accepted" }.count, 1)
        XCTAssertEqual(outcomes.filter { $0.contains("replayedBundle") }.count, 1)
    }

    func testRejectsEmptyBundleWithoutCallingMint() async throws {
        let access = AccessCell(merchantID: "merchant.empty", mintClient: InMemoryMintClient())
        let empty = SpendBundle(
            coins: [],
            requestID: UUID(),
            resourceID: "cell://empty/value",
            createdAt: Date()
        )

        do {
            _ = try await access.verifyAndRedeem(bundle: empty)
            XCTFail("Expected empty bundle rejection")
        } catch AccessCellError.invalidBundle {
            // Expected.
        }
    }
}
