import XCTest
import CellBase
@testable import DiMyCellProtocolCells
import DiMyMintClient
import DiMyPaymentTypes

/// En lommebokcelle tilhører nøyaktig én utsteder, og bindingen ligger i typen.
final class IssuerBoundWalletCellTests: XCTestCase {

    private final class TestIssuerWalletCell: DiMyWalletRuntimeCell {
        override class var boundMintKeyID: String? { "bound-test-issuer" }
    }

    private final class OtherIssuerWalletCell: DiMyWalletRuntimeCell {
        override class var boundMintKeyID: String? { "bound-other-issuer" }
    }

    // MARK: - R8: bindingen ligger i typen, ikke i miljøet

    func testBoundIssuerOverridesEnvironment() {
        XCTAssertEqual(TestIssuerWalletCell.resolvedMintKeyID(), "bound-test-issuer")
        XCTAssertEqual(OtherIssuerWalletCell.resolvedMintKeyID(), "bound-other-issuer")
        XCTAssertNotEqual(
            TestIssuerWalletCell.resolvedMintKeyID(),
            OtherIssuerWalletCell.resolvedMintKeyID(),
            "To bundne celletyper skal aldri kunne ende på samme utsteder."
        )
    }

    func testUnboundCellStillFallsBackToEnvironmentDefault() {
        XCTAssertNil(
            DiMyWalletRuntimeCell.boundMintKeyID,
            "Den ubundne basetypen skal fortsatt lese utstederen fra miljøet."
        )
        XCTAssertFalse(DiMyWalletRuntimeCell.resolvedMintKeyID().isEmpty)
    }

    // MARK: - R9: migrering er fail-closed, og mister ingenting

    func testMigrationPartitionsCoinsByTheIssuerTheyActuallyCarry() {
        let ours = Coin(
            denomMinorUnits: 10,
            serial: "serial-ours",
            mintKeyID: "bound-test-issuer",
            keyEpoch: 1,
            signature: "ignored-by-partition"
        )
        let foreign = Coin(
            denomMinorUnits: 20,
            serial: "serial-foreign",
            mintKeyID: "bound-other-issuer",
            keyEpoch: 1,
            signature: "ignored-by-partition"
        )

        let partitioned = DiMyWalletRuntimeCell.partitionByIssuer(
            coins: [ours, foreign],
            mintKeyID: "bound-test-issuer",
            registry: MintPublicKeyRegistry(keysByID: [:])
        )

        XCTAssertEqual(partitioned.usable.map(\.serial), ["serial-ours"])
        XCTAssertEqual(
            partitioned.quarantined.map(\.serial),
            ["serial-foreign"],
            "Fremmed mynt skal bli liggende i karantene, ikke forsvinne."
        )
    }

    func testRetiredKeyEpochIsQuarantinedNotDiscarded() {
        let retired = Coin(
            denomMinorUnits: 10,
            serial: "serial-retired",
            mintKeyID: "bound-test-issuer",
            keyEpoch: 1,
            signature: "ignored-by-partition"
        )
        let current = Coin(
            denomMinorUnits: 10,
            serial: "serial-current",
            mintKeyID: "bound-test-issuer",
            keyEpoch: 2,
            signature: "ignored-by-partition"
        )

        let partitioned = DiMyWalletRuntimeCell.partitionByIssuer(
            coins: [retired, current],
            mintKeyID: "bound-test-issuer",
            registry: MintPublicKeyRegistry(
                keysByID: [:],
                currentEpochByKeyID: ["bound-test-issuer": 2]
            )
        )

        XCTAssertEqual(partitioned.usable.map(\.serial), ["serial-current"])
        XCTAssertEqual(partitioned.quarantined.map(\.serial), ["serial-retired"])
    }

    func testCoinWithoutKeyEpochIsTreatedAsOldestWhenAnEpochIsRequired() {
        let unstamped = Coin(
            denomMinorUnits: 10,
            serial: "serial-unstamped",
            mintKeyID: "bound-test-issuer",
            keyEpoch: nil,
            signature: "ignored-by-partition"
        )

        let enforced = DiMyWalletRuntimeCell.partitionByIssuer(
            coins: [unstamped],
            mintKeyID: "bound-test-issuer",
            registry: MintPublicKeyRegistry(
                keysByID: [:],
                currentEpochByKeyID: ["bound-test-issuer": 2]
            )
        )
        XCTAssertEqual(
            enforced.quarantined.map(\.serial),
            ["serial-unstamped"],
            "Uten kohort skal mynten regnes som eldste kohort når kohort kreves."
        )

        let unenforced = DiMyWalletRuntimeCell.partitionByIssuer(
            coins: [unstamped],
            mintKeyID: "bound-test-issuer",
            registry: MintPublicKeyRegistry(keysByID: [:])
        )
        XCTAssertEqual(
            unenforced.usable.map(\.serial),
            ["serial-unstamped"],
            "Er ingen kohort konfigurert, håndheves ikke kohort."
        )
    }

