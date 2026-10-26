import Foundation
import DiMyMintClient
import DiMyPaymentTypes

public enum WalletCellError: Error, Sendable {
    case unsupportedAmount(UInt64)
    case insufficientBalance(required: UInt64, available: UInt64)
    case unableToCreateExactChange(UInt64)
    case issueMismatch
    case invalidCoinSignature(serial: String)
    case coinSerialCollision(serial: String)
    case missingVerificationKey(keyID: String)
    /// Mynten er signert av en annen utsteder enn denne lommeboka tilhører.
    case foreignMintKey(expected: String, found: String, serial: String)
    /// Mynten er signert i en nøkkelkohort som ikke lenger er gyldig.
    case retiredKeyEpoch(keyID: String, keyEpoch: UInt32?, serial: String)
    /// Bundlet inneholder mynt fra mer enn én utsteder og har derfor ingen.
    case mixedMintKeysInBundle
}

public struct PreparedIssueRequest: Sendable {
    public let issueRequest: IssueRequest
    fileprivate let plans: [PreparedCoinPlan]

    public init(issueRequest: IssueRequest, plans: [PreparedCoinPlan]) {
        self.issueRequest = issueRequest
        self.plans = plans
    }
}

public struct PreparedCoinPlan: Sendable {
    public let denomMinorUnits: UInt64
    public let serial: String
    public let mintKeyID: String

    public init(denomMinorUnits: UInt64, serial: String, mintKeyID: String) {
        self.denomMinorUnits = denomMinorUnits
        self.serial = serial
        self.mintKeyID = mintKeyID
    }
}

public protocol BlindSignatureAdapting: Sendable {
    func prepareIssueRequest(
        amountMinorUnits: UInt64,
        strategy: DenominationStrategy,
        mintKeyID: String,
        walletInstanceID: String?
    ) throws -> PreparedIssueRequest

    func finalizeIssuedCoins(
        signatures: [BlindSignature],
        preparedRequest: PreparedIssueRequest
    ) throws -> [Coin]
}

public struct DevelopmentBlindSignatureAdapter: BlindSignatureAdapting {
    public init() {}

    public func prepareIssueRequest(
        amountMinorUnits: UInt64,
        strategy: DenominationStrategy,
        mintKeyID: String,
        walletInstanceID: String?
    ) throws -> PreparedIssueRequest {
        let denoms = strategy.split(amountMinorUnits: amountMinorUnits)
        guard !denoms.isEmpty else {
            throw WalletCellError.unsupportedAmount(amountMinorUnits)
        }

        let plans = denoms.map { denom in
            PreparedCoinPlan(
                denomMinorUnits: denom,
                serial: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                mintKeyID: mintKeyID
            )
        }

        let blindedRequests = plans.map { plan in
            BlindedCoinRequest(
                denomMinorUnits: plan.denomMinorUnits,
                blindedMessage: "blind:\(plan.serial)",
                mintKeyID: plan.mintKeyID
            )
        }

        return PreparedIssueRequest(
            issueRequest: IssueRequest(requests: blindedRequests, walletInstanceID: walletInstanceID),
            plans: plans
        )
    }

    public func finalizeIssuedCoins(
        signatures: [BlindSignature],
        preparedRequest: PreparedIssueRequest
    ) throws -> [Coin] {
        guard signatures.count == preparedRequest.plans.count else {
            throw WalletCellError.issueMismatch
        }

        return zip(preparedRequest.plans, signatures).map { plan, signature in
            Coin(
                denomMinorUnits: plan.denomMinorUnits,
                serial: plan.serial,
                mintKeyID: plan.mintKeyID,
                keyEpoch: signature.keyEpoch,
                signature: signature.blindedSignature
            )
        }
    }
}

