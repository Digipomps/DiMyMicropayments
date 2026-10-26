import Foundation
import CellBase

private enum DiMyPricingExploreSchemas {
    static let string = ExploreContract.schema(type: "string")
    static let integer = ExploreContract.schema(type: "integer")
    static let bool = ExploreContract.schema(type: "bool")
    static let null = ExploreContract.schema(type: "null")
    static let price = ExploreContract.objectSchema(
        properties: ["resourceID": string, "priceMinorUnits": integer],
        requiredKeys: ["resourceID", "priceMinorUnits"]
    )
    static let state = ExploreContract.objectSchema(
        properties: ["prices": ExploreContract.listSchema(item: price), "count": integer],
        requiredKeys: ["prices", "count"],
        description: "Exact prices currently configured by resource."
    )
    static let quote = ExploreContract.objectSchema(
        properties: [
            "resourceID": string,
            "priceMinorUnits": ExploreContract.oneOfSchema(options: [integer, null]),
            "hasCustomPrice": bool
        ],
        requiredKeys: ["resourceID", "priceMinorUnits", "hasCustomPrice"]
    )
    static let setPriceInput = ExploreContract.objectSchema(
        properties: ["resourceID": string, "priceMinorUnits": integer],
        requiredKeys: ["resourceID", "priceMinorUnits"]
    )
    static let removePriceInput = ExploreContract.objectSchema(
        properties: ["resourceID": string],
        requiredKeys: ["resourceID"]
    )
    static let quoteInput = ExploreContract.objectSchema(
        properties: ["resourceID": string, "defaultPriceMinorUnits": integer],
        requiredKeys: ["resourceID"]
    )
    static let stateResult = ExploreContract.oneOfSchema(options: [state, string])
    static let quoteResult = ExploreContract.oneOfSchema(options: [quote, string])
}

public final class DiMyPricingPolicyCell:
    DiMyRuntimeBindingCell,
    MeddleOperationAuthorizationRequirementProviding
{
    enum CodingKeys: CodingKey {
        case generalCell
        case owner
        case pricesByResource
        case persistenceSchemaVersion
    }

    private struct SetPriceCommand: Codable {
        var resourceID: String
        var priceMinorUnits: UInt64
    }

    private struct RemovePriceCommand: Codable {
        var resourceID: String
    }

    private struct QuoteCommand: Codable {
        var resourceID: String
        var defaultPriceMinorUnits: UInt64?
    }

    private let stateQueue = DispatchQueue(label: "DiMyPricingPolicyCell.State")
    private var pricesByResource: [String: UInt64]
    private static let persistenceSchemaVersion = 2

    public required init(owner: Identity) async {
        self.pricesByResource = [:]
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
                debugDescription: "Unsupported persisted pricing schema version \(schemaVersion)."
            ))
        }
        self.pricesByResource = try container.decode(
            [String: UInt64].self,
            forKey: .pricesByResource
        )

        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        let snapshot = stateQueue.sync { pricesByResource }
        try container.encode(snapshot, forKey: .pricesByResource)
        try container.encode(Self.persistenceSchemaVersion, forKey: .persistenceSchemaVersion)
    }

    public func meddleAuthorizationRequirement(
        for method: ExploreContractMethod,
        keypath: String
    ) async throws -> String? {
        method == .set && keypath == "quote" ? "r---" : nil
    }

    override func installRuntimeBindings(owner: Identity) async {
        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }

    private func setupPermissions(owner: Identity) async {
        ensureAgreementGrant("r---", for: "state")
        ensureAgreementGrant("rw--", for: "setPrice")
        ensureAgreementGrant("rw--", for: "removePrice")
        ensureAgreementGrant("r---", for: "quote")
    }

    private func setupKeys(owner: Identity) async {
        await registerGet(
            key: "state",
            owner: owner,
            returns: DiMyPricingExploreSchemas.state,
            permissions: ["r---"],
            description: .string("Read all exact resource prices.")
        ) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "state", for: requester) else { return .string("denied") }
            return self.stateValue()
        }

        await registerSet(
            key: "setPrice",
            owner: owner,
            input: DiMyPricingExploreSchemas.setPriceInput,
            returns: DiMyPricingExploreSchemas.quoteResult,
            permissions: ["rw--"],
            description: .string("Set the exact minor-unit price for one resource.")
        ) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("rw--", at: "setPrice", for: requester) else { return .string("denied") }
            guard let command = ValueTypeCodableBridge.decode(SetPriceCommand.self, from: payload) else {
                return .string("error: expected payload {resourceID,priceMinorUnits}")
            }

            let snapshot = self.stateQueue.sync {
                self.pricesByResource[command.resourceID] = command.priceMinorUnits
                return (resolvedPrice: command.priceMinorUnits, hasCustomPrice: true)
            }
            return self.quoteValue(resourceID: command.resourceID, snapshot: snapshot)
        }

        await registerSet(
            key: "removePrice",
            owner: owner,
            input: DiMyPricingExploreSchemas.removePriceInput,
            returns: DiMyPricingExploreSchemas.stateResult,
            permissions: ["rw--"],
            description: .string("Remove the custom price for one resource.")
        ) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("rw--", at: "removePrice", for: requester) else { return .string("denied") }
            guard let command = ValueTypeCodableBridge.decode(RemovePriceCommand.self, from: payload) else {
                return .string("error: expected payload {resourceID}")
            }

            return self.stateQueue.sync {
                self.pricesByResource.removeValue(forKey: command.resourceID)
                return self.stateValue(from: self.pricesByResource)
            }
        }

        await registerSet(
            key: "quote",
            owner: owner,
            input: DiMyPricingExploreSchemas.quoteInput,
            returns: DiMyPricingExploreSchemas.quoteResult,
            permissions: ["r---"],
            description: .string("Side-effect-free parameterized price read; SET carries the quote query.")
        ) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "quote", for: requester) else { return .string("denied") }
            guard let command = ValueTypeCodableBridge.decode(QuoteCommand.self, from: payload) else {
                return .string("error: expected payload {resourceID,defaultPriceMinorUnits?}")
            }

            return self.quoteValue(resourceID: command.resourceID, defaultPriceMinorUnits: command.defaultPriceMinorUnits)
        }
    }

    private func stateValue() -> ValueType {
        let prices = stateQueue.sync { pricesByResource }
        return stateValue(from: prices)
    }

    private func stateValue(from prices: [String: UInt64]) -> ValueType {
        let values: [ValueType] = prices.keys.sorted().map { resourceID in
            .object([
                "resourceID": .string(resourceID),
                "priceMinorUnits": .integer(Int(clamping: prices[resourceID] ?? 0))
            ])
        }
        return .object([
            "prices": .list(values),
            "count": .integer(values.count)
        ])
    }

    private func quoteValue(resourceID: String, defaultPriceMinorUnits: UInt64?) -> ValueType {
        let snapshot = stateQueue.sync {
            (
                resolvedPrice: pricesByResource[resourceID] ?? defaultPriceMinorUnits,
                hasCustomPrice: pricesByResource[resourceID] != nil
            )
        }
        return quoteValue(resourceID: resourceID, snapshot: snapshot)
    }

    private func quoteValue(
        resourceID: String,
        snapshot: (resolvedPrice: UInt64?, hasCustomPrice: Bool)
    ) -> ValueType {
        return .object([
            "resourceID": .string(resourceID),
            "priceMinorUnits": snapshot.resolvedPrice.map { .integer(Int(clamping: $0)) } ?? .null,
            "hasCustomPrice": .bool(snapshot.hasCustomPrice)
        ])
    }
}