    func testPartitionDropsDuplicateSerialsWithoutLosingTheFirst() {
        let coin = Coin(
            denomMinorUnits: 10,
            serial: "serial-dup",
            mintKeyID: "bound-test-issuer",
            keyEpoch: 1,
            signature: "ignored-by-partition"
        )
        let partitioned = DiMyWalletRuntimeCell.partitionByIssuer(
            coins: [coin, coin],
            mintKeyID: "bound-test-issuer",
            registry: MintPublicKeyRegistry(keysByID: [:])
        )
        XCTAssertEqual(partitioned.usable.count, 1)
        XCTAssertTrue(partitioned.quarantined.isEmpty)
    }
    func testRuntimeMerchantIssuerPolicyFailsClosed() {
        XCTAssertEqual(DiMyAccessRuntimeCell.runtimeAcceptedMintKeyIDs(environment: ["VAPOR_ENV": "production"]), [])
        XCTAssertEqual(DiMyAccessRuntimeCell.runtimeAcceptedMintKeyIDs(environment: ["DIMY_MINT_KEY_ID": "issuer-A"]), ["issuer-A"])
        XCTAssertEqual(DiMyAccessRuntimeCell.runtimeAcceptedMintKeyIDs(environment: ["DIMY_ACCEPTED_MINT_KEY_IDS_JSON": "[\"issuer-A\",\"issuer-B\"]"]), ["issuer-A", "issuer-B"])
        for invalid in ["", "{}", "[]", "[\"\"]", "[\" issuer-A\"]"] {
            XCTAssertEqual(DiMyAccessRuntimeCell.runtimeAcceptedMintKeyIDs(environment: ["DIMY_ACCEPTED_MINT_KEY_IDS_JSON": invalid, "DIMY_MINT_KEY_ID": "issuer-A"]), [])
        }
    }

    func testSignedLegacyWalletMigrationPreservesQuarantineAndPendingAcrossRestarts() async throws {
        let oldEpochs = ProcessInfo.processInfo.environment["DIMY_MINT_KEY_EPOCHS_JSON"]
        let oldVault = CellBase.defaultIdentityVault
        let vault = EphemeralIdentityVault()
        CellBase.defaultIdentityVault = vault
        defer {
            CellBase.defaultIdentityVault = oldVault
            if let oldEpochs { setenv("DIMY_MINT_KEY_EPOCHS_JSON", oldEpochs, 1) }
            else { unsetenv("DIMY_MINT_KEY_EPOCHS_JSON") }
        }
        let identity = await vault.identity(for: "migration-test", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(identity)
        let original = await DiMyWalletRuntimeCell(owner: owner)
        let seed = try XCTUnwrap(HexCodec.decode(DevelopmentMintKeyMaterial.ed25519PrivateSeedHex))
        func signedCoin(_ serial: String, epoch: UInt32) throws -> Coin {
            let unsigned = Coin(denomMinorUnits: 5, serial: serial, mintKeyID: DevelopmentMintKeyMaterial.keyID, keyEpoch: epoch, signature: "")
            let signature = try CoinSignatureSigner.signEd25519(coin: unsigned, keyID: unsigned.mintKeyID, privateKeySeed: seed)
            return Coin(denomMinorUnits: 5, serial: serial, mintKeyID: unsigned.mintKeyID, keyEpoch: epoch, signature: signature)
        }
        let retired = try signedCoin("retired", epoch: 1)
        let current = try signedCoin("current", epoch: 2)
        let pending = SpendBundle(coins: [try signedCoin("pending", epoch: 1)], requestID: UUID(), resourceID: "cell:///migration", createdAt: Date())
        let encoder = JSONEncoder()
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        legacy["persistenceSchemaVersion"] = 2
        legacy.removeValue(forKey: "quarantinedCoins")
        legacy["storedCoins"] = try JSONSerialization.jsonObject(with: encoder.encode([retired, current]))
        legacy["cachedBundles"] = try JSONSerialization.jsonObject(with: encoder.encode([pending.requestID.uuidString: pending]))
        setenv("DIMY_MINT_KEY_EPOCHS_JSON", "{\"dev-mint-key-1\":2}", 1)
        var restored = try JSONDecoder().decode(DiMyWalletRuntimeCell.self, from: JSONSerialization.data(withJSONObject: legacy))
        for _ in 0..<2 {
            let data = try encoder.encode(restored)
            let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let usable = try JSONDecoder().decode([Coin].self, from: JSONSerialization.data(withJSONObject: snapshot["storedCoins"]!))
            let quarantined = try JSONDecoder().decode([Coin].self, from: JSONSerialization.data(withJSONObject: snapshot["quarantinedCoins"]!))
            let bundles = try JSONDecoder().decode([String: SpendBundle].self, from: JSONSerialization.data(withJSONObject: snapshot["cachedBundles"]!))
            XCTAssertEqual(usable, [current])
            XCTAssertEqual(quarantined, [retired])
            XCTAssertEqual(bundles[pending.requestID.uuidString], pending)
            XCTAssertEqual(snapshot["persistenceSchemaVersion"] as? Int, 3)
            var corrupt = snapshot
            corrupt.removeValue(forKey: "quarantinedCoins")
            XCTAssertThrowsError(try JSONDecoder().decode(DiMyWalletRuntimeCell.self, from: JSONSerialization.data(withJSONObject: corrupt)))
            corrupt["quarantinedCoins"] = NSNull()
            XCTAssertThrowsError(try JSONDecoder().decode(DiMyWalletRuntimeCell.self, from: JSONSerialization.data(withJSONObject: corrupt)))
            restored = try JSONDecoder().decode(DiMyWalletRuntimeCell.self, from: data)
        }
    }

}
