import XCTest
import DiMyPaymentTypes

final class PaymentTypesCryptoTests: XCTestCase {
    func testCoinSignatureRoundTripWithDevelopmentKey() throws {
        let seed = try XCTUnwrap(HexCodec.decode(DevelopmentMintKeyMaterial.ed25519PrivateSeedHex))
        let unsignedCoin = Coin(
            denomMinorUnits: 25,
            serial: "00112233445566778899aabbccddeeff",
            mintKeyID: DevelopmentMintKeyMaterial.keyID,
            signature: ""
        )

        let signature = try CoinSignatureSigner.signEd25519(
            coin: unsignedCoin,
            keyID: unsignedCoin.mintKeyID,
            privateKeySeed: seed
        )
        let signedCoin = Coin(
            denomMinorUnits: unsignedCoin.denomMinorUnits,
            serial: unsignedCoin.serial,
            mintKeyID: unsignedCoin.mintKeyID,
            signature: signature
        )

        XCTAssertTrue(CoinSignatureVerifier.verify(coin: signedCoin, using: .development))
    }

    func testCoinSignatureRejectsTamperedCoinData() throws {
        let seed = try XCTUnwrap(HexCodec.decode(DevelopmentMintKeyMaterial.ed25519PrivateSeedHex))
        let unsignedCoin = Coin(
            denomMinorUnits: 50,
            serial: "11112222333344445555666677778888",
            mintKeyID: DevelopmentMintKeyMaterial.keyID,
            keyEpoch: 9,
            signature: ""
        )

        let signature = try CoinSignatureSigner.signEd25519(
            coin: unsignedCoin,
            keyID: unsignedCoin.mintKeyID,
            privateKeySeed: seed
        )

        let tamperedCoin = Coin(
            denomMinorUnits: unsignedCoin.denomMinorUnits,
            serial: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            mintKeyID: unsignedCoin.mintKeyID,
            signature: signature
        )

        XCTAssertFalse(CoinSignatureVerifier.verify(coin: tamperedCoin, using: .development))
    }

    func testCoinSignatureRoundTripWithCOSEEnvelope() throws {
        let seed = try XCTUnwrap(HexCodec.decode(DevelopmentMintKeyMaterial.ed25519PrivateSeedHex))
        let unsignedCoin = Coin(
            denomMinorUnits: 13,
            serial: "feedfacefeedfacefeedfacefeedface",
            mintKeyID: DevelopmentMintKeyMaterial.keyID,
            keyEpoch: 3,
            signature: ""
        )

        let signature = try CoinSignatureSigner.signEd25519(
            coin: unsignedCoin,
            keyID: unsignedCoin.mintKeyID,
            privateKeySeed: seed,
            envelopeFormat: .coseSign1
        )
        XCTAssertTrue(signature.hasPrefix("cose1:"))

        let signedCoin = Coin(
            denomMinorUnits: unsignedCoin.denomMinorUnits,
            serial: unsignedCoin.serial,
            mintKeyID: unsignedCoin.mintKeyID,
            keyEpoch: unsignedCoin.keyEpoch,
            signature: signature
        )

        XCTAssertTrue(
            CoinSignatureVerifier.verify(
                coin: signedCoin,
                using: .development,
                acceptedFormats: [.coseSign1]
            )
        )
    }

    func testBundleHasherIgnoresCoinOrder() throws {
        let coinA = Coin(
            denomMinorUnits: 5,
            serial: "a",
            mintKeyID: "dev-mint-key-1",
            signature: "sig-a"
        )
        let coinB = Coin(
            denomMinorUnits: 7,
            serial: "b",
            mintKeyID: "dev-mint-key-1",
            signature: "sig-b"
        )

        let requestID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let createdAt = Date(timeIntervalSince1970: 1_709_000_000)

        let bundleOne = SpendBundle(
            coins: [coinA, coinB],
            requestID: requestID,
            resourceID: "cell://resource/demo",
            createdAt: createdAt
        )
        let bundleTwo = SpendBundle(
            coins: [coinB, coinA],
            requestID: requestID,
            resourceID: "cell://resource/demo",
            createdAt: createdAt
        )

        XCTAssertEqual(try BundleHasher.hash(bundle: bundleOne), try BundleHasher.hash(bundle: bundleTwo))
    }

