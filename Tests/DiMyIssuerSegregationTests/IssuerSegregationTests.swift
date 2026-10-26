import XCTest
import DiMyAccessCell
import DiMyMintClient
import DiMyPaymentTypes
import DiMyWalletCell

/// Kvote fra to utstedere skal aldri kunne blandes.
///
/// Testene her er skrevet for å være **røde mot revisjonen 1b31aece** og
/// grønne etter at segregeringen er på plass. En test som var grønn før
/// endringen beviser ingenting om endringen.
final class IssuerSegregationTests: XCTestCase {

    // MARK: - R2: myntutvalg skjer innenfor én utsteder

    /// Kjernen i hele bestillingen.
    ///
    /// 30 fra A og 20 fra B dekker 40 til sammen, men ingen av dem dekker 40
    /// alene. Handlingen skal derfor ikke skje. Mot dagens kode plukker
    /// `selectCoins` grådig på tvers av utstedere og returnerer et bundle med
    /// mynt fra begge.
    func testSpendCannotCombineCoinsFromTwoIssuers() async throws {
        let registry = IssuerFixture.twoIssuerRegistry()
        let wallet = IssuerFixture.walletA(registry: registry)

        _ = try await wallet.issue(amountMinorUnits: 30, strategy: .oneTwoFive)
        let foreignCoins = try await IssuerFixture.coinsFromIssuerB(
            amountMinorUnits: 20,
            registry: registry
        )
        // Mot dagens kode lykkes dette innskuddet. Etter R5 skal det feile.
        // Testen tåler begge utfall her, fordi det den skal bevise er at
        // *forbruket* aldri blander.
        try? await wallet.deposit(foreignCoins)

        do {
            let bundle = try await wallet.spend(
                priceMinorUnits: 40,
                resourceID: "cell:///demo/resource"
            )
            let issuers = Set(bundle.coins.map(\.mintKeyID))
            XCTFail(
                """
                Et forbruk på 40 skal ikke kunne gjennomføres når ingen enkelt \
                utsteder dekker det. Fikk et bundle på \
                \(bundle.totalMinorUnits) med utstedere \(issuers.sorted()).
                """
            )
        } catch {
            // Riktig utfall: ingen enkelt utsteder dekker 40.
        }

        let balanceA = await wallet.balanceMinorUnits()
        XCTAssertEqual(
            balanceA,
            30,
            "Lommeboka til A skal rapportere As saldo, ikke summen på tvers av utstedere."
        )
    }

    /// Et bundle skal alltid være ensartet, også når det faktisk finnes
    /// dekning hos én utsteder.
    func testSpendWithCoverageStaysWithinOneIssuer() async throws {
        let registry = IssuerFixture.twoIssuerRegistry()
        let wallet = IssuerFixture.walletA(registry: registry)

        _ = try await wallet.issue(amountMinorUnits: 30, strategy: .oneTwoFive)
        let foreignCoins = try await IssuerFixture.coinsFromIssuerB(
            amountMinorUnits: 20,
            registry: registry
        )
        try? await wallet.deposit(foreignCoins)

        let bundle = try await wallet.spend(
            priceMinorUnits: 20,
            resourceID: "cell:///demo/resource"
        )
        XCTAssertEqual(
            Set(bundle.coins.map(\.mintKeyID)),
            [IssuerFixture.issuerAKeyID],
            "Bundlet skal bare inneholde mynt fra lommebokas egen utsteder."
        )
    }

    // MARK: - R5/R6: fremmed utsteder kommer ikke inn

    func testDepositRejectsCoinsFromAnotherIssuer() async throws {
        let registry = IssuerFixture.twoIssuerRegistry()
        let wallet = IssuerFixture.walletA(registry: registry)
        _ = try await wallet.issue(amountMinorUnits: 30, strategy: .oneTwoFive)

        let foreignCoins = try await IssuerFixture.coinsFromIssuerB(
            amountMinorUnits: 20,
            registry: registry
        )

        do {
            try await wallet.deposit(foreignCoins)
            XCTFail("En lommebok bundet til A skal avvise mynt fra B.")
        } catch {
            // Riktig utfall.
        }

        let balance = await wallet.balanceMinorUnits()
        XCTAssertEqual(balance, 30, "Et avvist innskudd skal ikke endre saldoen.")
    }

