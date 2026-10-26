import Foundation

public enum PaymentAccountingSourceStatus: String, Codable, Hashable, Sendable {
    case current
    case stale
    case missing
}

public enum PaymentAccountingCoverageStatus: String, Codable, Hashable, Sendable {
    case current
    case stale
    case partial
    case unreconciled
}

public struct PaymentAccountingSourceCoverage: Codable, Hashable, Sendable {
    public let sourceID: String
    public let title: String
    public let status: PaymentAccountingSourceStatus
    public let asOf: Date?
    public let detail: String

    public init(
        sourceID: String,
        title: String,
        status: PaymentAccountingSourceStatus,
        asOf: Date?,
        detail: String
    ) {
        self.sourceID = sourceID
        self.title = title
        self.status = status
        self.asOf = asOf
        self.detail = detail
    }
}

public struct PaymentAccountingAuditCoverage: Codable, Hashable, Sendable {
    public let topUpOrders: Int
    public let prepaidIssues: Int
    public let credentialsIssued: Int
    public let credentialsConsumed: Int
    public let usageEvents: Int
    public let checksums: [String: String]

    public init(
        topUpOrders: Int,
        prepaidIssues: Int,
        credentialsIssued: Int,
        credentialsConsumed: Int,
        usageEvents: Int,
        checksums: [String: String] = [:]
    ) {
        self.topUpOrders = topUpOrders
        self.prepaidIssues = prepaidIssues
        self.credentialsIssued = credentialsIssued
        self.credentialsConsumed = credentialsConsumed
        self.usageEvents = usageEvents
        self.checksums = checksums
    }
}

public struct PaymentAccountingStageSources: Codable, Hashable, Sendable {
    public let pspCaptured: String
    public let ledgerCredited: String
    public let quotaIssued: String
    public let quotaRedeemed: String
    public let quotaOutstanding: String

    public init(
        pspCaptured: String,
        ledgerCredited: String,
        quotaIssued: String,
        quotaRedeemed: String,
        quotaOutstanding: String
    ) {
        self.pspCaptured = pspCaptured
        self.ledgerCredited = ledgerCredited
        self.quotaIssued = quotaIssued
        self.quotaRedeemed = quotaRedeemed
        self.quotaOutstanding = quotaOutstanding
    }

    public static let diMyMint = PaymentAccountingStageSources(
        pspCaptured: "dimymint.cash",
        ledgerCredited: "dimymint.usage-quota",
        quotaIssued: "dimymint.usage-quota",
        quotaRedeemed: "dimymint.usage-quota",
        quotaOutstanding: "dimymint.reconciliation"
    )
}

public struct PaymentAccountingProjectionInput: Codable, Hashable, Sendable {
    public let windowStart: Date
    public let windowEnd: Date
    public let asOf: Date
    public let currency: String
    public let minorUnitScale: Int
    public let pspCapturedMinorUnits: Int64
    public let ledgerCreditedMinorUnits: Int64
    public let issuedMinorUnits: Int64
    public let redeemedMinorUnits: Int64
    public let outstandingMinorUnits: Int64
    public let sources: [PaymentAccountingSourceCoverage]
    public let stageSources: PaymentAccountingStageSources
    public let audit: PaymentAccountingAuditCoverage?

    public init(
        windowStart: Date,
        windowEnd: Date,
        asOf: Date,
        currency: String,
        minorUnitScale: Int = 2,
        pspCapturedMinorUnits: Int64,
        ledgerCreditedMinorUnits: Int64,
        issuedMinorUnits: Int64,
        redeemedMinorUnits: Int64,
        outstandingMinorUnits: Int64,
        sources: [PaymentAccountingSourceCoverage],
        stageSources: PaymentAccountingStageSources = .diMyMint,
        audit: PaymentAccountingAuditCoverage? = nil
    ) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.asOf = asOf
        self.currency = currency.uppercased()
        self.minorUnitScale = minorUnitScale
        self.pspCapturedMinorUnits = pspCapturedMinorUnits
        self.ledgerCreditedMinorUnits = ledgerCreditedMinorUnits
        self.issuedMinorUnits = issuedMinorUnits
        self.redeemedMinorUnits = redeemedMinorUnits
        self.outstandingMinorUnits = outstandingMinorUnits
        self.sources = sources
        self.stageSources = stageSources
        self.audit = audit
    }
}

public struct PaymentAccountingStage: Codable, Hashable, Sendable {
    public let stageID: String
    public let title: String
    public let amountMinorUnits: Int64
    public let currency: String
    public let status: String
    public let sourceID: String

    public init(
        stageID: String,
        title: String,
        amountMinorUnits: Int64,
        currency: String,
        status: String,
        sourceID: String
    ) {
        self.stageID = stageID
        self.title = title
        self.amountMinorUnits = amountMinorUnits
        self.currency = currency
        self.status = status
        self.sourceID = sourceID
    }
}

public struct PaymentAccountingException: Codable, Hashable, Sendable {
    public let exceptionID: String
    public let severity: String
    public let title: String
    public let detail: String
    public let amountMinorUnits: Int64
    public let currency: String

