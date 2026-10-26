import Foundation
import CellBase
import DiMyMintClient
import DiMyPaymentTypes
import DiMyWalletCell

private enum DiMyWalletExploreSchemas {
    static let string = ExploreContract.schema(type: "string")
    static let integer = ExploreContract.schema(type: "integer")
    static let null = ExploreContract.schema(type: "null")
    static let coin = ExploreContract.objectSchema(description: "One signed DiMy coin.")
    static let spendBundle = ExploreContract.objectSchema(description: "A DiMy spend bundle.")
    static let state = ExploreContract.objectSchema(
        properties: [
            "balanceMinorUnits": integer,
            "coinCount": integer,
            "pendingBundles": integer,
            "mintKeyID": string,
            "walletInstanceID": ExploreContract.oneOfSchema(options: [string, null]),
            "issuerScoped": ExploreContract.schema(type: "bool"),
            "currentKeyEpoch": ExploreContract.oneOfSchema(options: [integer, null]),
            "quarantinedCoinCount": integer,
            "quarantinedMintKeyIDs": ExploreContract.listSchema(item: string)
        ],
        requiredKeys: [
            "balanceMinorUnits", "coinCount", "pendingBundles", "mintKeyID",
            "walletInstanceID", "issuerScoped", "quarantinedCoinCount"
        ],
        description: "Balance and inventory for exactly one issuer. This wallet holds no other issuer's value."
    )
    static let result = ExploreContract.oneOfSchema(options: [ExploreContract.objectSchema(), string])
    static let stateResult = ExploreContract.oneOfSchema(options: [state, string])
    static let issueInput = ExploreContract.objectSchema(
        properties: ["amountMinorUnits": integer, "strategy": string],
        requiredKeys: ["amountMinorUnits"],
        description: "Issue non-transferable wallet value using an allowed denomination strategy."
    )
    static let spendInput = ExploreContract.objectSchema(
        properties: ["priceMinorUnits": integer, "resourceID": string, "mintKeyID": string],
        requiredKeys: ["priceMinorUnits", "resourceID"],
        description: "Reserve value from this wallet's issuer. An explicit mintKeyID must match this wallet."
    )
    static let rollbackInput = ExploreContract.oneOfSchema(
        options: [
            ExploreContract.objectSchema(
                properties: ["requestID": string, "bundle": spendBundle],
                description: "A request identifier or embedded spend bundle."
            ),
            spendBundle
        ]
    )
    static let depositInput = ExploreContract.listSchema(item: coin, description: "Coins to deposit into this wallet.")
}

/// En lommebokcelle tilhører nøyaktig én utsteder.
///
/// Bindingen skjer i typen, ikke i miljøet: en vert som trenger to utstedere
/// erklærer to subklasser og registrerer dem under hvert sitt cellenavn. Da er
/// «to potter kan ikke summeres» en egenskap ved objektgrafen, ikke en regel
/// noen må huske å håndheve.
///
///     final class DiMyTestWalletCell: DiMyWalletRuntimeCell {
///         override class var boundMintKeyID: String? { "dimy-test-mint-key" }
///     }
///
/// Uten binding faller cella tilbake på `DIMY_MINT_KEY_ID` fra miljøet, slik
/// den alltid har gjort.
open class DiMyWalletRuntimeCell: DiMyRuntimeBindingCell {
    /// Utstederen denne celletypen tilhører. `nil` betyr «les fra miljøet».
    open class var boundMintKeyID: String? { nil }

    static func resolvedMintKeyID() -> String {
        if let bound = boundMintKeyID { return bound }
        return ProcessInfo.processInfo.environment["DIMY_MINT_KEY_ID"] ?? "dev-mint-key-1"
    }

    enum CodingKeys: CodingKey {
        case generalCell
        case owner
        case storedCoins
        case cachedBundles
        case mintKeyID
        case walletInstanceID
        case persistenceSchemaVersion
        case quarantinedCoins
    }

    private struct IssueCommand: Codable {
        var amountMinorUnits: UInt64
        var strategy: DenominationStrategy?
    }

    private struct SpendCommand: Codable {
        var priceMinorUnits: UInt64
        var resourceID: String
        /// Valgfri, men er den satt må den stemme med lommebokas utsteder.
        /// Med én lommebok per utsteder er dette en påstand som kontrolleres,
        /// ikke et valg mellom potter.
        var mintKeyID: String?
    }