    func testRollbackRejectsBundleFromAnotherIssuer() async throws {
        let registry = IssuerFixture.twoIssuerRegistry()
        let walletA = IssuerFixture.walletA(registry: registry)
        let walletB = IssuerFixture.walletB(registry: registry)

        _ = try await walletA.issue(amountMinorUnits: 30, strategy: .oneTwoFive)
        _ = try await walletB.issue(amountMinorUnits: 20, strategy: .oneTwoFive)

        let foreignBundle = try await walletB.spend(
            priceMinorUnits: 20,
            resourceID: "cell:///demo/resource"
        )

        do {
            try await walletA.rollback(bundle: foreignBundle)
            XCTFail("Tilbakerulling skal ikke kunne smugle fremmed verdi inn i A.")
        } catch {
            // Riktig utfall.
        }

        let balance = await walletA.balanceMinorUnits()
        XCTAssertEqual(balance, 30, "En avvist tilbakerulling skal ikke endre saldoen.")
    }

    // MARK: - R4: innløsning avviser blandet bundle

    func testRedeemRejectsBundleWithMixedIssuers() async throws {
        let registry = IssuerFixture.twoIssuerRegistry()

        let walletA = IssuerFixture.walletA(registry: registry)
        let walletB = IssuerFixture.walletB(registry: registry)
        let coinsA = try await walletA.issue(amountMinorUnits: 5, strategy: .oneTwoFive)
        let coinsB = try await walletB.issue(amountMinorUnits: 5, strategy: .oneTwoFive)

        // Et håndlaget blandet bundle - nøyaktig det en feil i utvalget ville
        // produsert.
        let mixed = SpendBundle(
            coins: coinsA + coinsB,
            requestID: UUID(),
            resourceID: "cell:///demo/resource",
            createdAt: Date()
        )
        XCTAssertGreaterThan(
            Set(mixed.coins.map(\.mintKeyID)).count,
            1,
            "Forutsetningen for testen: bundlet skal faktisk være blandet."
        )

        let access = AccessCell(
            merchantID: "test-merchant",
            mintClient: IssuerFixture.mintA(registry: registry),
            verifier: DevelopmentCoinVerifier(keyRegistry: registry)
        )

        do {
            _ = try await access.verifyAndRedeem(bundle: mixed)
            XCTFail("Innløsning skal avvise et bundle med mynt fra to utstedere.")
        } catch {
            // Riktig utfall.
        }
    }

    // MARK: - R4: ensartethet er kontrollerbart utenfra

    func testUniformIssuerIsObservableOnTheBundle() async throws {
        let registry = IssuerFixture.twoIssuerRegistry()
        let walletA = IssuerFixture.walletA(registry: registry)
        let walletB = IssuerFixture.walletB(registry: registry)
        let coinsA = try await walletA.issue(amountMinorUnits: 5, strategy: .oneTwoFive)
        let coinsB = try await walletB.issue(amountMinorUnits: 5, strategy: .oneTwoFive)

        let uniform = SpendBundle(
            coins: coinsA,
            requestID: UUID(),
            resourceID: "cell:///demo/resource",
            createdAt: Date()
        )
        let mixed = SpendBundle(
            coins: coinsA + coinsB,
            requestID: UUID(),
            resourceID: "cell:///demo/resource",
            createdAt: Date()
        )

        XCTAssertEqual(uniform.uniformMintKeyID, IssuerFixture.issuerAKeyID)
        XCTAssertNil(
            mixed.uniformMintKeyID,
            "Et blandet bundle har ingen utsteder, og skal si det selv."
        )
    }