    public init(
        exceptionID: String,
        severity: String,
        title: String,
        detail: String,
        amountMinorUnits: Int64,
        currency: String
    ) {
        self.exceptionID = exceptionID
        self.severity = severity
        self.title = title
        self.detail = detail
        self.amountMinorUnits = amountMinorUnits
        self.currency = currency
    }
}

public struct PaymentAccountingProjection: Codable, Hashable, Sendable {
    public static let schemaIdentifier = "dimy.payment-accounting-projection.v0"

    public let schema: String
    public let windowStart: Date
    public let windowEnd: Date
    public let asOf: Date
    public let currency: String
    public let minorUnitScale: Int
    public let coverageStatus: PaymentAccountingCoverageStatus
    public let pspCapturedMinorUnits: Int64
    public let ledgerCreditedMinorUnits: Int64
    public let issuedMinorUnits: Int64
    public let redeemedMinorUnits: Int64
    public let outstandingMinorUnits: Int64
    public let captureToCreditGapMinorUnits: Int64
    public let expectedOutstandingMinorUnits: Int64
    public let stages: [PaymentAccountingStage]
    public let sources: [PaymentAccountingSourceCoverage]
    public let exceptions: [PaymentAccountingException]
    public let audit: PaymentAccountingAuditCoverage?
    public let knownMissingFields: [String]

    public init(
        schema: String = PaymentAccountingProjection.schemaIdentifier,
        windowStart: Date,
        windowEnd: Date,
        asOf: Date,
        currency: String,
        minorUnitScale: Int,
        coverageStatus: PaymentAccountingCoverageStatus,
        pspCapturedMinorUnits: Int64,
        ledgerCreditedMinorUnits: Int64,
        issuedMinorUnits: Int64,
        redeemedMinorUnits: Int64,
        outstandingMinorUnits: Int64,
        captureToCreditGapMinorUnits: Int64,
        expectedOutstandingMinorUnits: Int64,
        stages: [PaymentAccountingStage],
        sources: [PaymentAccountingSourceCoverage],
        exceptions: [PaymentAccountingException],
        audit: PaymentAccountingAuditCoverage?,
        knownMissingFields: [String]
    ) {
        self.schema = schema
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.asOf = asOf
        self.currency = currency
        self.minorUnitScale = minorUnitScale
        self.coverageStatus = coverageStatus
        self.pspCapturedMinorUnits = pspCapturedMinorUnits
        self.ledgerCreditedMinorUnits = ledgerCreditedMinorUnits
        self.issuedMinorUnits = issuedMinorUnits
        self.redeemedMinorUnits = redeemedMinorUnits
        self.outstandingMinorUnits = outstandingMinorUnits
        self.captureToCreditGapMinorUnits = captureToCreditGapMinorUnits
        self.expectedOutstandingMinorUnits = expectedOutstandingMinorUnits
        self.stages = stages
        self.sources = sources
        self.exceptions = exceptions
        self.audit = audit
        self.knownMissingFields = knownMissingFields
    }

    public static func empty(asOf: Date = Date()) -> PaymentAccountingProjection {
        let source = PaymentAccountingSourceCoverage(
            sourceID: "projection",
            title: "Datakilder",
            status: .missing,
            asOf: nil,
            detail: "Ingen kildesnapshot er lastet."
        )
        return PaymentAccountingProjection(
            windowStart: asOf,
            windowEnd: asOf,
            asOf: asOf,
            currency: "NOK",
            minorUnitScale: 2,
            coverageStatus: .partial,
            pspCapturedMinorUnits: 0,
            ledgerCreditedMinorUnits: 0,
            issuedMinorUnits: 0,
            redeemedMinorUnits: 0,
            outstandingMinorUnits: 0,
            captureToCreditGapMinorUnits: 0,
            expectedOutstandingMinorUnits: 0,
            stages: [],
            sources: [source],
            exceptions: [],
            audit: nil,
            knownMissingFields: PaymentAccountingProjectionBuilder.v0KnownMissingFields
        )
    }
}

public enum PaymentAccountingProjectionError: Error, Equatable {
    case invalidWindow
    case invalidCurrency(String)
    case invalidMinorUnitScale(Int)
    case negativeAmount(field: String, value: Int64)
    case negativeAuditCount(field: String, value: Int)
}

public enum PaymentAccountingProjectionBuilder {
    public static let v0KnownMissingFields = [
        "provider_fees",
        "refunds",
        "disputes",
        "payouts",
        "bank_settlements",
        "tax",
        "artist_payable"
    ]

    public static func build(_ input: PaymentAccountingProjectionInput) throws -> PaymentAccountingProjection {
        guard input.windowStart <= input.windowEnd else {
            throw PaymentAccountingProjectionError.invalidWindow
        }
        guard input.currency.count == 3, input.currency.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            throw PaymentAccountingProjectionError.invalidCurrency(input.currency)
        }
        guard (0...6).contains(input.minorUnitScale) else {
            throw PaymentAccountingProjectionError.invalidMinorUnitScale(input.minorUnitScale)
        }

