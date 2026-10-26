import CellBase
import DiMyPaymentTypes
import Foundation

public enum PaymentAccountingProjectionContract {
    public static let cellName = "PaymentAccountingProjection"
    public static let endpoint = "cell:///PaymentAccountingProjection"

    public enum Keys {
        public static let projection = "projection"
        public static let coverageLabel = "coverageLabel"
        public static let asOfLabel = "asOfLabel"
        public static let capturedLabel = "capturedLabel"
        public static let creditedLabel = "creditedLabel"
        public static let issuedLabel = "issuedLabel"
        public static let redeemedLabel = "redeemedLabel"
        public static let outstandingLabel = "outstandingLabel"
        public static let captureCreditGapLabel = "captureCreditGapLabel"
        public static let stages = "stages"
        public static let sources = "sources"
        public static let exceptions = "exceptions"
        public static let auditRows = "auditRows"
        public static let configuration = "configuration"
        public static let skeletonConfiguration = "skeletonConfiguration"
        public static let purposeGoal = "purposeGoal"
        public static let ingest = "projection.ingest"
    }
}

private enum PaymentAccountingProjectionSchemas {
    static let scalarString = ExploreContract.schema(type: "string")
    static let scalarInteger = ExploreContract.schema(type: "integer")
    static let nullableString = ExploreContract.oneOfSchema(options: [
        ExploreContract.schema(type: "string"),
        ExploreContract.schema(type: "null")
    ])
    static let stageSources = ExploreContract.objectSchema(
        properties: [
            "pspCaptured": scalarString,
            "ledgerCredited": scalarString,
            "quotaIssued": scalarString,
            "quotaRedeemed": scalarString,
            "quotaOutstanding": scalarString
        ],
        requiredKeys: ["pspCaptured", "ledgerCredited", "quotaIssued", "quotaRedeemed", "quotaOutstanding"],
        description: "Eksplisitt proveniens for hvert beregnet kontrolltrinn."
    )
    static let audit = ExploreContract.objectSchema(
        properties: [
            "topUpOrders": scalarInteger,
            "prepaidIssues": scalarInteger,
            "credentialsIssued": scalarInteger,
            "credentialsConsumed": scalarInteger,
            "usageEvents": scalarInteger,
            "checksums": ExploreContract.objectSchema(description: "Stabile checksums per audit-recordgruppe.")
        ],
        requiredKeys: ["topUpOrders", "prepaidIssues", "credentialsIssued", "credentialsConsumed", "usageEvents", "checksums"],
        description: "Auditdekning som følger projeksjonen."
    )