/// En lommebok tilhører nøyaktig én utsteder.
///
/// Invarianten er at `coins` bare inneholder mynt med denne lommebokas
/// `mintKeyID`. Den håndheves ved hver eneste inngang — utstedelse, innskudd
/// og tilbakerulling — slik at saldo og myntutvalg ikke *kan* se to utstedere.
/// Det er derfor segregeringen er strukturell her og ikke en regel noen må
/// huske: to potter kan ikke summeres når de ikke finnes i samme objekt.
public actor WalletCell {
    private let walletInstanceID: String?
    private let mintKeyID: String
    private let mintClient: any MintClient
    private let blindAdapter: any BlindSignatureAdapting
    private let verificationRegistry: MintPublicKeyRegistry
    private var coins: [Coin] = []

    public init(
        walletInstanceID: String? = nil,
        mintKeyID: String = "dev-mint-key-1",
        mintClient: any MintClient,
        blindAdapter: any BlindSignatureAdapting = DevelopmentBlindSignatureAdapter(),
        verificationRegistry: MintPublicKeyRegistry = .development
    ) {
        self.walletInstanceID = walletInstanceID
        self.mintKeyID = mintKeyID
        self.mintClient = mintClient
        self.blindAdapter = blindAdapter
        self.verificationRegistry = verificationRegistry
    }

    public func issue(
        amountMinorUnits: UInt64,
        strategy: DenominationStrategy = .oneTwoFive
    ) async throws -> [Coin] {
        guard verificationRegistry.publicKeyData(for: mintKeyID) != nil else {
            throw WalletCellError.missingVerificationKey(keyID: mintKeyID)
        }
        let prepared = try blindAdapter.prepareIssueRequest(
            amountMinorUnits: amountMinorUnits,
            strategy: strategy,
            mintKeyID: mintKeyID,
            walletInstanceID: walletInstanceID
        )
        let response = try await mintClient.issue(prepared.issueRequest)
        guard response.debitedMinorUnits == amountMinorUnits else {
            throw WalletCellError.issueMismatch
        }
        let issuedCoins = try blindAdapter.finalizeIssuedCoins(
            signatures: response.signatures,
            preparedRequest: prepared
        )
        guard issuedCoins.reduce(0, { $0 + $1.denomMinorUnits }) == amountMinorUnits else {
            throw WalletCellError.issueMismatch
        }
        try appendValidatedCoins(issuedCoins)
        return issuedCoins
    }

    public func spend(priceMinorUnits: UInt64, resourceID: String) throws -> SpendBundle {
        guard priceMinorUnits > 0 else {
            throw WalletCellError.unsupportedAmount(priceMinorUnits)
        }
        // Dekningen måles mot denne utstederens saldo alene. To utstederes
        // kvote skal aldri kunne dekke én handling sammen.
        let available = balanceMinorUnits()
        guard priceMinorUnits <= available else {
            throw WalletCellError.insufficientBalance(required: priceMinorUnits, available: available)
        }

        let selected = try selectCoins(totalMinorUnits: priceMinorUnits)

        // Skal være umulig gitt invarianten, men et blandet bundle er den ene
        // feilen hele denne modellen finnes for å hindre. Da sier vi det heller
        // høyt enn å sende det videre.
        guard selected.allSatisfy({ $0.mintKeyID == mintKeyID }) else {
            throw WalletCellError.mixedMintKeysInBundle
        }

        let selectedSerials = Set(selected.map(\.serial))
        coins.removeAll { selectedSerials.contains($0.serial) }

        return SpendBundle(
            coins: selected,
            requestID: UUID(),
            resourceID: resourceID,
            createdAt: Date()
        )
    }

    /// Tilbakerulling kan ikke smugle fremmed verdi inn i lommeboka.
    ///
    /// `rollback` er et innskudd, og arver derfor vaktene i `deposit`. Den
    /// eksplisitte kontrollen her finnes for at feilen skal navngi årsaken,
    /// og for at egenskapen skal ha et sted å bli testet.
    public func rollback(bundle: SpendBundle) throws {
        guard let bundleIssuer = bundle.uniformMintKeyID else {
            throw WalletCellError.mixedMintKeysInBundle
        }
        guard bundleIssuer == mintKeyID else {
            throw WalletCellError.foreignMintKey(
                expected: mintKeyID,
                found: bundleIssuer,
                serial: bundle.coins.first?.serial ?? ""
            )
        }
        try deposit(bundle.coins)
    }

    public func deposit(_ newCoins: [Coin]) throws {
        try appendValidatedCoins(newCoins)
    }

    /// Utstederen denne lommeboka tilhører.
    public func issuerMintKeyID() -> String {
        mintKeyID
    }

    /// Saldoen til denne lommebokas utsteder.
    ///
    /// Det finnes ingen sum på tvers av utstedere her, fordi det ikke finnes
    /// mynt fra andre utstedere i denne lommeboka.
    public func balanceMinorUnits() -> UInt64 {
        coins.reduce(0) { $0 + $1.denomMinorUnits }
    }

    public func coinInventory() -> [Coin] {
        coins.sorted { lhs, rhs in
            if lhs.denomMinorUnits == rhs.denomMinorUnits {
                return lhs.serial < rhs.serial
            }
            return lhs.denomMinorUnits > rhs.denomMinorUnits
        }
    }

    private func appendValidatedCoins(_ newCoins: [Coin]) throws {
        var coinsBySerial = Dictionary(uniqueKeysWithValues: coins.map { ($0.serial, $0) })
        var additions: [Coin] = []

        for coin in newCoins {
            // Utstederkontrollen står først, foran både duplikat- og
            // signaturkontrollen, slik at ingen vei inn i lommeboka kan gå
            // utenom den.
            guard coin.mintKeyID == mintKeyID else {
                throw WalletCellError.foreignMintKey(
                    expected: mintKeyID,
                    found: coin.mintKeyID,
                    serial: coin.serial
                )
            }
            guard verificationRegistry.acceptsKeyEpoch(coin.keyEpoch, for: coin.mintKeyID) else {
                throw WalletCellError.retiredKeyEpoch(
                    keyID: coin.mintKeyID,
                    keyEpoch: coin.keyEpoch,
                    serial: coin.serial
                )
            }
            if let existing = coinsBySerial[coin.serial] {
                guard existing == coin else {
                    throw WalletCellError.coinSerialCollision(serial: coin.serial)
                }
                continue
            }
            guard CoinSignatureVerifier.verify(coin: coin, using: verificationRegistry) else {
                throw WalletCellError.invalidCoinSignature(serial: coin.serial)
            }
            coinsBySerial[coin.serial] = coin
            additions.append(coin)
        }

        coins.append(contentsOf: additions)
    }

    private func selectCoins(totalMinorUnits: UInt64) throws -> [Coin] {
        var remaining = totalMinorUnits
        // Her lå sammenblandingen: utvalget sorterte alle mynter uansett
        // utsteder. Filteret er strengt tatt overflødig gitt invarianten, og
        // står her nettopp fordi dette er stedet feilen oppsto.
        let sortedCoins = coins
            .filter { $0.mintKeyID == mintKeyID }
            .sorted { $0.denomMinorUnits > $1.denomMinorUnits }
        var selected: [Coin] = []

        for coin in sortedCoins where remaining > 0 {
            guard coin.denomMinorUnits <= remaining else {
                continue
            }
            selected.append(coin)
            remaining -= coin.denomMinorUnits
        }

        guard remaining == 0 else {
            throw WalletCellError.unableToCreateExactChange(totalMinorUnits)
        }

        return selected
    }
}