        try validateNonnegative("pspCapturedMinorUnits", input.pspCapturedMinorUnits)
        try validateNonnegative("ledgerCreditedMinorUnits", input.ledgerCreditedMinorUnits)
        try validateNonnegative("issuedMinorUnits", input.issuedMinorUnits)
        try validateNonnegative("redeemedMinorUnits", input.redeemedMinorUnits)
        try validateNonnegative("outstandingMinorUnits", input.outstandingMinorUnits)
        if let audit = input.audit {
            try validateNonnegativeAudit("topUpOrders", audit.topUpOrders)
            try validateNonnegativeAudit("prepaidIssues", audit.prepaidIssues)
            try validateNonnegativeAudit("credentialsIssued", audit.credentialsIssued)
            try validateNonnegativeAudit("credentialsConsumed", audit.credentialsConsumed)
            try validateNonnegativeAudit("usageEvents", audit.usageEvents)
        }

        let captureToCreditGap = input.pspCapturedMinorUnits - input.ledgerCreditedMinorUnits
        let expectedOutstanding = input.issuedMinorUnits - input.redeemedMinorUnits
        var exceptions: [PaymentAccountingException] = []
        if captureToCreditGap != 0 {
            exceptions.append(
                PaymentAccountingException(
                    exceptionID: "capture-credit-gap",
                    severity: "high",
                    title: "Avvik mellom PSP og intern kreditering",
                    detail: "PSP captured minus ledger credited er ikke null.",
                    amountMinorUnits: captureToCreditGap,
                    currency: input.currency
                )
            )
        }
        if expectedOutstanding != input.outstandingMinorUnits {
            exceptions.append(
                PaymentAccountingException(
                    exceptionID: "outstanding-mismatch",
                    severity: "high",
                    title: "Utestående brukskvote stemmer ikke",
                    detail: "Issued minus redeemed er ulik rapportert outstanding.",
                    amountMinorUnits: input.outstandingMinorUnits - expectedOutstanding,
                    currency: input.currency
                )
            )
        }

        let coverageStatus: PaymentAccountingCoverageStatus
        if input.sources.contains(where: { $0.status == .missing }) {
            coverageStatus = .partial
        } else if !exceptions.isEmpty {
            coverageStatus = .unreconciled
        } else if input.sources.contains(where: { $0.status == .stale }) {
            coverageStatus = .stale
        } else {
            coverageStatus = .current
        }

        let stages = [
            PaymentAccountingStage(
                stageID: "psp-captured",
                title: "PSP captured",
                amountMinorUnits: input.pspCapturedMinorUnits,
                currency: input.currency,
                status: "reported",
                sourceID: input.stageSources.pspCaptured
            ),
            PaymentAccountingStage(
                stageID: "ledger-credited",
                title: "Intern kreditering",
                amountMinorUnits: input.ledgerCreditedMinorUnits,
                currency: input.currency,
                status: captureToCreditGap == 0 ? "matched" : "mismatch",
                sourceID: input.stageSources.ledgerCredited
            ),
            PaymentAccountingStage(
                stageID: "quota-issued",
                title: "Brukskvote utstedt",
                amountMinorUnits: input.issuedMinorUnits,
                currency: input.currency,
                status: "reported",
                sourceID: input.stageSources.quotaIssued
            ),
            PaymentAccountingStage(
                stageID: "quota-redeemed",
                title: "Brukskvote brukt",
                amountMinorUnits: input.redeemedMinorUnits,
                currency: input.currency,
                status: "reported",
                sourceID: input.stageSources.quotaRedeemed
            ),
            PaymentAccountingStage(
                stageID: "quota-outstanding",
                title: "Utestående brukskvote",
                amountMinorUnits: input.outstandingMinorUnits,
                currency: input.currency,
                status: expectedOutstanding == input.outstandingMinorUnits ? "matched" : "mismatch",
                sourceID: input.stageSources.quotaOutstanding
            )
        ]

        return PaymentAccountingProjection(
            windowStart: input.windowStart,
            windowEnd: input.windowEnd,
            asOf: input.asOf,
            currency: input.currency,
            minorUnitScale: input.minorUnitScale,
            coverageStatus: coverageStatus,
            pspCapturedMinorUnits: input.pspCapturedMinorUnits,
            ledgerCreditedMinorUnits: input.ledgerCreditedMinorUnits,
            issuedMinorUnits: input.issuedMinorUnits,
            redeemedMinorUnits: input.redeemedMinorUnits,
            outstandingMinorUnits: input.outstandingMinorUnits,
            captureToCreditGapMinorUnits: captureToCreditGap,
            expectedOutstandingMinorUnits: expectedOutstanding,
            stages: stages,
            sources: input.sources,
            exceptions: exceptions,
            audit: input.audit,
            knownMissingFields: v0KnownMissingFields
        )
    }

    private static func validateNonnegative(_ field: String, _ value: Int64) throws {
        guard value >= 0 else {
            throw PaymentAccountingProjectionError.negativeAmount(field: field, value: value)
        }
    }

    private static func validateNonnegativeAudit(_ field: String, _ value: Int) throws {
        guard value >= 0 else {
            throw PaymentAccountingProjectionError.negativeAuditCount(field: field, value: value)
        }
    }
}
