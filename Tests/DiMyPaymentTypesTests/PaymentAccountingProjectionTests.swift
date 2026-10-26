import Foundation
import XCTest
@testable import DiMyPaymentTypes

final class PaymentAccountingProjectionTests: XCTestCase {
    func testBuilderProducesReconciledReadOnlySnapshotWithExplicitCoverageGaps() throws {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let end = start.addingTimeInterval(86_400)
        let projection = try PaymentAccountingProjectionBuilder.build(
            PaymentAccountingProjectionInput(
                windowStart: start,
                windowEnd: end,
                asOf: end,
                currency: "nok",
                pspCapturedMinorUnits: 10_000,
                ledgerCreditedMinorUnits: 10_000,
                issuedMinorUnits: 8_000,
                redeemedMinorUnits: 3_000,
                outstandingMinorUnits: 5_000,
                sources: [
                    PaymentAccountingSourceCoverage(
                        sourceID: "dimymint.reconciliation",
                        title: "DiMyMint reconciliation",
                        status: .current,
                        asOf: end,
                        detail: "Captured, credited, issued, redeemed and outstanding."
                    ),
                    PaymentAccountingSourceCoverage(
                        sourceID: "cellscaffold.audit",
                        title: "CellScaffold audit",
                        status: .current,
                        asOf: end,
                        detail: "Counts and checksums."
                    )
                ],
                audit: PaymentAccountingAuditCoverage(
                    topUpOrders: 2,
                    prepaidIssues: 2,
                    credentialsIssued: 4,
                    credentialsConsumed: 3,
                    usageEvents: 3,
                    checksums: ["usageEvents": "abc123"]
                )
            )
        )

        XCTAssertEqual(projection.schema, "dimy.payment-accounting-projection.v0")
        XCTAssertEqual(projection.currency, "NOK")
        XCTAssertEqual(projection.coverageStatus, .current)
        XCTAssertEqual(projection.captureToCreditGapMinorUnits, 0)
        XCTAssertEqual(projection.expectedOutstandingMinorUnits, 5_000)
        XCTAssertEqual(projection.stages.count, 5)
        XCTAssertTrue(projection.exceptions.isEmpty)
        XCTAssertEqual(projection.audit?.usageEvents, 3)
        XCTAssertTrue(projection.knownMissingFields.contains("artist_payable"))
        XCTAssertTrue(projection.knownMissingFields.contains("provider_fees"))
    }

    func testBuilderMakesMissingSourcesMoreImportantThanReconciliationStatus() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let projection = try PaymentAccountingProjectionBuilder.build(
            PaymentAccountingProjectionInput(
                windowStart: now,
                windowEnd: now,
                asOf: now,
                currency: "NOK",
                pspCapturedMinorUnits: 1_000,
                ledgerCreditedMinorUnits: 900,
                issuedMinorUnits: 900,
                redeemedMinorUnits: 100,
                outstandingMinorUnits: 800,
                sources: [
                    PaymentAccountingSourceCoverage(
                        sourceID: "cellscaffold.audit",
                        title: "CellScaffold audit",
                        status: .missing,
                        asOf: nil,
                        detail: "Source unavailable."
                    )
                ]
            )
        )

        XCTAssertEqual(projection.coverageStatus, .partial)
        XCTAssertEqual(projection.exceptions.map(\.exceptionID), ["capture-credit-gap"])
        XCTAssertEqual(projection.captureToCreditGapMinorUnits, 100)
    }

    func testBuilderRejectsNegativeEconomicAmountsInsteadOfClampingThem() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        XCTAssertThrowsError(
            try PaymentAccountingProjectionBuilder.build(
                PaymentAccountingProjectionInput(
                    windowStart: now,
                    windowEnd: now,
                    asOf: now,
                    currency: "NOK",
                    pspCapturedMinorUnits: -1,
                    ledgerCreditedMinorUnits: 0,
                    issuedMinorUnits: 0,
                    redeemedMinorUnits: 0,
                    outstandingMinorUnits: 0,
                    sources: []
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PaymentAccountingProjectionError,
                .negativeAmount(field: "pspCapturedMinorUnits", value: -1)
            )
        }
    }
}
