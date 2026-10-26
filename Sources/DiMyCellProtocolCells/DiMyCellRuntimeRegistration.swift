import Foundation
import CellBase

public enum DiMyCellRuntimeRegistration {
    public static func registerScaffoldCells(
        resolver: CellResolver,
        identityDomain: String = "Scaffold"
    ) async throws {
        try await registerDefaultCells(
            resolver: resolver,
            identityDomain: identityDomain,
            walletScope: .identityUnique,
            accessScope: .identityUnique,
            pricingScope: .scaffoldUnique,
            accountingProjectionScope: .scaffoldUnique,
            persistency: .persistant
        )
    }

    public static func registerBindingCells(
        resolver: CellResolver,
        identityDomain: String = "private"
    ) async throws {
        try await registerDefaultCells(
            resolver: resolver,
            identityDomain: identityDomain,
            walletScope: .template,
            accessScope: .template,
            pricingScope: .template,
            accountingProjectionScope: .template,
            persistency: .ephemeral
        )
    }

    public static func registerDefaultCells(
        resolver: CellResolver,
        identityDomain: String,
        walletScope: CellUsageScope,
        accessScope: CellUsageScope,
        pricingScope: CellUsageScope,
        accountingProjectionScope: CellUsageScope = .scaffoldUnique,
        persistency: Persistancy
    ) async throws {
        try await resolver.addCellResolve(
            name: "DiMyWallet",
            cellScope: walletScope,
            persistency: persistency,
            identityDomain: identityDomain,
            type: DiMyWalletRuntimeCell.self
        )

        try await resolver.addCellResolve(
            name: "DiMyAccess",
            cellScope: accessScope,
            persistency: persistency,
            identityDomain: identityDomain,
            type: DiMyAccessRuntimeCell.self
        )

        try await resolver.addCellResolve(
            name: "DiMyPricingPolicy",
            cellScope: pricingScope,
            persistency: persistency,
            identityDomain: identityDomain,
            type: DiMyPricingPolicyCell.self
        )

        try await resolver.addCellResolve(
            name: PaymentAccountingProjectionContract.cellName,
            cellScope: accountingProjectionScope,
            persistency: persistency,
            identityDomain: identityDomain,
            type: PaymentAccountingProjectionCell.self
        )
    }
}