    // MARK: - R7: kohort håndheves

    func testCoinFromRetiredKeyEpochCannotBeUsed() async throws {
        // Utsteder B har gått videre til kohort 2. Mynt fra kohort 1 er død.
        let registry = IssuerFixture.twoIssuerRegistry(
            currentEpochByKeyID: [IssuerFixture.issuerBKeyID: 2]
        )
        let oldEpochCoins = try await IssuerFixture.coinsFromIssuerB(
            amountMinorUnits: 20,
            registry: IssuerFixture.twoIssuerRegistry(),
            keyEpoch: 1
        )

        let wallet = IssuerFixture.walletB(registry: registry, keyEpoch: 2)
        do {
            try await wallet.deposit(oldEpochCoins)
            XCTFail("Mynt fra en pensjonert nøkkelkohort skal ikke kunne brukes.")
        } catch {
            // Riktig utfall.
        }

        let balance = await wallet.balanceMinorUnits()
        XCTAssertEqual(balance, 0)
    }
    func testReceiptMustBindIssuerMerchantAndCurrentEpochWithoutPoisoningRetry() async throws {
        let registry = IssuerFixture.twoIssuerRegistry(currentEpochByKeyID: [IssuerFixture.issuerAKeyID: 2])
        let wallet = IssuerFixture.walletA(registry: registry, keyEpoch: 2)
        _ = try await wallet.issue(amountMinorUnits: 5)
        let bundle = try await wallet.spend(priceMinorUnits: 5, resourceID: "cell:///receipt-binding")
        let client = ReceiptBindingMint()
        let access = AccessCell(merchantID: "merchant-A", mintClient: client,
            verifier: DevelopmentCoinVerifier(keyRegistry: registry), acceptedMintKeyIDs: [IssuerFixture.issuerAKeyID])
        for mode in ["wrong-issuer", "wrong-merchant", "retired-epoch"] {
            await client.setMode(mode)
            do { _ = try await access.verifyAndRedeem(bundle: bundle); XCTFail("Accepted \(mode)") }
            catch AccessCellError.mismatchedReceiptRecipient { XCTAssertNotEqual(mode, "retired-epoch") }
            catch AccessCellError.invalidReceiptSignature { XCTAssertEqual(mode, "retired-epoch") }
        }
        await client.setMode("valid")
        let grant = try await access.verifyAndRedeem(bundle: bundle)
        XCTAssertEqual(grant.resourceID, bundle.resourceID)
    }

}

private actor ReceiptBindingMint: MintClient {
    var mode = "valid"
    func setMode(_ value: String) { mode = value }
    func issue(_ request: IssueRequest) async throws -> IssueResponse { throw MintClientError.notImplemented }
    func redeem(_ request: RedeemRequest) async throws -> RedeemResponse {
        let wrongIssuer = mode == "wrong-issuer"
        let keyID = wrongIssuer ? IssuerFixture.issuerBKeyID : IssuerFixture.issuerAKeyID
        let seed = try XCTUnwrap(HexCodec.decode(wrongIssuer ? IssuerFixture.issuerBSeedHex : IssuerFixture.issuerASeedHex))
        let unsigned = SpendReceipt(bundleHash: request.bundleHash, merchantCreditRef: "test-credit",
            merchantID: mode == "wrong-merchant" ? "merchant-B" : request.merchantID,
            mintKeyID: keyID, keyEpoch: mode == "retired-epoch" ? 1 : 2, issuedAt: Date(), signature: "")
        let signature = try SpendReceiptSignatureSigner.signEd25519(receipt: unsigned, keyID: keyID, privateKeySeed: seed)
        return .accepted(SpendReceipt(bundleHash: unsigned.bundleHash, merchantCreditRef: unsigned.merchantCreditRef,
            merchantID: unsigned.merchantID, mintKeyID: keyID, keyEpoch: unsigned.keyEpoch, issuedAt: unsigned.issuedAt, signature: signature))
    }
}
