import Foundation
import DiMyMintClient
import DiMyPaymentTypes

public enum AccessCellError: Error, Sendable {
    case invalidBundle
    case invalidCoinSignature(serial: String)
    case invalidReceiptSignature
    case mismatchedReceiptRecipient
    case replayedBundle
    case replayedCoin(serial: String)
    case missingReceipt
    case mismatchedBundleHash
    case redemptionRejected(RedeemRejectionReason)
    /// Bundlet inneholder mynt fra mer enn én utsteder. Da står ingen utsteder
    /// bak hele beløpet, og det kan ikke løses inn.
    case mixedMintKeys
    /// Utstederen er ikke i listen denne merchanten godtar.
    case unacceptedMintKey(String)
}

public protocol CoinVerifying: Sendable {
    func verify(_ coin: Coin) -> Bool
    func verify(_ receipt: SpendReceipt) -> Bool
    func verifyForRedemption(_ receipt: SpendReceipt) -> Bool
}

public extension CoinVerifying {
    func verifyForRedemption(_ receipt: SpendReceipt) -> Bool { verify(receipt) }
    func verify(_ receipt: SpendReceipt) -> Bool {
        false
    }
}

public struct DevelopmentCoinVerifier: CoinVerifying {
    private let keyRegistry: MintPublicKeyRegistry

    public init(keyRegistry: MintPublicKeyRegistry = .development) {
        self.keyRegistry = keyRegistry
    }

    public func verify(_ coin: Coin) -> Bool {
        CoinSignatureVerifier.verify(coin: coin, using: keyRegistry)
    }

    public func verify(_ receipt: SpendReceipt) -> Bool {
        SpendReceiptSignatureVerifier.verify(receipt: receipt, using: keyRegistry)
    }

    public func verifyForRedemption(_ receipt: SpendReceipt) -> Bool {
        keyRegistry.acceptsKeyEpoch(receipt.keyEpoch, for: receipt.mintKeyID) && verify(receipt)
    }
}

public actor AccessCell {
    private let merchantID: String
    private let mintClient: any MintClient
    private let verifier: any CoinVerifying
    private var acceptedReceipts: [String: SpendReceipt] = [:]
    private var acceptedBundleHashes: Set<String> = []
    private var acceptedCoinSerials: Set<String> = []
    private var pendingBundleHashes: Set<String> = []
    private var pendingCoinSerials: Set<String> = []
    private let acceptedMintKeyIDs: Set<String>?

    /// - Parameter acceptedMintKeyIDs: Utstederne denne merchanten godtar.
    ///   `nil` betyr ukonfigurert og godtar enhver utsteder som ellers
    ///   verifiserer. I produksjon skal den settes eksplisitt — en åpen liste
    ///   er en beslutning, ikke en standard.
    public init(
        merchantID: String,
        mintClient: any MintClient,
        verifier: any CoinVerifying = DevelopmentCoinVerifier(),
        acceptedReceipts: [String: SpendReceipt] = [:],
        acceptedBundleHashes: Set<String> = [],
        acceptedCoinSerials: Set<String> = [],
        acceptedMintKeyIDs: Set<String>? = nil
    ) {
        self.merchantID = merchantID
        self.mintClient = mintClient
        self.verifier = verifier
        self.acceptedReceipts = acceptedReceipts.filter { bundleHash, receipt in
            bundleHash == receipt.bundleHash
                && receipt.merchantID == merchantID
                && verifier.verify(receipt)
        }
        self.acceptedBundleHashes = acceptedBundleHashes.union(self.acceptedReceipts.keys)
        self.acceptedCoinSerials = acceptedCoinSerials
        self.acceptedMintKeyIDs = acceptedMintKeyIDs
    }

    public func verifyAndRedeem(bundle: SpendBundle) async throws -> AccessGrant {
        guard !bundle.coins.isEmpty,
              !bundle.resourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AccessCellError.invalidBundle
        }
        // Et bundle må kunne navngi én utsteder. Kan det ikke det, står ingen
        // utsteder bak hele beløpet, og innløsningen ville gjort merchanten
        // til stedet der to utstederes verdi møtes.
        guard let bundleIssuer = bundle.uniformMintKeyID else {
            throw AccessCellError.mixedMintKeys
        }
        if let acceptedMintKeyIDs {
            guard acceptedMintKeyIDs.contains(bundleIssuer) else {
                throw AccessCellError.unacceptedMintKey(bundleIssuer)
            }
        }
        for coin in bundle.coins where !verifier.verify(coin) {
            throw AccessCellError.invalidCoinSignature(serial: coin.serial)
        }

        let bundleHash = try BundleHasher.hash(bundle: bundle)
        guard !acceptedBundleHashes.contains(bundleHash),
              !pendingBundleHashes.contains(bundleHash) else {
            throw AccessCellError.replayedBundle
        }

        var bundleSerials: Set<String> = []
        for coin in bundle.coins {
            guard bundleSerials.insert(coin.serial).inserted,
                  !acceptedCoinSerials.contains(coin.serial),
                  !pendingCoinSerials.contains(coin.serial) else {
                throw AccessCellError.replayedCoin(serial: coin.serial)
            }
        }

        pendingBundleHashes.insert(bundleHash)
        pendingCoinSerials.formUnion(bundleSerials)
        do {
            let request = RedeemRequest(bundle: bundle, bundleHash: bundleHash, merchantID: merchantID)
            let response = try await mintClient.redeem(request)

            guard response.accepted else {
                throw AccessCellError.redemptionRejected(response.rejectionReason ?? .unknown)
            }

            guard let receipt = response.receipt else {
                throw AccessCellError.missingReceipt
            }

            guard receipt.bundleHash == bundleHash else {
                throw AccessCellError.mismatchedBundleHash
            }

            guard receipt.mintKeyID == bundleIssuer,
                  receipt.merchantID == merchantID else {
                throw AccessCellError.mismatchedReceiptRecipient
            }

            guard verifier.verifyForRedemption(receipt) else {
                throw AccessCellError.invalidReceiptSignature
            }

            pendingBundleHashes.remove(bundleHash)
            pendingCoinSerials.subtract(bundleSerials)
            acceptedBundleHashes.insert(bundleHash)
            acceptedCoinSerials.formUnion(bundleSerials)
            acceptedReceipts[bundleHash] = receipt
            return AccessGrant(resourceID: bundle.resourceID, receiptHash: bundleHash, grantedAt: Date())
        } catch {
            pendingBundleHashes.remove(bundleHash)
            pendingCoinSerials.subtract(bundleSerials)
            throw error
        }
    }

    public func receipt(bundleHash: String) -> SpendReceipt? {
        acceptedReceipts[bundleHash]
    }
}