    func testRuntimeRegistryUsesOnlyExplicitValidConfiguredKeys() throws {
        let customKeyID = "mint-prod-2026"
        let registry = MintPublicKeyRegistry.runtime(environment: [
            "DIMY_MINT_PUBLIC_KEYS_JSON": "{\"\(customKeyID)\":\"\(DevelopmentMintKeyMaterial.ed25519PublicKeyHex)\"}"
        ])
        let seed = try XCTUnwrap(HexCodec.decode(DevelopmentMintKeyMaterial.ed25519PrivateSeedHex))
        let unsigned = Coin(
            denomMinorUnits: 25,
            serial: "configured-runtime-key",
            mintKeyID: customKeyID,
            keyEpoch: 7,
            signature: ""
        )
        let signature = try CoinSignatureSigner.signEd25519(
            coin: unsigned,
            keyID: customKeyID,
            privateKeySeed: seed
        )
        let signed = Coin(
            denomMinorUnits: unsigned.denomMinorUnits,
            serial: unsigned.serial,
            mintKeyID: unsigned.mintKeyID,
            keyEpoch: unsigned.keyEpoch,
            signature: signature
        )

        XCTAssertTrue(CoinSignatureVerifier.verify(coin: signed, using: registry))
        XCTAssertNil(registry.publicKeyData(for: DevelopmentMintKeyMaterial.keyID))

        let invalid = MintPublicKeyRegistry.runtime(environment: [
            "DIMY_MINT_PUBLIC_KEYS_JSON": "{\"\(customKeyID)\":\"not-a-key\"}"
        ])
        XCTAssertNil(invalid.publicKeyData(for: customKeyID))
        XCTAssertNil(invalid.publicKeyData(for: DevelopmentMintKeyMaterial.keyID))

        let emptyConfigured = MintPublicKeyRegistry.runtime(environment: [
            "DIMY_MINT_PUBLIC_KEYS_JSON": "   "
        ])
        XCTAssertNil(emptyConfigured.publicKeyData(for: DevelopmentMintKeyMaterial.keyID))

        let absent = MintPublicKeyRegistry.runtime(environment: [:])
        XCTAssertNotNil(absent.publicKeyData(for: DevelopmentMintKeyMaterial.keyID))
    }
    func testRuntimeEpochPolicyRejectsRetiredAndMalformedConfiguration() throws {
        let keyID = DevelopmentMintKeyMaterial.keyID
        let registry = MintPublicKeyRegistry.runtime(environment: [
            "DIMY_MINT_KEY_EPOCHS_JSON": "{\"\(keyID)\":2}"
        ])
        XCTAssertEqual(registry.currentEpoch(for: keyID), 2)
        XCTAssertFalse(registry.acceptsKeyEpoch(1, for: keyID))
        XCTAssertFalse(registry.acceptsKeyEpoch(nil, for: keyID))
        XCTAssertTrue(registry.acceptsKeyEpoch(2, for: keyID))
        let seed = try XCTUnwrap(HexCodec.decode(DevelopmentMintKeyMaterial.ed25519PrivateSeedHex))
        let unsigned = Coin(denomMinorUnits: 25, serial: "retired-runtime", mintKeyID: keyID, keyEpoch: 1, signature: "")
        let signature = try CoinSignatureSigner.signEd25519(coin: unsigned, keyID: keyID, privateKeySeed: seed)
        let coin = Coin(denomMinorUnits: 25, serial: unsigned.serial, mintKeyID: keyID, keyEpoch: 1, signature: signature)
        XCTAssertTrue(CoinSignatureVerifier.verifySignatureOnly(coin: coin, using: registry))
        XCTAssertFalse(CoinSignatureVerifier.verify(coin: coin, using: registry))
        for malformed in ["", "{}", "[]", "{\"unknown-issuer\":2}", "{\"\(keyID)\":-1}"] {
            let invalid = MintPublicKeyRegistry.runtime(environment: ["DIMY_MINT_KEY_EPOCHS_JSON": malformed])
            XCTAssertTrue(invalid.keysByID.isEmpty, "Invalid policy must fail closed: \(malformed)")
        }
    }

}
