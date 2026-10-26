import Foundation
import CellBase
import DiMyAccessCell
import DiMyMintClient
import DiMyPaymentTypes

private enum DiMyAccessExploreSchemas {
    static let string = ExploreContract.schema(type: "string")
    static let integer = ExploreContract.schema(type: "integer")
    static let null = ExploreContract.schema(type: "null")
    static let spendBundle = ExploreContract.objectSchema(description: "A DiMy spend bundle.")
    static let receipt = ExploreContract.objectSchema(description: "A verified DiMy spend receipt.")
    static let state = ExploreContract.objectSchema(
        properties: ["merchantID": string, "receiptCount": integer],
        requiredKeys: ["merchantID", "receiptCount"],
        description: "Merchant binding and cached receipt count."
    )
    static let merchantInput = ExploreContract.oneOfSchema(options: [
        string,
        ExploreContract.objectSchema(properties: ["value": string], requiredKeys: ["value"])
    ])
    static let redeemInput = ExploreContract.oneOfSchema(options: [
        spendBundle,
        ExploreContract.objectSchema(properties: ["bundle": spendBundle], requiredKeys: ["bundle"])
    ])
    static let receiptInput = ExploreContract.oneOfSchema(options: [
        string,
        ExploreContract.objectSchema(properties: ["bundleHash": string], requiredKeys: ["bundleHash"])
    ])
    static let objectResult = ExploreContract.oneOfSchema(options: [ExploreContract.objectSchema(), string])
    static let receiptResult = ExploreContract.oneOfSchema(options: [receipt, null, string])
}