    private struct RollbackCommand: Codable {
        var requestID: UUID?
        var bundle: SpendBundle?
    }

    private let stateQueue = DispatchQueue(label: "DiMyWalletRuntimeCell.State")
    private var storedCoins: [Coin]
    private var cachedBundles: [String: SpendBundle]
    private let mintKeyID: String
    private let walletInstanceID: String?
    /// Mynt som er ekte, men ikke brukbar i denne lommeboka — feil utsteder
    /// eller pensjonert nøkkelkohort.
    ///
    /// De blir liggende, lesbare og rapportert, men aldri valgt. En mynt som
    /// forsvinner uten spor er verre enn en mynt som nektes.
    private var quarantinedCoins: [Coin]

    private let operationGate: DiMyAsyncOperationGate
    private var walletRuntime: WalletCell?

    private static let persistenceSchemaVersion = 3

    public required init(owner: Identity) async {
        self.storedCoins = []
        self.cachedBundles = [:]
        self.quarantinedCoins = []
        self.mintKeyID = Self.resolvedMintKeyID()
        self.walletInstanceID = ProcessInfo.processInfo.environment["DIMY_WALLET_INSTANCE_ID"]
        self.operationGate = DiMyAsyncOperationGate()
        await super.init(owner: owner)
        try? await ensureRuntimeReady()
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .persistenceSchemaVersion
        ) ?? 1
        guard schemaVersion >= 1, schemaVersion <= Self.persistenceSchemaVersion else {
            throw Swift.DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath + [CodingKeys.persistenceSchemaVersion],
                debugDescription: "Unsupported persisted wallet schema version \(schemaVersion)."
            ))
        }
        let decodedCoins = try container.decode([Coin].self, forKey: .storedCoins)
        let decodedBundles = try container.decode(
            [String: SpendBundle].self,
            forKey: .cachedBundles
        )
        let decodedQuarantine = schemaVersion >= 3
            ? try container.decode([Coin].self, forKey: .quarantinedCoins)
            : try container.decodeIfPresent([Coin].self, forKey: .quarantinedCoins) ?? []
        let persistedMintKeyID = try container.decode(String.self, forKey: .mintKeyID)

        // Er celletypen bundet til en utsteder, vinner bindingen over det som
        // ligger lagret. Et øyeblikksbilde skrevet før bindingen kan inneholde
        // mynt fra en annen utsteder; de skal ikke bli brukbare bare fordi de
        // lå der først.
        let effectiveMintKeyID = Self.boundMintKeyID ?? persistedMintKeyID

        try Self.validatePersistedWalletState(
            storedCoins: decodedCoins + decodedQuarantine,
            cachedBundles: decodedBundles,
            container: container
        )

        // Migrering fra skjema 2: et øyeblikksbilde kunne inneholde mynt fra
        // flere utstedere i samme pott - det er nettopp feilen. De grupperes
        // på den utstederen de faktisk bærer, ikke på en antakelse.
        let partitioned = Self.partitionByIssuer(
            coins: decodedCoins + decodedQuarantine,
            mintKeyID: effectiveMintKeyID
        )
        self.storedCoins = partitioned.usable
        self.quarantinedCoins = partitioned.quarantined
        self.cachedBundles = decodedBundles
        self.mintKeyID = effectiveMintKeyID
        self.walletInstanceID = try container.decodeIfPresent(String.self, forKey: .walletInstanceID)
        self.operationGate = DiMyAsyncOperationGate()
        self.walletRuntime = nil

        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        let snapshot = stateQueue.sync {
            (storedCoins: storedCoins, cachedBundles: cachedBundles, quarantinedCoins: quarantinedCoins)
        }
        try container.encode(snapshot.storedCoins, forKey: .storedCoins)
        try container.encode(snapshot.cachedBundles, forKey: .cachedBundles)
        try container.encode(snapshot.quarantinedCoins, forKey: .quarantinedCoins)
        try container.encode(mintKeyID, forKey: .mintKeyID)
        try container.encodeIfPresent(walletInstanceID, forKey: .walletInstanceID)
        try container.encode(Self.persistenceSchemaVersion, forKey: .persistenceSchemaVersion)
    }

    override func installRuntimeBindings(owner: Identity) async {
        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }

    private func setupPermissions(owner: Identity) async {
        ensureAgreementGrant("r---", for: "state")
        ensureAgreementGrant("rw--", for: "issue")
        ensureAgreementGrant("rw--", for: "spend")
        ensureAgreementGrant("rw--", for: "rollback")
        ensureAgreementGrant("rw--", for: "depositCoins")
    }

    private func setupKeys(owner: Identity) async {
        await registerGet(
            key: "state",
            owner: owner,
            returns: DiMyWalletExploreSchemas.state,
            permissions: ["r---"],
            description: .string("Read the wallet balance, coin inventory and pending spend count.")
        ) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "state", for: requester) else { return .string("denied") }
            return await self.stateValue()
        }

        await registerSet(
            key: "issue",
            owner: owner,
            input: DiMyWalletExploreSchemas.issueInput,
            returns: DiMyWalletExploreSchemas.result,
            permissions: ["rw--"],
            description: .string("Issue non-transferable wallet value for the authorized wallet owner.")
        ) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("rw--", at: "issue", for: requester) else { return .string("denied") }
            return await self.issue(payload: payload)
        }

        await registerSet(
            key: "spend",
            owner: owner,
            input: DiMyWalletExploreSchemas.spendInput,
            returns: ExploreContract.oneOfSchema(options: [DiMyWalletExploreSchemas.spendBundle, DiMyWalletExploreSchemas.string]),
            permissions: ["rw--"],
            description: .string("Reserve wallet value for one exact resource and return a spend bundle.")
        ) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("rw--", at: "spend", for: requester) else { return .string("denied") }
            return await self.spend(payload: payload)
        }

        await registerSet(
            key: "rollback",
            owner: owner,
            input: DiMyWalletExploreSchemas.rollbackInput,
            returns: DiMyWalletExploreSchemas.stateResult,
            permissions: ["rw--"],
            description: .string("Rollback one previously created spend bundle.")
        ) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("rw--", at: "rollback", for: requester) else { return .string("denied") }
            return await self.rollback(payload: payload)
        }

        await registerSet(
            key: "depositCoins",
            owner: owner,
            input: DiMyWalletExploreSchemas.depositInput,
            returns: DiMyWalletExploreSchemas.stateResult,
            permissions: ["rw--"],
            description: .string("Deposit an explicitly supplied list of signed coins.")
        ) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("rw--", at: "depositCoins", for: requester) else { return .string("denied") }

            guard let coins = ValueTypeCodableBridge.decode([Coin].self, from: payload) else {
                return .string("error: expected coin list payload")
            }

            return await self.withSerializedWalletOperation {
                let pendingSerials = self.stateQueue.sync {
                    Set(self.cachedBundles.values.flatMap { $0.coins.map(\.serial) })
                }
                guard coins.allSatisfy({ !pendingSerials.contains($0.serial) }) else {
                    return .string("error: deposited coin is already reserved in a pending spend bundle")
                }
                do {
                    let wallet = try await self.runtimeWalletLocked()
                    try await wallet.deposit(coins)
                    await self.syncFromRuntime(wallet)
                    return await self.stateValueLocked(wallet)
                } catch {
                    return .string("error: \(error)")
                }
            }
        }
    }

    private func stateValue() async -> ValueType {
        await withSerializedWalletOperation {
            do {
                let wallet = try await self.runtimeWalletLocked()
                return await self.stateValueLocked(wallet)
            } catch {
                return .string("error: \(error)")
            }
        }
    }

    private func stateValueLocked(_ wallet: WalletCell) async -> ValueType {
        let balance = await wallet.balanceMinorUnits()
        let inventory = await wallet.coinInventory()
        let snapshot = stateQueue.sync {
            (pendingBundles: cachedBundles.count, quarantined: quarantinedCoins)
        }
        let currentKeyEpoch = MintPublicKeyRegistry.runtime().currentEpoch(for: mintKeyID)

        return .object([
            // Saldoen tilhører nøyaktig én utsteder. Det finnes ingen sum på
            // tvers her, fordi denne lommeboka ikke holder andres verdi.
            "balanceMinorUnits": .integer(Int(clamping: balance)),
            "coinCount": .integer(inventory.count),
            "pendingBundles": .integer(snapshot.pendingBundles),
            "mintKeyID": .string(mintKeyID),
            "walletInstanceID": walletInstanceID.map(ValueType.string) ?? .null,
            "issuerScoped": .bool(true),
            "currentKeyEpoch": currentKeyEpoch.map { .integer(Int($0)) } ?? .null,
            "quarantinedCoinCount": .integer(snapshot.quarantined.count),
            "quarantinedMintKeyIDs": .list(
                Set(snapshot.quarantined.map(\.mintKeyID)).sorted().map(ValueType.string)
            ),
            "transferability": .string("none"),
            "cashOut": .bool(false)
        ])
    }

    private func issue(payload: ValueType) async -> ValueType {
        let command: IssueCommand?
        if case .null = payload {
            command = nil
        } else {
            command = ValueTypeCodableBridge.decode(IssueCommand.self, from: payload)
        }

        let amount = command?.amountMinorUnits ?? 0
        if amount == 0 {
            return .string("error: amountMinorUnits must be > 0")
        }

        let strategy = command?.strategy ?? .oneTwoFive
        return await withSerializedWalletOperation {
            do {
                let wallet = try await self.runtimeWalletLocked()
                let issued = try await wallet.issue(amountMinorUnits: amount, strategy: strategy)
                await self.syncFromRuntime(wallet)
                return .object([
                    "issuedCoins": ValueTypeCodableBridge.encode(issued),
                    "state": await self.stateValueLocked(wallet)
                ])
            } catch {
                return .string("error: \(error)")
            }
        }
    }

    private func spend(payload: ValueType) async -> ValueType {
        guard let command = ValueTypeCodableBridge.decode(SpendCommand.self, from: payload) else {
            return .string("error: expected payload {priceMinorUnits, resourceID}")
        }
        guard command.priceMinorUnits > 0 else {
            return .string("error: priceMinorUnits must be > 0")
        }
        guard !command.resourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .string("error: resourceID must not be empty")
        }
        if let requestedMintKeyID = command.mintKeyID,
           requestedMintKeyID != mintKeyID {
            return .string(
                "error: this wallet belongs to issuer '\(mintKeyID)', not '\(requestedMintKeyID)'"
            )
        }

        return await withSerializedWalletOperation {
            do {
                let wallet = try await self.runtimeWalletLocked()
                let bundle = try await wallet.spend(
                    priceMinorUnits: command.priceMinorUnits,
                    resourceID: command.resourceID
                )
                await self.syncFromRuntime(wallet, bundleChange: .add(bundle))
                return ValueTypeCodableBridge.encode(bundle)
            } catch {
                return .string("error: \(error)")
            }
        }
    }

    private func rollback(payload: ValueType) async -> ValueType {
        let command = ValueTypeCodableBridge.decode(RollbackCommand.self, from: payload)
        let decodedBundle = ValueTypeCodableBridge.decode(SpendBundle.self, from: payload)

        return await withSerializedWalletOperation {
            let requestedBundle: SpendBundle?
            let requestID: UUID?
            if let decodedBundle {
                requestedBundle = decodedBundle
                requestID = decodedBundle.requestID
            } else if let providedBundle = command?.bundle {
                requestedBundle = providedBundle
                requestID = providedBundle.requestID
            } else if let commandRequestID = command?.requestID {
                requestedBundle = nil
                requestID = commandRequestID
            } else {
                requestedBundle = nil
                requestID = nil
            }

            guard let requestID else {
                return .string("error: expected payload with requestID or bundle")
            }
            guard let cachedBundle = self.stateQueue.sync(execute: {
                self.cachedBundles[requestID.uuidString]
            }) else {
                return .string("error: spend bundle is not pending or was already rolled back")
            }
            if let requestedBundle,
               !self.matchesPendingBundle(requestedBundle, cachedBundle) {
                return .string("error: spend bundle does not match the pending wallet bundle")
            }

            do {
                let wallet = try await self.runtimeWalletLocked()
                try await wallet.rollback(bundle: cachedBundle)
                await self.syncFromRuntime(wallet, bundleChange: .remove(requestID.uuidString))
                return await self.stateValueLocked(wallet)
            } catch {
                return .string("error: \(error)")
            }
        }
    }

    private func matchesPendingBundle(_ requested: SpendBundle, _ cached: SpendBundle) -> Bool {
        requested.requestID == cached.requestID
            && requested.resourceID == cached.resourceID
            && requested.coins == cached.coins
            && Self.epochSeconds(requested.createdAt) == Self.epochSeconds(cached.createdAt)
    }

    /// `ValueTypeCodableBridge` uses JSONEncoder's ISO-8601 strategy, which
    /// carries whole-second precision. Compare the complete bundle at that
    /// exact wire precision so a returned bundle can be rolled back unchanged.
    private static func epochSeconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }

    private func runtimeWalletLocked() async throws -> WalletCell {
        if let runtime = walletRuntime {
            return runtime
        }

        let mintClient = await MintClientRegistry.shared.makeClient()
        let runtime = WalletCell(
            walletInstanceID: walletInstanceID,
            mintKeyID: mintKeyID,
            mintClient: mintClient,
            verificationRegistry: .runtime()
        )

        let persistedCoins = stateQueue.sync { storedCoins }
        if !persistedCoins.isEmpty {
            try await runtime.deposit(persistedCoins)
        }

        walletRuntime = runtime
        return runtime
    }

    private enum CachedBundleChange {
        case none
        case add(SpendBundle)
        case remove(String)
    }

    private func syncFromRuntime(
        _ runtime: WalletCell,
        bundleChange: CachedBundleChange = .none
    ) async {
        let inventory = await runtime.coinInventory()
        stateQueue.sync {
            storedCoins = inventory
            switch bundleChange {
            case .none:
                break
            case .add(let bundle):
                cachedBundles[bundle.requestID.uuidString] = bundle
            case .remove(let requestID):
                cachedBundles.removeValue(forKey: requestID)
            }
        }
    }

    private func withSerializedWalletOperation(
        _ operation: () async -> ValueType
    ) async -> ValueType {
        await operationGate.enter()
        let result = await operation()
        await operationGate.leave()
        return result
    }

    /// Deler lagrede mynter i brukbare og karantene.
    ///
    /// Brukbar krever både riktig utsteder og en gyldig nøkkelkohort. Alt
    /// annet beholdes, men kan aldri velges.
    static func partitionByIssuer(
        coins: [Coin],
        mintKeyID: String,
        registry: MintPublicKeyRegistry = .runtime()
    ) -> (usable: [Coin], quarantined: [Coin]) {
        var usable: [Coin] = []
        var quarantined: [Coin] = []
        var seenSerials: Set<String> = []
        for coin in coins {
            guard seenSerials.insert(coin.serial).inserted else { continue }
            if coin.mintKeyID == mintKeyID,
               registry.acceptsKeyEpoch(coin.keyEpoch, for: coin.mintKeyID) {
                usable.append(coin)
            } else {
                quarantined.append(coin)
            }
        }
        return (usable, quarantined)
    }

    private static func validatePersistedWalletState(
        storedCoins: [Coin],
        cachedBundles: [String: SpendBundle],
        container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        let verifierRegistry = MintPublicKeyRegistry.runtime()
        var persistedSerials: Set<String> = []

        func validateCoin(_ coin: Coin, key: CodingKeys) throws {
            // Bare signaturen kontrolleres her. En ekte, men utgått eller
            // fremmed mynt er policy og havner i karantene lenger nede; en
            // forfalsket mynt er korrupsjon og skal stoppe innlesingen.
            guard coin.denomMinorUnits > 0,
                  !coin.serial.isEmpty,
                  CoinSignatureVerifier.verifySignatureOnly(coin: coin, using: verifierRegistry) else {
                throw Swift.DecodingError.dataCorrupted(.init(
                    codingPath: container.codingPath + [key],
                    debugDescription: "Persisted wallet state contains an invalid signed coin."
                ))
            }
            guard persistedSerials.insert(coin.serial).inserted else {
                throw Swift.DecodingError.dataCorrupted(.init(
                    codingPath: container.codingPath + [key],
                    debugDescription: "Persisted wallet state reuses a coin serial across available or pending value."
                ))
            }
        }

        for coin in storedCoins {
            try validateCoin(coin, key: .storedCoins)
        }

        for (cacheKey, bundle) in cachedBundles {
            guard cacheKey == bundle.requestID.uuidString,
                  !bundle.resourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !bundle.coins.isEmpty else {
                throw Swift.DecodingError.dataCorrupted(.init(
                    codingPath: container.codingPath + [CodingKeys.cachedBundles],
                    debugDescription: "Persisted pending bundle has an inconsistent key, resource or empty coin set."
                ))
            }
            for coin in bundle.coins {
                try validateCoin(coin, key: .cachedBundles)
            }
        }
    }
}
