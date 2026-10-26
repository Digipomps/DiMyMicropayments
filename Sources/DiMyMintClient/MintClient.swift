import Foundation
import DiMyPaymentTypes

public enum MintClientError: Error, Sendable {
    case invalidResponse
    case invalidIssueRequest
    case unsupportedMintKey(String)
    case signingFailed
    case notImplemented
}

public protocol MintIssuingClient: Sendable {
    func issue(_ request: IssueRequest) async throws -> IssueResponse
}

public protocol MintRedeemingClient: Sendable {
    func redeem(_ request: RedeemRequest) async throws -> RedeemResponse
}

public typealias MintClient = MintIssuingClient & MintRedeemingClient

public actor InMemoryMintClient: MintClient {
    private var spentSerials: Set<String> = []
    private let signingKeyID: String
    private let signingKeyEpoch: UInt32
    private let signingSeed: Data
    private let envelopeFormat: SignatureEnvelopeFormat
    private let verificationRegistry: MintPublicKeyRegistry

    /// - Parameter signingSeedHex: Explicit Ed25519 private seed for
    ///   `signingKeyID`. Omit it to use the bootstrap development seed, which
    ///   is only valid for `DevelopmentMintKeyMaterial.keyID`. A second mint —
    ///   a second issuer — needs its own seed, because two issuers that share
    ///   signing material are not two issuers.
    public init(
        signingKeyID: String = "dev-mint-key-1",
        signingKeyEpoch: UInt32 = 1,
        signingSeedHex: String? = nil,
        envelopeFormat: SignatureEnvelopeFormat = SignatureEnvelopeFeatureFlags.preferredFormat(),
        verificationRegistry: MintPublicKeyRegistry = .development
    ) {
        self.signingKeyID = signingKeyID
        self.signingKeyEpoch = signingKeyEpoch
        self.envelopeFormat = envelopeFormat
        self.verificationRegistry = verificationRegistry

        if let signingSeedHex {
            self.signingSeed = HexCodec.decode(signingSeedHex) ?? Data()
            return
        }
        guard signingKeyID == DevelopmentMintKeyMaterial.keyID,
              let signingSeed = HexCodec.decode(DevelopmentMintKeyMaterial.ed25519PrivateSeedHex)
        else {
            self.signingSeed = Data()
            return
        }
        self.signingSeed = signingSeed
    }

    public func issue(_ request: IssueRequest) async throws -> IssueResponse {
        guard !signingSeed.isEmpty else {
            throw MintClientError.unsupportedMintKey(signingKeyID)
        }

        let signatures = try request.requests.map { item in
            guard item.mintKeyID == signingKeyID else {
                throw MintClientError.unsupportedMintKey(item.mintKeyID)
            }

            guard let serial = Self.extractSerial(fromBlindMessage: item.blindedMessage) else {
                throw MintClientError.invalidIssueRequest
            }

            let unsignedCoin = Coin(
                denomMinorUnits: item.denomMinorUnits,
                serial: serial,
                mintKeyID: item.mintKeyID,
                keyEpoch: signingKeyEpoch,
                signature: ""
            )

            let signature = try CoinSignatureSigner.signEd25519(
                coin: unsignedCoin,
                keyID: item.mintKeyID,
                privateKeySeed: signingSeed,
                envelopeFormat: envelopeFormat
            )

            return BlindSignature(
                denomMinorUnits: item.denomMinorUnits,
                blindedSignature: signature,
                mintKeyID: item.mintKeyID,
                keyEpoch: signingKeyEpoch
            )
        }

        let debited = request.requests.reduce(0) { $0 + $1.denomMinorUnits }
        return IssueResponse(signatures: signatures, debitedMinorUnits: debited, issuedAt: Date())
    }

    public func redeem(_ request: RedeemRequest) async throws -> RedeemResponse {
        guard !signingSeed.isEmpty else {
            throw MintClientError.unsupportedMintKey(signingKeyID)
        }

        for coin in request.bundle.coins {
            if spentSerials.contains(coin.serial) {
                return .rejected(.doubleSpend)
            }
        }

        for coin in request.bundle.coins where !CoinSignatureVerifier.verify(
            coin: coin,
            using: verificationRegistry
        ) {
            return .rejected(.invalidCoinSignature)
        }

        for coin in request.bundle.coins {
            spentSerials.insert(coin.serial)
        }

        let unsignedReceipt = SpendReceipt(
            bundleHash: request.bundleHash,
            merchantCreditRef: UUID().uuidString,
            merchantID: request.merchantID,
            mintKeyID: signingKeyID,
            keyEpoch: signingKeyEpoch,
            issuedAt: Date(),
            signature: ""
        )

        let receiptSignature = try SpendReceiptSignatureSigner.signEd25519(
            receipt: unsignedReceipt,
            keyID: signingKeyID,
            privateKeySeed: signingSeed,
            envelopeFormat: envelopeFormat
        )

        let receipt = SpendReceipt(
            bundleHash: unsignedReceipt.bundleHash,
            merchantCreditRef: unsignedReceipt.merchantCreditRef,
            merchantID: unsignedReceipt.merchantID,
            mintKeyID: unsignedReceipt.mintKeyID,
            keyEpoch: unsignedReceipt.keyEpoch,
            issuedAt: unsignedReceipt.issuedAt,
            signature: receiptSignature
        )
        return .accepted(receipt)
    }

    private static func extractSerial(fromBlindMessage raw: String) -> String? {
        let prefix = "blind:"
        guard raw.hasPrefix(prefix) else {
            return nil
        }

        let serial = String(raw.dropFirst(prefix.count))
        guard !serial.isEmpty else {
            return nil
        }
        return serial
    }
}