    static let source = ExploreContract.objectSchema(
        properties: [
            "sourceID": scalarString,
            "title": scalarString,
            "status": scalarString,
            "asOf": nullableString,
            "detail": scalarString
        ],
        requiredKeys: ["sourceID", "title", "status", "detail"],
        description: "Datakildedekning uten rå providerpayload eller kjøperdata."
    )
    static let stage = ExploreContract.objectSchema(
        properties: [
            "stageID": scalarString,
            "title": scalarString,
            "amountMinorUnits": scalarInteger,
            "amountLabel": scalarString,
            "currency": scalarString,
            "status": scalarString,
            "sourceID": scalarString
        ],
        requiredKeys: ["stageID", "title", "amountMinorUnits", "amountLabel", "currency", "status", "sourceID"],
        description: "Ett read-only avstemmingstrinn."
    )
    static let exception = ExploreContract.objectSchema(
        properties: [
            "exceptionID": scalarString,
            "severity": scalarString,
            "title": scalarString,
            "detail": scalarString,
            "amountMinorUnits": scalarInteger,
            "amountLabel": scalarString,
            "currency": scalarString
        ],
        requiredKeys: ["exceptionID", "severity", "title", "detail", "amountMinorUnits", "amountLabel", "currency"],
        description: "Et beregnet avvik; ikke en muterbar regnskapspost."
    )
    static let auditRow = ExploreContract.objectSchema(
        properties: [
            "recordType": scalarString,
            "title": scalarString,
            "count": scalarInteger,
            "checksum": scalarString,
            "status": scalarString
        ],
        requiredKeys: ["recordType", "title", "count", "checksum", "status"],
        description: "Read-only auditdekning og checksum per recordgruppe."
    )
    static let projection = ExploreContract.objectSchema(
        properties: [
            "schema": scalarString,
            "windowStart": scalarString,
            "windowEnd": scalarString,
            "asOf": scalarString,
            "currency": scalarString,
            "minorUnitScale": scalarInteger,
            "coverageStatus": scalarString,
            "pspCapturedMinorUnits": scalarInteger,
            "ledgerCreditedMinorUnits": scalarInteger,
            "issuedMinorUnits": scalarInteger,
            "redeemedMinorUnits": scalarInteger,
            "outstandingMinorUnits": scalarInteger,
            "captureToCreditGapMinorUnits": scalarInteger,
            "expectedOutstandingMinorUnits": scalarInteger,
            "stages": ExploreContract.listSchema(item: stage),
            "sources": ExploreContract.listSchema(item: source),
            "exceptions": ExploreContract.listSchema(item: exception),
            "audit": ExploreContract.oneOfSchema(options: [audit, ExploreContract.schema(type: "null")]),
            "knownMissingFields": ExploreContract.listSchema(item: scalarString)
        ],
        requiredKeys: [
            "schema", "windowStart", "windowEnd", "asOf", "currency", "minorUnitScale",
            "coverageStatus", "pspCapturedMinorUnits",
            "ledgerCreditedMinorUnits", "issuedMinorUnits", "redeemedMinorUnits",
            "outstandingMinorUnits", "captureToCreditGapMinorUnits",
            "expectedOutstandingMinorUnits", "stages", "sources", "exceptions",
            "audit", "knownMissingFields"
        ],
        description: "Reproduserbar read-only v0-projeksjon med eksplisitte dekningshull."
    )
    static let ingestInput = ExploreContract.objectSchema(
        properties: [
            "windowStart": scalarString,
            "windowEnd": scalarString,
            "asOf": scalarString,
            "currency": scalarString,
            "minorUnitScale": scalarInteger,
            "pspCapturedMinorUnits": scalarInteger,
            "ledgerCreditedMinorUnits": scalarInteger,
            "issuedMinorUnits": scalarInteger,
            "redeemedMinorUnits": scalarInteger,
            "outstandingMinorUnits": scalarInteger,
            "sources": ExploreContract.listSchema(item: source),
            "stageSources": stageSources,
            "audit": ExploreContract.oneOfSchema(options: [audit, ExploreContract.schema(type: "null")])
        ],
        requiredKeys: [
            "windowStart", "windowEnd", "asOf", "currency", "pspCapturedMinorUnits",
            "ledgerCreditedMinorUnits", "issuedMinorUnits", "redeemedMinorUnits",
            "outstandingMinorUnits", "sources", "stageSources", "audit"
        ],
        description: "Normalisert kildesnapshot skrevet av en privilegert scaffold-adapter."
    )
}

public final class PaymentAccountingProjectionCell: DiMyRuntimeBindingCell {
    private enum CodingKeys: CodingKey {
        case projection
    }

    private let stateQueue = DispatchQueue(label: "PaymentAccountingProjectionCell.State")
    private var currentProjection: PaymentAccountingProjection