public final class DiMyAccessRuntimeCell:
    DiMyRuntimeBindingCell,
    MeddleOperationAuthorizationRequirementProviding
{
    enum CodingKeys: CodingKey {
        case generalCell
        case owner
        case merchantID
        case receiptCache
        case redeemedBundleHashes
        case redeemedCoinSerials
        case replayHistoryMigrationRequired
        case persistenceSchemaVersion
    }

    private struct ReceiptQuery: Codable {
        var bundleHash: String
    }

    private let stateQueue = DispatchQueue(label: "DiMyAccessRuntimeCell.State")
    private var receiptCache: [String: SpendReceipt]
    private var redeemedBundleHashes: Set<String>
    private var redeemedCoinSerials: Set<String>
    private var replayHistoryMigrationRequired: Bool
    private var merchantID: String

    private let operationGate: DiMyAsyncOperationGate
    private var accessRuntime: AccessCell?

    private static let persistenceSchemaVersion = 2

    public required init(owner: Identity) async {
        self.receiptCache = [:]
        self.redeemedBundleHashes = []
        self.redeemedCoinSerials = []
        self.replayHistoryMigrationRequired = false
        self.merchantID = ProcessInfo.processInfo.environment["DIMY_MERCHANT_ID"] ?? "merchant.default"
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
        guard schemaVersion == 1 || schemaVersion == Self.persistenceSchemaVersion else {
            throw Swift.DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath + [CodingKeys.persistenceSchemaVersion],
                debugDescription: "Unsupported persisted access schema version \(schemaVersion)."
            ))
        }
        let decodedMerchantID = try container.decode(
            String.self,
            forKey: .merchantID
        )
        let decodedReceipts = try container.decode(
            [String: SpendReceipt].self,
            forKey: .receiptCache
        )
        let decodedBundleHashes: Set<String>
        let decodedCoinSerials: Set<String>
        let decodedMigrationRequired: Bool
        if schemaVersion == 1 {
            decodedBundleHashes = Set(decodedReceipts.keys)
            decodedCoinSerials = []
            decodedMigrationRequired = !decodedReceipts.isEmpty
        } else {
            decodedBundleHashes = try container.decode(
                Set<String>.self,
                forKey: .redeemedBundleHashes
            )
            decodedCoinSerials = try container.decode(
                Set<String>.self,
                forKey: .redeemedCoinSerials
            )
            decodedMigrationRequired = try container.decode(
                Bool.self,
                forKey: .replayHistoryMigrationRequired
            )
        }
        let migrationRequired = decodedMigrationRequired
            || (!decodedReceipts.isEmpty && decodedCoinSerials.isEmpty)
        let verifier = DevelopmentCoinVerifier(keyRegistry: .runtime())
        for (bundleHash, receipt) in decodedReceipts {
            guard bundleHash == receipt.bundleHash,
                  verifier.verify(receipt) else {
                throw Swift.DecodingError.dataCorrupted(.init(
                    codingPath: container.codingPath + [CodingKeys.receiptCache],
                    debugDescription: "Persisted receipt cache contains an invalid receipt or bundle-hash key."
                ))
            }
        }
        let replayHashes = decodedBundleHashes.union(decodedReceipts.keys)
        guard replayHashes.allSatisfy(Self.isCanonicalBundleHash) else {
            throw Swift.DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath + [CodingKeys.redeemedBundleHashes],
                debugDescription: "Persisted replay history contains a non-canonical bundle hash."
            ))
        }
        guard decodedCoinSerials.allSatisfy({ !$0.isEmpty }) else {
            throw Swift.DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath + [CodingKeys.redeemedCoinSerials],
                debugDescription: "Persisted coin replay history contains an empty serial."
            ))
        }
        self.receiptCache = decodedReceipts
        self.redeemedBundleHashes = replayHashes
        self.redeemedCoinSerials = decodedCoinSerials
        self.replayHistoryMigrationRequired = migrationRequired
        self.merchantID = decodedMerchantID
        self.operationGate = DiMyAsyncOperationGate()
        self.accessRuntime = nil

        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        let snapshot = stateQueue.sync {
            (
                receiptCache: receiptCache,
                redeemedBundleHashes: redeemedBundleHashes,
                redeemedCoinSerials: redeemedCoinSerials,
                replayHistoryMigrationRequired: replayHistoryMigrationRequired,
                merchantID: merchantID
            )
        }
        try container.encode(snapshot.receiptCache, forKey: .receiptCache)
        try container.encode(snapshot.redeemedBundleHashes, forKey: .redeemedBundleHashes)
        try container.encode(snapshot.redeemedCoinSerials, forKey: .redeemedCoinSerials)
        try container.encode(
            snapshot.replayHistoryMigrationRequired,
            forKey: .replayHistoryMigrationRequired
        )
        try container.encode(snapshot.merchantID, forKey: .merchantID)
        try container.encode(Self.persistenceSchemaVersion, forKey: .persistenceSchemaVersion)
    }

    public func meddleAuthorizationRequirement(
        for method: ExploreContractMethod,
        keypath: String
    ) async throws -> String? {
        method == .set && keypath == "receipt" ? "r---" : nil
    }

    override func installRuntimeBindings(owner: Identity) async {
        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }

    private func setupPermissions(owner: Identity) async {
        ensureAgreementGrant("r---", for: "state")
        ensureAgreementGrant("r---", for: "merchantID")
        ensureAgreementGrant("rw--", for: "merchantID")
        ensureAgreementGrant("rw--", for: "verifyAndRedeem")
        ensureAgreementGrant("r---", for: "receipt")
    }

    private func setupKeys(owner: Identity) async {
        await registerGet(
            key: "state",
            owner: owner,
            returns: DiMyAccessExploreSchemas.state,
            permissions: ["r---"],
            description: .string("Read the merchant binding and verified receipt count.")
        ) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "state", for: requester) else { return .string("denied") }
            return self.stateValue()
        }

        await registerGet(
            key: "merchantID",
            owner: owner,
            returns: DiMyAccessExploreSchemas.string,
            permissions: ["r---"],
            description: .string("Read the merchant identifier bound to this access cell.")
        ) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "merchantID", for: requester) else { return .string("denied") }
            return .string(self.stateQueue.sync { self.merchantID })
        }

        await registerSet(
            key: "merchantID",
            owner: owner,
            input: DiMyAccessExploreSchemas.merchantInput,
            returns: DiMyAccessExploreSchemas.string,
            permissions: ["rw--"],
            description: .string("Replace the merchant identifier for subsequent redemptions.")
        ) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("rw--", at: "merchantID", for: requester) else { return .string("denied") }
            guard let value = ValueTypeCodableBridge.asString(payload["value"] ?? payload) else {
                return .string("error: expected merchant ID string")
            }

            return await self.setMerchantID(value)
        }

        await registerSet(
            key: "verifyAndRedeem",
            owner: owner,
            input: DiMyAccessExploreSchemas.redeemInput,
            returns: DiMyAccessExploreSchemas.objectResult,
            permissions: ["rw--"],
            description: .string("Verify and redeem one spend bundle for the configured merchant.")
        ) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("rw--", at: "verifyAndRedeem", for: requester) else { return .string("denied") }
            return await self.verifyAndRedeem(payload: payload)
        }

        await registerSet(
            key: "receipt",
            owner: owner,
            input: DiMyAccessExploreSchemas.receiptInput,
            returns: DiMyAccessExploreSchemas.receiptResult,
            permissions: ["r---"],
            description: .string("Side-effect-free parameterized read of a cached receipt; SET carries the lookup query.")
        ) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "receipt", for: requester) else { return .string("denied") }
            return self.receipt(payload: payload)
        }
    }

    private func stateValue() -> ValueType {
        let snapshot = stateQueue.sync {
            (merchantID: merchantID, count: receiptCache.count)
        }
        return .object([
            "merchantID": .string(snapshot.merchantID),
            "receiptCount": .integer(snapshot.count)
        ])
    }

    private func verifyAndRedeem(payload: ValueType) async -> ValueType {
        let bundle: SpendBundle?
        if let fromObject = payload["bundle"], case .null = fromObject {
            bundle = nil
        } else if let nested = payload["bundle"] {
            bundle = ValueTypeCodableBridge.decode(SpendBundle.self, from: nested)
        } else {
            bundle = ValueTypeCodableBridge.decode(SpendBundle.self, from: payload)
        }

        guard let bundle else {
            return .string("error: expected SpendBundle payload")
        }
        guard !stateQueue.sync(execute: { replayHistoryMigrationRequired }) else {
            return .string("error: persisted replay history requires migration; redemption is locked")
        }

        return await withSerializedAccessOperation {
            let runtime = await self.runtimeAccessCellLocked()
            do {
                let grant = try await runtime.verifyAndRedeem(bundle: bundle)
                let receiptHash = grant.receiptHash
                if let receipt = await runtime.receipt(bundleHash: receiptHash) {
                    self.stateQueue.sync {
                        self.receiptCache[receiptHash] = receipt
                        self.redeemedBundleHashes.insert(receiptHash)
                        self.redeemedCoinSerials.formUnion(bundle.coins.map(\.serial))
                    }
                }
                return .object([
                    "grant": ValueTypeCodableBridge.encode(grant),
                    "receipt": self.stateQueue.sync {
                        ValueTypeCodableBridge.encode(self.receiptCache[receiptHash])
                    }
                ])
            } catch {
                return .string("error: \(error)")
            }
        }
    }

    private func receipt(payload: ValueType) -> ValueType {
        let query = ValueTypeCodableBridge.decode(ReceiptQuery.self, from: payload)
        let bundleHash = query?.bundleHash ?? ValueTypeCodableBridge.asString(payload)
        guard let bundleHash else {
            return .string("error: expected payload {bundleHash}")
        }

        let cached = stateQueue.sync { receiptCache[bundleHash] }
        if let cached {
            return ValueTypeCodableBridge.encode(cached)
        }
        return .null
    }

    private func setMerchantID(_ value: String) async -> ValueType {
        await withSerializedAccessOperation {
            self.stateQueue.sync {
                self.merchantID = value
            }
            self.accessRuntime = nil
            return .string(value)
        }
    }

    private func runtimeAccessCellLocked() async -> AccessCell {
        if let runtime = accessRuntime {
            return runtime
        }

        let client = await MintClientRegistry.shared.makeClient()
        let snapshot = stateQueue.sync {
            (
                merchantID: merchantID,
                acceptedReceipts: receiptCache,
                acceptedBundleHashes: redeemedBundleHashes,
                acceptedCoinSerials: redeemedCoinSerials
            )
        }
        let runtime = AccessCell(
            merchantID: snapshot.merchantID,
            mintClient: client,
            verifier: DevelopmentCoinVerifier(keyRegistry: .runtime()),
            acceptedReceipts: snapshot.acceptedReceipts,
            acceptedBundleHashes: snapshot.acceptedBundleHashes,
            acceptedCoinSerials: snapshot.acceptedCoinSerials,
            acceptedMintKeyIDs: Self.runtimeAcceptedMintKeyIDs()
        )
        accessRuntime = runtime
        return runtime
    }

    /// Bind the runtime merchant to explicit issuer policy. An invalid or
    /// absent production policy accepts no issuer, never all trusted keys.
    static func runtimeAcceptedMintKeyIDs(environment: [String: String] = ProcessInfo.processInfo.environment) -> Set<String> {
        if let raw = environment["DIMY_ACCEPTED_MINT_KEY_IDS_JSON"] {
            guard let data = raw.data(using: .utf8),
                  let ids = try? JSONDecoder().decode([String].self, from: data),
                  !ids.isEmpty,
                  ids.allSatisfy({ !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }) else {
                return []
            }
            return Set(ids)
        }
        if let id = environment["DIMY_MINT_KEY_ID"] {
            let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? [] : [normalized]
        }
        let production = ["production", "staging"].contains(environment["VAPOR_ENV"]?.lowercased() ?? "")
        return production ? [] : [DevelopmentMintKeyMaterial.keyID]
    }

    private func withSerializedAccessOperation(
        _ operation: () async -> ValueType
    ) async -> ValueType {
        await operationGate.enter()
        let result = await operation()
        await operationGate.leave()
        return result
    }

    private static func isCanonicalBundleHash(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }
}
