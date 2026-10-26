import Crypto
import Foundation
import DiMyMintClient
import DiMyPaymentTypes
import DiMyWalletCell

/// To utstedere, hver med sitt eget signeringsmateriale.
///
/// Det er hele poenget: to utstedere som deler nøkkel er ikke to utstedere.
/// Segregeringen hviler på at mynt fra A er kryptografisk skillbar fra mynt
/// fra B, og disse hjelperne finnes for å kunne bevise nettopp det.
enum IssuerFixture {
    static let issuerAKeyID = DevelopmentMintKeyMaterial.keyID
    static let issuerASeedHex = DevelopmentMintKeyMaterial.ed25519PrivateSeedHex

    static let issuerBKeyID = "test-mint-key-b"
    /// Vilkårlig, men fast, slik at testene er deterministiske.
    static let issuerBSeedHex =
        "4c8f1d2a9b3e6f70a15c48d9e2b7361f8a4d05c7e9138b26af5074c3d81e9f52"

    static func publicKeyData(forSeedHex seedHex: String) -> Data? {
        guard let seed = HexCodec.decode(seedHex),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
            return nil
        }
        return key.publicKey.rawRepresentation
    }

    /// Register som kjenner begge utstedere.
    static func twoIssuerRegistry(
        currentEpochByKeyID: [String: UInt32] = [:]
    ) -> MintPublicKeyRegistry {
        var keys: [String: Data] = [:]
        if let a = HexCodec.decode(DevelopmentMintKeyMaterial.ed25519PublicKeyHex) {
            keys[issuerAKeyID] = a
        }
        if let b = publicKeyData(forSeedHex: issuerBSeedHex) {
            keys[issuerBKeyID] = b
        }
        return MintPublicKeyRegistry(
            keysByID: keys,
            currentEpochByKeyID: currentEpochByKeyID
        )
    }

    static func mintA(
        registry: MintPublicKeyRegistry,
        keyEpoch: UInt32 = 1
    ) -> InMemoryMintClient {
        InMemoryMintClient(
            signingKeyID: issuerAKeyID,
            signingKeyEpoch: keyEpoch,
            signingSeedHex: issuerASeedHex,
            verificationRegistry: registry
        )
    }

    static func mintB(
        registry: MintPublicKeyRegistry,
        keyEpoch: UInt32 = 1
    ) -> InMemoryMintClient {
        InMemoryMintClient(
            signingKeyID: issuerBKeyID,
            signingKeyEpoch: keyEpoch,
            signingSeedHex: issuerBSeedHex,
            verificationRegistry: registry
        )
    }

    static func walletA(
        registry: MintPublicKeyRegistry,
        keyEpoch: UInt32 = 1
    ) -> WalletCell {
        WalletCell(
            mintKeyID: issuerAKeyID,
            mintClient: mintA(registry: registry, keyEpoch: keyEpoch),
            verificationRegistry: registry
        )
    }

    static func walletB(
        registry: MintPublicKeyRegistry,
        keyEpoch: UInt32 = 1
    ) -> WalletCell {
        WalletCell(
            mintKeyID: issuerBKeyID,
            mintClient: mintB(registry: registry, keyEpoch: keyEpoch),
            verificationRegistry: registry
        )
    }

    /// Mynter fra utsteder B, mintet i en lommebok som er bundet til B.
    static func coinsFromIssuerB(
        amountMinorUnits: UInt64,
        registry: MintPublicKeyRegistry,
        keyEpoch: UInt32 = 1
    ) async throws -> [Coin] {
        let wallet = walletB(registry: registry, keyEpoch: keyEpoch)
        return try await wallet.issue(
            amountMinorUnits: amountMinorUnits,
            strategy: .oneTwoFive
        )
    }
}