    public required init(owner: Identity) async {
        currentProjection = .empty()
        await super.init(owner: owner)
        try? await ensureRuntimeReady()
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentProjection = (try? container.decode(PaymentAccountingProjection.self, forKey: .projection)) ?? .empty()
        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stateQueue.sync { currentProjection }, forKey: .projection)
    }

    override func installRuntimeBindings(owner: Identity) async {
        setupPermissions()
        await setupReadKeys(owner: owner)
        await setupIngestKey(owner: owner)
    }

    private func setupPermissions() {
        let readKeys = [
            PaymentAccountingProjectionContract.Keys.projection,
            PaymentAccountingProjectionContract.Keys.coverageLabel,
            PaymentAccountingProjectionContract.Keys.asOfLabel,
            PaymentAccountingProjectionContract.Keys.capturedLabel,
            PaymentAccountingProjectionContract.Keys.creditedLabel,
            PaymentAccountingProjectionContract.Keys.issuedLabel,
            PaymentAccountingProjectionContract.Keys.redeemedLabel,
            PaymentAccountingProjectionContract.Keys.outstandingLabel,
            PaymentAccountingProjectionContract.Keys.captureCreditGapLabel,
            PaymentAccountingProjectionContract.Keys.stages,
            PaymentAccountingProjectionContract.Keys.sources,
            PaymentAccountingProjectionContract.Keys.exceptions,
            PaymentAccountingProjectionContract.Keys.auditRows,
            PaymentAccountingProjectionContract.Keys.configuration,
            PaymentAccountingProjectionContract.Keys.skeletonConfiguration,
            PaymentAccountingProjectionContract.Keys.purposeGoal
        ]
        for key in readKeys {
            ensureAgreementGrant("r---", for: key)
        }
        ensureAgreementGrant("rw--", for: PaymentAccountingProjectionContract.Keys.ingest)
    }

    private func setupReadKeys(owner: Identity) async {
        await registerGet(
            key: PaymentAccountingProjectionContract.Keys.projection,
            owner: owner,
            returns: PaymentAccountingProjectionSchemas.projection,
            permissions: ["r---"],
            description: .string("Read den normaliserte accounting-projeksjonen uten rå providerpayload eller kjøperdata.")
        ) { [weak self] requester in
            guard let self else { return .null }
            guard await self.canRead(PaymentAccountingProjectionContract.Keys.projection, requester: requester) else { return .string("denied") }
            return ValueTypeCodableBridge.encode(self.snapshot())
        }

        let labelKeys = [
            PaymentAccountingProjectionContract.Keys.coverageLabel,
            PaymentAccountingProjectionContract.Keys.asOfLabel,
            PaymentAccountingProjectionContract.Keys.capturedLabel,
            PaymentAccountingProjectionContract.Keys.creditedLabel,
            PaymentAccountingProjectionContract.Keys.issuedLabel,
            PaymentAccountingProjectionContract.Keys.redeemedLabel,
            PaymentAccountingProjectionContract.Keys.outstandingLabel,
            PaymentAccountingProjectionContract.Keys.captureCreditGapLabel
        ]
        for key in labelKeys {
            await registerGet(
                key: key,
                owner: owner,
                returns: PaymentAccountingProjectionSchemas.scalarString,
                permissions: ["r---"],
                description: .string("Read formattert, kildebevisst dashboardtekst for \(key).")
            ) { [weak self] requester in
                guard let self else { return .string("Ikke tilgjengelig") }
                guard await self.canRead(key, requester: requester) else { return .string("denied") }
                return .string(self.labelValue(for: key))
            }
        }

        await registerGet(
            key: PaymentAccountingProjectionContract.Keys.stages,
            owner: owner,
            returns: ExploreContract.listSchema(item: PaymentAccountingProjectionSchemas.stage),
            permissions: ["r---"],
            description: .string("Read den femtrinns captured-til-brukskvote-kjeden.")
        ) { [weak self] requester in
            guard let self else { return .list([]) }
            guard await self.canRead(PaymentAccountingProjectionContract.Keys.stages, requester: requester) else { return .string("denied") }
            return .list(self.stageValues())
        }

        await registerGet(
            key: PaymentAccountingProjectionContract.Keys.sources,
            owner: owner,
            returns: ExploreContract.listSchema(item: PaymentAccountingProjectionSchemas.source),
            permissions: ["r---"],
            description: .string("Read datakilder, ferskhet og dekningsstatus.")
        ) { [weak self] requester in
            guard let self else { return .list([]) }
            guard await self.canRead(PaymentAccountingProjectionContract.Keys.sources, requester: requester) else { return .string("denied") }
            return .list(self.sourceValues())
        }

        await registerGet(
            key: PaymentAccountingProjectionContract.Keys.exceptions,
            owner: owner,
            returns: ExploreContract.listSchema(item: PaymentAccountingProjectionSchemas.exception),
            permissions: ["r---"],
            description: .string("Read avvik uten å tilby mutasjon eller korreksjon i dashboardet.")
        ) { [weak self] requester in
            guard let self else { return .list([]) }
            guard await self.canRead(PaymentAccountingProjectionContract.Keys.exceptions, requester: requester) else { return .string("denied") }
            return .list(self.exceptionValues())
        }

        await registerGet(
            key: PaymentAccountingProjectionContract.Keys.auditRows,
            owner: owner,
            returns: ExploreContract.listSchema(item: PaymentAccountingProjectionSchemas.auditRow),
            permissions: ["r---"],
            description: .string("Read audit-tellinger og checksums uten rådata eller kjøperidentitet.")
        ) { [weak self] requester in
            guard let self else { return .list([]) }
            guard await self.canRead(PaymentAccountingProjectionContract.Keys.auditRows, requester: requester) else { return .string("denied") }
            return .list(self.auditRowValues())
        }

        for key in [
            PaymentAccountingProjectionContract.Keys.configuration,
            PaymentAccountingProjectionContract.Keys.skeletonConfiguration
        ] {
            await registerGet(
                key: key,
                owner: owner,
                returns: ExploreContract.objectSchema(description: "CellConfiguration"),
                permissions: ["r---"],
                description: .string("Read den minimale read-only kontrollcockpit-konfigurasjonen.")
            ) { [weak self] requester in
                guard let self else { return .null }
                guard await self.canRead(key, requester: requester) else { return .string("denied") }
                return .cellConfiguration(PaymentAccountingDashboardConfigurationFactory.makeCellConfiguration())
            }
        }

        await registerGet(
            key: PaymentAccountingProjectionContract.Keys.purposeGoal,
            owner: owner,
            returns: ExploreContract.objectSchema(
                properties: [
                    "purpose": PaymentAccountingProjectionSchemas.scalarString,
                    "goal": PaymentAccountingProjectionSchemas.scalarString,
                    "status": PaymentAccountingProjectionSchemas.scalarString
                ],
                requiredKeys: ["purpose", "goal", "status"]
            ),
            permissions: ["r---"],
            description: .string("Read cockpitens deklarerte formål og nåværende implementeringsstatus.")
        ) { [weak self] requester in
            guard let self else { return .null }
            guard await self.canRead(PaymentAccountingProjectionContract.Keys.purposeGoal, requester: requester) else { return .string("denied") }
            return .object([
                "purpose": .string("purpose://value-and-commons"),
                "goal": .string("Gi etterprøvbar oversikt over PSP capture, intern kreditering og brukskvote."),
                "status": .string("v0-read-only-partial-coverage")
            ])
        }
    }

    private func setupIngestKey(owner: Identity) async {
        await registerSet(
            key: PaymentAccountingProjectionContract.Keys.ingest,
            owner: owner,
            input: PaymentAccountingProjectionSchemas.ingestInput,
            returns: PaymentAccountingProjectionSchemas.projection,
            permissions: ["rw--"],
            description: .string("Replace projection from a privileged normalized source snapshot; not exposed by the observer cockpit.")
        ) { [weak self] requester, payload in
            guard let self else { return .null }
            guard await self.validateAccess("rw--", at: PaymentAccountingProjectionContract.Keys.ingest, for: requester) else {
                return .string("denied")
            }
            guard let input = ValueTypeCodableBridge.decode(PaymentAccountingProjectionInput.self, from: payload) else {
                return self.errorValue(code: "invalid_projection_input", detail: "Kildesnapshot kunne ikke dekodes.")
            }
            do {
                let projection = try PaymentAccountingProjectionBuilder.build(input)
                self.stateQueue.sync { self.currentProjection = projection }
                return ValueTypeCodableBridge.encode(projection)
            } catch {
                return self.errorValue(code: "invalid_projection_input", detail: String(describing: error))
            }
        }
    }

    private func canRead(_ key: String, requester: Identity) async -> Bool {
        await validateAccess("r---", at: key, for: requester)
    }

    private func snapshot() -> PaymentAccountingProjection {
        stateQueue.sync { currentProjection }
    }

    private func labelValue(for key: String) -> String {
        let projection = snapshot()
        switch key {
        case PaymentAccountingProjectionContract.Keys.coverageLabel:
            let missing = projection.knownMissingFields.joined(separator: ", ")
            return "Datadekning: \(projection.coverageStatus.rawValue). V0 mangler fortsatt: \(missing)."
        case PaymentAccountingProjectionContract.Keys.asOfLabel:
            return "Sist beregnet \(Self.isoFormatter.string(from: projection.asOf))."
        case PaymentAccountingProjectionContract.Keys.capturedLabel:
            return format(projection.pspCapturedMinorUnits, projection: projection)
        case PaymentAccountingProjectionContract.Keys.creditedLabel:
            return format(projection.ledgerCreditedMinorUnits, projection: projection)
        case PaymentAccountingProjectionContract.Keys.issuedLabel:
            return format(projection.issuedMinorUnits, projection: projection)
        case PaymentAccountingProjectionContract.Keys.redeemedLabel:
            return format(projection.redeemedMinorUnits, projection: projection)
        case PaymentAccountingProjectionContract.Keys.outstandingLabel:
            return format(projection.outstandingMinorUnits, projection: projection)
        case PaymentAccountingProjectionContract.Keys.captureCreditGapLabel:
            return format(projection.captureToCreditGapMinorUnits, projection: projection)
        default:
            return "Ikke tilgjengelig"
        }
    }

    private func stageValues() -> [ValueType] {
        let projection = snapshot()
        return projection.stages.map { stage in
            .object([
                "stageID": .string(stage.stageID),
                "title": .string(stage.title),
                "amountMinorUnits": .integer(Int(clamping: stage.amountMinorUnits)),
                "amountLabel": .string(format(stage.amountMinorUnits, projection: projection)),
                "currency": .string(stage.currency),
                "status": .string(stage.status),
                "sourceID": .string(stage.sourceID)
            ])
        }
    }

    private func sourceValues() -> [ValueType] {
        snapshot().sources.map { source in
            .object([
                "sourceID": .string(source.sourceID),
                "title": .string(source.title),
                "status": .string(source.status.rawValue),
                "asOf": source.asOf.map { .string(Self.isoFormatter.string(from: $0)) } ?? .null,
                "detail": .string(source.detail)
            ])
        }
    }

    private func exceptionValues() -> [ValueType] {
        let projection = snapshot()
        return projection.exceptions.map { exception in
            .object([
                "exceptionID": .string(exception.exceptionID),
                "severity": .string(exception.severity),
                "title": .string(exception.title),
                "detail": .string(exception.detail),
                "amountMinorUnits": .integer(Int(clamping: exception.amountMinorUnits)),
                "amountLabel": .string(format(exception.amountMinorUnits, projection: projection)),
                "currency": .string(exception.currency)
            ])
        }
    }

    private func auditRowValues() -> [ValueType] {
        guard let audit = snapshot().audit else { return [] }
        let rows: [(String, String, Int)] = [
            ("topUpOrders", "Top-up-ordrer", audit.topUpOrders),
            ("prepaidIssues", "Intern kreditering", audit.prepaidIssues),
            ("credentialsIssued", "Tilgangsbevis utstedt", audit.credentialsIssued),
            ("credentialsConsumed", "Tilgangsbevis brukt", audit.credentialsConsumed),
            ("usageEvents", "Brukshendelser", audit.usageEvents)
        ]
        return rows.map { recordType, title, count in
            let checksum = audit.checksums[recordType] ?? "mangler"
            return .object([
                "recordType": .string(recordType),
                "title": .string(title),
                "count": .integer(count),
                "checksum": .string(checksum),
                "status": .string(audit.checksums[recordType] == nil ? "checksum-missing" : "covered")
            ])
        }
    }

    private func format(_ minorUnits: Int64, projection: PaymentAccountingProjection) -> String {
        let divisor = pow(10.0, Double(projection.minorUnitScale))
        let majorUnits = Double(minorUnits) / divisor
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "nb_NO")
        formatter.numberStyle = .currency
        formatter.currencyCode = projection.currency
        formatter.minimumFractionDigits = projection.minorUnitScale
        formatter.maximumFractionDigits = projection.minorUnitScale
        return formatter.string(from: NSNumber(value: majorUnits)) ?? "\(minorUnits) \(projection.currency) minor units"
    }

    private func errorValue(code: String, detail: String) -> ValueType {
        .object([
            "ok": .bool(false),
            "code": .string(code),
            "detail": .string(detail)
        ])
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

public enum PaymentAccountingDashboardConfigurationFactory {
    public static func makeCellConfiguration() -> CellConfiguration {
        var reference = CellReference(
            endpoint: PaymentAccountingProjectionContract.endpoint,
            subscribeFeed: false,
            label: "projection"
        )
        reference.subscriptions = []
        reference.setKeysAndValues = []

        var configuration = CellConfiguration(
            name: "DiMy betalingskontroll",
            cellReferences: [reference]
        )
        configuration.uuid = "2B13BF3A-529E-4ECB-9062-EC0CC476D617"
        configuration.description = "Read-only v0-kontrollcockpit med eksplisitt datadekning og uten tilbakeførings-, utbetalings- eller ledger-mutasjoner."
        configuration.discovery = CellConfigurationDiscovery(
            sourceCellEndpoint: PaymentAccountingProjectionContract.endpoint,
            sourceCellName: PaymentAccountingProjectionContract.cellName,
            purpose: "Etterprøvbar betalings- og brukskvoteoversikt",
            purposeDescription: "Vis captured, intern kreditering, brukskvote, avvik og kildedekning uten å hevde komplett regnskap.",
            interests: ["betaling", "brukskvote", "avstemming", "audit"],
            purposeRefs: ["purpose://value-and-commons", "purpose://access.audit.privacy"],
            menuSlots: ["admin", "finance", "operations"]
        )
        configuration.skeleton = makeSkeleton()
        return configuration
    }

    private static func makeSkeleton() -> SkeletonElement {
        let metricGrid = SkeletonGrid(
            columns: [.adaptive(min: 180, max: 280)],
            spacing: 12,
            elements: [
                metricSection(title: "PSP captured", keypath: "projection.capturedLabel"),
                metricSection(title: "Intern kreditering", keypath: "projection.creditedLabel"),
                metricSection(title: "Brukskvote utstedt", keypath: "projection.issuedLabel"),
                metricSection(title: "Brukskvote brukt", keypath: "projection.redeemedLabel"),
                metricSection(title: "Utestående brukskvote", keypath: "projection.outstandingLabel"),
                metricSection(title: "Uavstemt differanse", keypath: "projection.captureCreditGapLabel")
            ],
            modifiers: surfaceModifiers(role: "metric-grid")
        )

        let stageRows = SkeletonList(
            keypath: "projection.stages",
            flowElementSkeleton: SkeletonVStack(
                elements: [
                    itemText("title", role: "stage-title"),
                    itemText("amountLabel", role: "stage-amount"),
                    itemText("status", role: "stage-status"),
                    itemText("sourceID", role: "source-id")
                ],
                spacing: 4
            )
        )
        let sourceRows = SkeletonList(
            keypath: "projection.sources",
            flowElementSkeleton: SkeletonVStack(
                elements: [
                    itemText("title", role: "source-title"),
                    itemText("status", role: "source-status"),
                    itemText("detail", role: "source-detail"),
                    itemText("asOf", role: "source-as-of")
                ],
                spacing: 4
            )
        )
        let exceptionRows = SkeletonList(
            keypath: "projection.exceptions",
            flowElementSkeleton: SkeletonVStack(
                elements: [
                    itemText("title", role: "exception-title"),
                    itemText("detail", role: "exception-detail"),
                    itemText("amountLabel", role: "exception-amount"),
                    itemText("severity", role: "exception-severity")
                ],
                spacing: 4
            )
        )
        let auditRows = SkeletonList(
            keypath: "projection.auditRows",
            flowElementSkeleton: SkeletonVStack(
                elements: [
                    itemText("title", role: "audit-title"),
                    itemText("count", role: "audit-count"),
                    itemText("status", role: "audit-status"),
                    itemText("checksum", role: "audit-checksum")
                ],
                spacing: 4
            )
        )

        let content = SkeletonVStack(
            elements: [
                staticText("DiMy betalingskontroll", role: "page-title", fontSize: 30, weight: "bold"),
                staticText("Read-only kontrollcockpit. Top-up er ikke automatisk inntekt, og artistutbetaling er ikke beregnet i v0.", role: "scope-warning"),
                boundText("projection.coverageLabel", role: "coverage-banner", weight: "semibold"),
                boundText("projection.asOfLabel", role: "freshness-label"),
                .Grid(metricGrid),
                section(title: "Kontrollkjede", content: [.List(stageRows)]),
                section(title: "Datakilder og ferskhet", content: [.List(sourceRows)]),
                section(title: "Avvik", content: [.List(exceptionRows)]),
                section(title: "Auditspor og checksums", content: [.List(auditRows)]),
                .Button(SkeletonButton(
                    keypath: "",
                    label: "Tilbake til Co-Pilot og min enhet",
                    url: "/porthole"
                ))
            ],
            spacing: 16,
            modifiers: pageModifiers()
        )
        return .ScrollView(SkeletonScrollView(axis: "vertical", elements: [.VStack(content)]))
    }

    private static func metricSection(title: String, keypath: String) -> SkeletonElement {
        section(
            title: title,
            content: [boundText(keypath, role: "metric-value", weight: "bold")],
            role: "metric-card"
        )
    }

    private static func section(title: String, content: SkeletonElementList, role: String = "dashboard-section") -> SkeletonElement {
        var section = SkeletonSection(
            header: staticText(title, role: "section-title", weight: "semibold"),
            content: content
        )
        section.modifiers = surfaceModifiers(role: role)
        return .Section(section)
    }

    private static func staticText(
        _ text: String,
        role: String,
        fontSize: Double? = nil,
        weight: String? = nil
    ) -> SkeletonElement {
        var element = SkeletonText(text: text)
        var modifiers = SkeletonModifiers()
        modifiers.styleRole = role
        modifiers.fontSize = fontSize
        modifiers.fontWeight = weight
        element.modifiers = modifiers
        return .Text(element)
    }

    private static func boundText(_ keypath: String, role: String, weight: String? = nil) -> SkeletonElement {
        var element = SkeletonText(keypath: keypath)
        var modifiers = SkeletonModifiers()
        modifiers.styleRole = role
        modifiers.fontWeight = weight
        element.modifiers = modifiers
        return .Text(element)
    }

    private static func itemText(_ keypath: String, role: String) -> SkeletonElement {
        boundText(keypath, role: role)
    }

    private static func surfaceModifiers(role: String) -> SkeletonModifiers {
        var modifiers = SkeletonModifiers()
        modifiers.styleRole = role
        modifiers.padding = 12
        modifiers.cornerRadius = 10
        modifiers.borderWidth = 1
        modifiers.borderColor = "#D1D5DB"
        return modifiers
    }

    private static func pageModifiers() -> SkeletonModifiers {
        var modifiers = SkeletonModifiers()
        modifiers.styleRole = "payment-accounting-dashboard"
        modifiers.padding = 20
        modifiers.maxWidthInfinity = true
        modifiers.hAlignment = "leading"
        return modifiers
    }
}
