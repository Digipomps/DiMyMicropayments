import CellBase
import DiMyPaymentTypes
import Foundation
import XCTest
@testable import DiMyCellProtocolCells

final class PaymentAccountingProjectionCellTests: XCTestCase {
    func testPrivilegedIngestFeedsReadOnlyObserverKeysAndHonestCoverage() async throws {
        let vault = EphemeralIdentityVault()
        let previousVault = CellBase.defaultIdentityVault
        CellBase.defaultIdentityVault = vault
        defer { CellBase.defaultIdentityVault = previousVault }
        let owner = try await makeOwner(vault: vault)
        let cell = await PaymentAccountingProjectionCell(owner: owner)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let input = PaymentAccountingProjectionInput(
            windowStart: now.addingTimeInterval(-3_600),
            windowEnd: now,
            asOf: now,
            currency: "NOK",
            pspCapturedMinorUnits: 12_000,
            ledgerCreditedMinorUnits: 11_500,
            issuedMinorUnits: 8_000,
            redeemedMinorUnits: 3_000,
            outstandingMinorUnits: 5_000,
            sources: [
                PaymentAccountingSourceCoverage(
                    sourceID: "dimymint.reconciliation",
                    title: "DiMyMint reconciliation",
                    status: .current,
                    asOf: now,
                    detail: "Captured, credited, issued, redeemed and outstanding."
                ),
                PaymentAccountingSourceCoverage(
                    sourceID: "cellscaffold.audit",
                    title: "CellScaffold audit",
                    status: .stale,
                    asOf: now.addingTimeInterval(-7_200),
                    detail: "Counts and checksums are older than expected."
                )
            ],
            audit: PaymentAccountingAuditCoverage(
                topUpOrders: 3,
                prepaidIssues: 2,
                credentialsIssued: 4,
                credentialsConsumed: 1,
                usageEvents: 6,
                checksums: [
                    "topUpOrders": "topup-checksum",
                    "prepaidIssues": "prepaid-checksum",
                    "credentialsIssued": "issued-checksum",
                    "credentialsConsumed": "consumed-checksum",
                    "usageEvents": "usage-checksum"
                ]
            )
        )

        let ingestResult = try await cell.set(
            keypath: PaymentAccountingProjectionContract.Keys.ingest,
            value: encode(input),
            requester: owner
        )
        guard case let .object(ingested)? = ingestResult else {
            return XCTFail("Expected a projection object")
        }
        XCTAssertEqual(ingested["coverageStatus"], .string("unreconciled"))

        let captured = try await cell.get(
            keypath: PaymentAccountingProjectionContract.Keys.capturedLabel,
            requester: owner
        )
        guard case let .string(capturedLabel) = captured else {
            return XCTFail("Expected formatted captured label")
        }
        XCTAssertTrue(capturedLabel.contains("120"))
        XCTAssertTrue(capturedLabel.contains("NOK") || capturedLabel.contains("kr"))

        let stages = try await cell.get(
            keypath: PaymentAccountingProjectionContract.Keys.stages,
            requester: owner
        )
        guard case let .list(stageValues) = stages else {
            return XCTFail("Expected stage list")
        }
        XCTAssertEqual(stageValues.count, 5)

        let exceptions = try await cell.get(
            keypath: PaymentAccountingProjectionContract.Keys.exceptions,
            requester: owner
        )
        guard case let .list(exceptionValues) = exceptions else {
            return XCTFail("Expected exception list")
        }
        XCTAssertEqual(exceptionValues.count, 1)

        let auditRows = try await cell.get(
            keypath: PaymentAccountingProjectionContract.Keys.auditRows,
            requester: owner
        )
        guard case let .list(auditValues) = auditRows else {
            return XCTFail("Expected audit row list")
        }
        XCTAssertEqual(auditValues.count, 5)
        XCTAssertTrue(try auditRows.jsonString().contains("usage-checksum"))

        let coverage = try await cell.get(
            keypath: PaymentAccountingProjectionContract.Keys.coverageLabel,
            requester: owner
        )
        guard case let .string(coverageLabel) = coverage else {
            return XCTFail("Expected coverage label")
        }
        XCTAssertTrue(coverageLabel.contains("artist_payable"))
        XCTAssertTrue(coverageLabel.contains("provider_fees"))
    }

    func testConfigurationIsReadOnlyAndUsesSupportedPortableElements() throws {
        let configuration = PaymentAccountingDashboardConfigurationFactory.makeCellConfiguration()
        let data = try JSONEncoder().encode(configuration)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("Grid"))
        XCTAssertTrue(json.contains("List"))
        XCTAssertTrue(json.contains("Section"))
        XCTAssertTrue(json.contains("Tilbake til Co-Pilot og min enhet"))
        XCTAssertTrue(json.contains("Auditspor og checksums"))
        XCTAssertFalse(json.contains(PaymentAccountingProjectionContract.Keys.ingest))
        XCTAssertFalse(json.contains("refund"))
        XCTAssertFalse(json.contains("payout"))

        let decoded = try JSONDecoder().decode(CellConfiguration.self, from: data)
        XCTAssertEqual(decoded.name, "DiMy betalingskontroll")
        XCTAssertEqual(decoded.cellReferences?.first?.label, "projection")
        XCTAssertEqual(decoded.cellReferences?.first?.endpoint, PaymentAccountingProjectionContract.endpoint)
    }

    func testExploreAdvertisesExplicitReadContracts() async throws {
        let vault = EphemeralIdentityVault()
        let previousVault = CellBase.defaultIdentityVault
        CellBase.defaultIdentityVault = vault
        defer { CellBase.defaultIdentityVault = previousVault }
        let owner = try await makeOwner(vault: vault)
        let cell = await PaymentAccountingProjectionCell(owner: owner)

        let keys = try await cell.keys(requester: owner)
        XCTAssertTrue(keys.contains(PaymentAccountingProjectionContract.Keys.projection))
        XCTAssertTrue(keys.contains(PaymentAccountingProjectionContract.Keys.sources))
        XCTAssertTrue(keys.contains(PaymentAccountingProjectionContract.Keys.auditRows))
        XCTAssertTrue(keys.contains(PaymentAccountingProjectionContract.Keys.ingest))

        let contract = try await cell.typeForKey(
            key: PaymentAccountingProjectionContract.Keys.stages,
            requester: owner
        )
        let contractJSON = try contract.jsonString()
        XCTAssertTrue(contractJSON.contains("permissions"))
        XCTAssertTrue(contractJSON.contains("r---"))
        XCTAssertTrue(contractJSON.contains("returns"))
        XCTAssertFalse(contractJSON.contains("unknown"))
    }

    private func makeOwner(vault: EphemeralIdentityVault) async throws -> Identity {
        guard let owner = await vault.identity(
            for: "payment-accounting-projection-\(UUID().uuidString)",
            makeNewIfNotFound: true
        ) else {
            throw TestError.missingOwner
        }
        return owner
    }

    private func encode<T: Encodable>(_ value: T) throws -> ValueType {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ValueType.self, from: data)
    }

    private enum TestError: Error {
        case missingOwner
    }
}
