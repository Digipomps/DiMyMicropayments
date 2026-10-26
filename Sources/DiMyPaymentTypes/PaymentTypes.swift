import Crypto
import Foundation

public struct Coin: Codable, Hashable, Sendable {
    public let denomMinorUnits: UInt64
    public let serial: String
    public let mintKeyID: String
    public let keyEpoch: UInt32?
    public let signature: String

    public init(
        denomMinorUnits: UInt64,
        serial: String,
        mintKeyID: String,
        keyEpoch: UInt32? = nil,
        signature: String
    ) {
        self.denomMinorUnits = denomMinorUnits
        self.serial = serial
        self.mintKeyID = mintKeyID
        self.keyEpoch = keyEpoch
        self.signature = signature
    }
}

public struct BlindedCoinRequest: Codable, Hashable, Sendable {
    public let denomMinorUnits: UInt64
    public let blindedMessage: String
    public let mintKeyID: String

    public init(denomMinorUnits: UInt64, blindedMessage: String, mintKeyID: String) {
        self.denomMinorUnits = denomMinorUnits
        self.blindedMessage = blindedMessage
        self.mintKeyID = mintKeyID
    }
}

public struct BlindSignature: Codable, Hashable, Sendable {
    public let denomMinorUnits: UInt64
    public let blindedSignature: String
    public let mintKeyID: String
    public let keyEpoch: UInt32?

    public init(
        denomMinorUnits: UInt64,
        blindedSignature: String,
        mintKeyID: String,
        keyEpoch: UInt32? = nil
    ) {
        self.denomMinorUnits = denomMinorUnits
        self.blindedSignature = blindedSignature
        self.mintKeyID = mintKeyID
        self.keyEpoch = keyEpoch
    }
}

public struct IssueRequest: Codable, Hashable, Sendable {
    public let requests: [BlindedCoinRequest]
    public let walletInstanceID: String?

    public init(requests: [BlindedCoinRequest], walletInstanceID: String? = nil) {
        self.requests = requests
        self.walletInstanceID = walletInstanceID
    }
}

public struct IssueResponse: Codable, Hashable, Sendable {
    public let signatures: [BlindSignature]
    public let debitedMinorUnits: UInt64
    public let issuedAt: Date

    public init(signatures: [BlindSignature], debitedMinorUnits: UInt64, issuedAt: Date) {
        self.signatures = signatures
        self.debitedMinorUnits = debitedMinorUnits
        self.issuedAt = issuedAt
    }
}

public struct SpendBundle: Codable, Hashable, Sendable {
    public let coins: [Coin]
    public let requestID: UUID
    public let resourceID: String
    public let createdAt: Date

    public init(coins: [Coin], requestID: UUID, resourceID: String, createdAt: Date) {
        self.coins = coins
        self.requestID = requestID
        self.resourceID = resourceID
        self.createdAt = createdAt
    }

    public var totalMinorUnits: UInt64 {
        coins.reduce(0) { $0 + $1.denomMinorUnits }
    }

    /// Utstederen hele bundlet tilhører, eller `nil` hvis det er blandet.
    ///
    /// Et blandet bundle har ingen utsteder. Det er ikke en detalj: et bundle
    /// som ikke kan navngi én utsteder skal ikke kunne løses inn, fordi ingen
    /// utsteder da står bak hele beløpet.
    public var uniformMintKeyID: String? {
        guard let first = coins.first?.mintKeyID else { return nil }
        return coins.allSatisfy { $0.mintKeyID == first } ? first : nil
    }
}

public struct RedeemRequest: Codable, Hashable, Sendable {
    public let bundle: SpendBundle
    public let bundleHash: String
    public let merchantID: String

    public init(bundle: SpendBundle, bundleHash: String, merchantID: String) {
        self.bundle = bundle
        self.bundleHash = bundleHash
        self.merchantID = merchantID
    }
}

public enum RedeemRejectionReason: String, Codable, Sendable {
    case doubleSpend
    case invalidBundleHash
    case invalidCoinSignature
    case unknown
}

public struct SpendReceipt: Codable, Hashable, Sendable {
    public let bundleHash: String
    public let merchantCreditRef: String
    public let merchantID: String
    public let mintKeyID: String
    public let keyEpoch: UInt32?
    public let issuedAt: Date
    public let signature: String

    public init(
        bundleHash: String,
        merchantCreditRef: String,
        merchantID: String,
        mintKeyID: String,
        keyEpoch: UInt32? = nil,
        issuedAt: Date,
        signature: String
    ) {
        self.bundleHash = bundleHash
        self.merchantCreditRef = merchantCreditRef
        self.merchantID = merchantID
        self.mintKeyID = mintKeyID
        self.keyEpoch = keyEpoch
        self.issuedAt = issuedAt
        self.signature = signature
    }
}

public struct RedeemResponse: Codable, Hashable, Sendable {
    public let accepted: Bool
    public let receipt: SpendReceipt?
    public let rejectionReason: RedeemRejectionReason?

    public init(accepted: Bool, receipt: SpendReceipt?, rejectionReason: RedeemRejectionReason?) {
        self.accepted = accepted
        self.receipt = receipt
        self.rejectionReason = rejectionReason
    }

    public static func accepted(_ receipt: SpendReceipt) -> Self {
        Self(accepted: true, receipt: receipt, rejectionReason: nil)
    }

    public static func rejected(_ reason: RedeemRejectionReason) -> Self {
        Self(accepted: false, receipt: nil, rejectionReason: reason)
    }
}

public struct AccessGrant: Codable, Hashable, Sendable {
    public let resourceID: String
    public let receiptHash: String
    public let grantedAt: Date

    public init(resourceID: String, receiptHash: String, grantedAt: Date) {
        self.resourceID = resourceID
        self.receiptHash = receiptHash
        self.grantedAt = grantedAt
    }
}

public enum DenominationStrategy: String, Codable, Sendable {
    case oneTwoFive
    case powersOfTwo
    case unit

    public func split(amountMinorUnits: UInt64) -> [UInt64] {
        guard amountMinorUnits > 0 else {
            return []
        }

        let denominations = supportedDenominations(upperBound: amountMinorUnits)
        var remaining = amountMinorUnits
        var result: [UInt64] = []

        for denom in denominations.sorted(by: >) {
            while remaining >= denom {
                result.append(denom)
                remaining -= denom
            }
        }

        if remaining == 0 {
            return result
        }

        return []
    }

    private func supportedDenominations(upperBound: UInt64) -> [UInt64] {
        switch self {
        case .oneTwoFive:
            var values: [UInt64] = []
            var scale: UInt64 = 1
            while scale <= upperBound {
                for base in [1, 2, 5] {
                    let value = UInt64(base) * scale
                    if value <= upperBound {
                        values.append(value)
                    }
                }
                if scale > UInt64.max / 10 {
                    break
                }
                scale *= 10
            }
            return values
        case .powersOfTwo:
            var values: [UInt64] = []
            var value: UInt64 = 1
            while value <= upperBound {
                values.append(value)
                if value > UInt64.max / 2 {
                    break
                }
                value *= 2
            }
            return values
        case .unit:
            return [1]
        }
    }
}

public enum BundleHasher {
    public static func hash(bundle: SpendBundle) throws -> String {
        let payload = try CanonicalEncoding.encode(canonicalBundle(from: bundle))
        let digest = SHA256.hash(data: payload)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalBundle(from bundle: SpendBundle) -> CanonicalSpendBundle {
        let canonicalCoins = bundle.coins
            .sorted {
                if $0.serial == $1.serial {
                    return $0.denomMinorUnits < $1.denomMinorUnits
                }
                return $0.serial < $1.serial
            }
            .map {
                CanonicalSpendCoin(
                    denomMinorUnits: $0.denomMinorUnits,
                    serial: $0.serial,
                    mintKeyID: $0.mintKeyID,
                    keyEpoch: $0.keyEpoch,
                    signature: $0.signature
                )
            }

        return CanonicalSpendBundle(
            version: 1,
            requestID: bundle.requestID.uuidString.lowercased(),
            resourceID: bundle.resourceID,
            createdAtMS: bundle.createdAt.epochMilliseconds,
            coins: canonicalCoins
        )
    }
}

public enum SignatureEnvelopeError: Error, Sendable {
    case invalidFormat
    case unsupportedFormat(String)
    case unsupportedAlgorithm(String)
    case invalidBase64URL
    case invalidCOSEEnvelope
    case payloadMismatch
}

public enum SignatureAlgorithm: String, Codable, Hashable, Sendable {
    case ed25519
}

public enum SignatureEnvelopeFormat: String, Codable, Hashable, Sendable {
    case legacyTriplet = "legacy_triplet"
    case coseSign1 = "cose_sign1"
}

public enum SignatureEnvelopeFeatureFlags {
    public static func preferredFormat(from processInfo: ProcessInfo = .processInfo) -> SignatureEnvelopeFormat {
        guard let raw = processInfo.environment["DIMY_SIGNATURE_ENVELOPE_FORMAT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return .legacyTriplet
        }

        return SignatureEnvelopeFormat(rawValue: raw) ?? .legacyTriplet
    }

    public static func acceptedFormats(from processInfo: ProcessInfo = .processInfo) -> Set<SignatureEnvelopeFormat> {
        let preferred = preferredFormat(from: processInfo)
        switch preferred {
        case .legacyTriplet:
            return [.legacyTriplet]
        case .coseSign1:
            // Allow legacy verification during migration.
            return [.legacyTriplet, .coseSign1]
        }
    }
}

public struct ParsedSignatureEnvelope: Hashable, Sendable {
    public let format: SignatureEnvelopeFormat
    public let algorithm: SignatureAlgorithm
    public let keyID: String
    public let payload: Data?
    public let signature: Data

    public init(
        format: SignatureEnvelopeFormat,
        algorithm: SignatureAlgorithm,
        keyID: String,
        payload: Data? = nil,
        signature: Data
    ) {
        self.format = format
        self.algorithm = algorithm
        self.keyID = keyID
        self.payload = payload
        self.signature = signature
    }
}

public enum SignatureEnvelopeCodec {
    public static func encode(
        algorithm: SignatureAlgorithm,
        keyID: String,
        signature: Data
    ) -> String {
        "\(algorithm.rawValue):\(keyID):\(Base64URL.encode(signature))"
    }

    public static func decode(_ raw: String) throws -> ParsedSignatureEnvelope {
        let parts = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw SignatureEnvelopeError.invalidFormat
        }

        guard let algorithm = SignatureAlgorithm(rawValue: String(parts[0])) else {
            throw SignatureEnvelopeError.unsupportedAlgorithm(String(parts[0]))
        }

        let keyID = String(parts[1])
        guard !keyID.isEmpty else {
            throw SignatureEnvelopeError.invalidFormat
        }

        guard let signature = Base64URL.decode(String(parts[2])) else {
            throw SignatureEnvelopeError.invalidBase64URL
        }

        return ParsedSignatureEnvelope(
            format: .legacyTriplet,
            algorithm: algorithm,
            keyID: keyID,
            payload: nil,
            signature: signature
        )
    }
}

public enum PaymentSignatureEnvelopeCodec {
    public static func encode(
        format: SignatureEnvelopeFormat,
        algorithm: SignatureAlgorithm,
        keyID: String,
        payload: Data,
        signature: Data
    ) throws -> String {
        switch format {
        case .legacyTriplet:
            return SignatureEnvelopeCodec.encode(
                algorithm: algorithm,
                keyID: keyID,
                signature: signature
            )
        case .coseSign1:
            return try COSESign1EnvelopeCodec.encode(
                algorithm: algorithm,
                keyID: keyID,
                payload: payload,
                signature: signature
            )
        }
    }

    public static func decode(_ raw: String) throws -> ParsedSignatureEnvelope {
        if raw.hasPrefix(COSESign1EnvelopeCodec.compactPrefix) {
            return try COSESign1EnvelopeCodec.decode(raw)
        }
        return try SignatureEnvelopeCodec.decode(raw)
    }
}

public enum COSESign1EnvelopeCodec {
    static let compactPrefix = "cose1:"
    private static let contentType = "application/vnd.dimy.signature.v1"

    public static func encode(
        algorithm: SignatureAlgorithm,
        keyID: String,
        payload: Data,
        signature: Data
    ) throws -> String {
        let algorithmID = try coseAlgorithmID(for: algorithm)
        let protectedMap: [CBORMapKey: CBORValue] = [
            .integer(1): .negativeInt(Int64(-algorithmID)),
            .integer(3): .text(contentType),
            .integer(4): .byteString(Data(keyID.utf8))
        ]
        let protectedBytes = try CBORCodec.encode(.map(protectedMap))
        let envelope = CBORValue.array([
            .byteString(protectedBytes),
            .map([:]),
            .byteString(payload),
            .byteString(signature)
        ])
        let bytes = try CBORCodec.encode(envelope)
        return compactPrefix + Base64URL.encode(bytes)
    }

    public static func decode(_ raw: String) throws -> ParsedSignatureEnvelope {
        guard raw.hasPrefix(compactPrefix) else {
            throw SignatureEnvelopeError.unsupportedFormat(raw)
        }

        let encoded = String(raw.dropFirst(compactPrefix.count))
        guard let bytes = Base64URL.decode(encoded) else {
            throw SignatureEnvelopeError.invalidBase64URL
        }

        let envelope = try CBORCodec.decode(bytes)
        guard case .array(let members) = envelope, members.count == 4,
              case .byteString(let protectedBytes) = members[0],
              case .map = members[1],
              case .byteString(let payload) = members[2],
              case .byteString(let signature) = members[3]
        else {
            throw SignatureEnvelopeError.invalidCOSEEnvelope
        }

        let protectedValue = try CBORCodec.decode(protectedBytes)
        guard case .map(let protectedMap) = protectedValue else {
            throw SignatureEnvelopeError.invalidCOSEEnvelope
        }

        let algorithm = try decodeAlgorithm(from: protectedMap)
        let keyID = try decodeKeyID(from: protectedMap)

        return ParsedSignatureEnvelope(
            format: .coseSign1,
            algorithm: algorithm,
            keyID: keyID,
            payload: payload,
            signature: signature
        )
    }

    private static func decodeAlgorithm(from map: [CBORMapKey: CBORValue]) throws -> SignatureAlgorithm {
        guard let algorithmValue = map[.integer(1)] else {
            throw SignatureEnvelopeError.invalidCOSEEnvelope
        }

        switch algorithmValue {
        case .negativeInt(let value):
            // COSE encodes -19 as major type 1 with argument 18, represented here as -19.
            guard value == -19 else {
                throw SignatureEnvelopeError.unsupportedAlgorithm(String(value))
            }
            return .ed25519
        default:
            throw SignatureEnvelopeError.invalidCOSEEnvelope
        }
    }

    private static func decodeKeyID(from map: [CBORMapKey: CBORValue]) throws -> String {
        guard let keyValue = map[.integer(4)],
              case .byteString(let keyData) = keyValue,
              let keyID = String(data: keyData, encoding: .utf8),
              !keyID.isEmpty
        else {
            throw SignatureEnvelopeError.invalidCOSEEnvelope
        }

        return keyID
    }

    private static func coseAlgorithmID(for algorithm: SignatureAlgorithm) throws -> Int64 {
        switch algorithm {
        case .ed25519:
            return 19
        }
    }
}

public enum CoinSignatureSigner {
    public static func signEd25519(
        coin: Coin,
        keyID: String,
        privateKeySeed: Data,
        envelopeFormat: SignatureEnvelopeFormat = SignatureEnvelopeFeatureFlags.preferredFormat()
    ) throws -> String {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeySeed)
        let payload = try CoinSigningPayloadEncoder.encode(coin: coin)
        let signature = try privateKey.signature(for: payload)
        return try PaymentSignatureEnvelopeCodec.encode(
            format: envelopeFormat,
            algorithm: .ed25519,
            keyID: keyID,
            payload: payload,
            signature: signature
        )
    }
}

public struct MintPublicKeyRegistry: Sendable {
    public let keysByID: [String: Data]

    /// Gjeldende nøkkelkohort per mint-nøkkel.
    ///
    /// En mynt bærer `keyEpoch` fra den ble signert. Er kohorten eldre enn den
    /// gjeldende for nøkkelen, er mynten ugyldiggjort. Det er mekanismen som
    /// lar én utstedelsesrunde annulleres uten å legge ned utstederen.
    ///
    /// Er ingen kohort satt for en nøkkel, håndheves ikke kohort for den —
    /// da oppfører registeret seg som før. Er en kohort satt, kreves den.
    public let currentEpochByKeyID: [String: UInt32]

    public init(keysByID: [String: Data], currentEpochByKeyID: [String: UInt32] = [:]) {
        self.keysByID = keysByID
        self.currentEpochByKeyID = currentEpochByKeyID
    }

    public func publicKeyData(for keyID: String) -> Data? {
        keysByID[keyID]
    }

    public func currentEpoch(for keyID: String) -> UInt32? {
        currentEpochByKeyID[keyID]
    }

    /// Fail-closed: er en kohort konfigurert for nøkkelen, er en mynt uten
    /// kohort å regne som eldste kohort, altså ugyldig. Er ingen kohort
    /// konfigurert, aksepteres alt som ellers verifiserer.
    public func acceptsKeyEpoch(_ keyEpoch: UInt32?, for keyID: String) -> Bool {
        guard let required = currentEpochByKeyID[keyID] else { return true }
        guard let keyEpoch else { return false }
        return keyEpoch >= required
    }
}

public enum DevelopmentMintKeyMaterial {
    public static let keyID = "dev-mint-key-1"
    public static let ed25519PrivateSeedHex = "9d61b19deffd5a60ba844af492ec2cc4" +
        "4449c5697b326919703bac031cae7f60"
    public static let ed25519PublicKeyHex = "d75a980182b10ab7d54bfed3c964073a" +
        "0ee172f3daa62325af021a68f707511a"
}

public extension MintPublicKeyRegistry {
    static let development: MintPublicKeyRegistry = {
        guard let publicKey = HexCodec.decode(DevelopmentMintKeyMaterial.ed25519PublicKeyHex) else {
            return MintPublicKeyRegistry(keysByID: [:])
        }
        return MintPublicKeyRegistry(keysByID: [DevelopmentMintKeyMaterial.keyID: publicKey])
    }()

    /// Builds the authoritative verification registry for runtime wrappers.
    ///
    /// When `DIMY_MINT_PUBLIC_KEYS_JSON` is absent, the bootstrap development
    /// key remains available. When it is present, it must be a JSON object of
    /// key IDs to 32-byte Ed25519 public keys encoded as hex. Invalid configured
    /// input produces an empty registry so verification fails closed.
    static func runtime(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MintPublicKeyRegistry {
        var keys = development.keysByID
        if let configuredValue = environment["DIMY_MINT_PUBLIC_KEYS_JSON"] {
            let raw = configuredValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = raw.data(using: .utf8),
                  let encodedKeys = try? JSONDecoder().decode([String: String].self, from: data),
                  !encodedKeys.isEmpty else {
                return MintPublicKeyRegistry(keysByID: [:])
            }
            keys = [:]
            for (keyID, encodedKey) in encodedKeys {
                guard !keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let keyData = HexCodec.decode(encodedKey), keyData.count == 32 else {
                    return MintPublicKeyRegistry(keysByID: [:])
                }
                keys[keyID] = keyData
            }
        }
        var epochs: [String: UInt32] = [:]
        if let configured = environment["DIMY_MINT_KEY_EPOCHS_JSON"] {
            guard let data = configured.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode([String: UInt32].self, from: data),
                  !parsed.isEmpty, parsed.keys.allSatisfy({ keys[$0] != nil }) else {
                // Invalid or misbound policy must not silently disable retirement.
                return MintPublicKeyRegistry(keysByID: [:])
            }
            epochs = parsed
        }
        return MintPublicKeyRegistry(keysByID: keys, currentEpochByKeyID: epochs)
    }
}

public enum CoinSignatureVerifier {
    /// Er mynten gyldig å bruke nå — signatur **og** nøkkelkohort.
    ///
    /// Kohortkontrollen ligger her, ikke utenfor, slik at hver eneste kaller
    /// arver den: lommeboka, den varige tilstandskontrollen og innløsningen.
    public static func verify(
        coin: Coin,
        using registry: MintPublicKeyRegistry,
        acceptedFormats: Set<SignatureEnvelopeFormat> = SignatureEnvelopeFeatureFlags.acceptedFormats()
    ) -> Bool {
        guard registry.acceptsKeyEpoch(coin.keyEpoch, for: coin.mintKeyID) else {
            return false
        }
        return verifySignatureOnly(coin: coin, using: registry, acceptedFormats: acceptedFormats)
    }

    /// Bare signaturen, uten kohortpolicy.
    ///
    /// Finnes for å kunne skille to helt ulike ting fra hverandre: en mynt som
    /// er *forfalsket*, og en mynt som er ekte men *utgått*. Den første er
    /// korrupsjon og skal stoppe innlesing; den andre er policy og skal føre
    /// mynten i karantene, ikke slette den.
    public static func verifySignatureOnly(
        coin: Coin,
        using registry: MintPublicKeyRegistry,
        acceptedFormats: Set<SignatureEnvelopeFormat> = SignatureEnvelopeFeatureFlags.acceptedFormats()
    ) -> Bool {
        guard let keyData = registry.publicKeyData(for: coin.mintKeyID),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let envelope = try? PaymentSignatureEnvelopeCodec.decode(coin.signature),
              acceptedFormats.contains(envelope.format),
              envelope.algorithm == .ed25519,
              envelope.keyID == coin.mintKeyID,
              let payload = try? CoinSigningPayloadEncoder.encode(coin: coin)
        else {
            return false
        }

        if let embeddedPayload = envelope.payload, embeddedPayload != payload {
            return false
        }

        return publicKey.isValidSignature(envelope.signature, for: payload)
    }
}

public enum SpendReceiptSignatureVerifier {
    public static func verify(
        receipt: SpendReceipt,
        using registry: MintPublicKeyRegistry,
        acceptedFormats: Set<SignatureEnvelopeFormat> = SignatureEnvelopeFeatureFlags.acceptedFormats()
    ) -> Bool {
        guard let keyData = registry.publicKeyData(for: receipt.mintKeyID),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let envelope = try? PaymentSignatureEnvelopeCodec.decode(receipt.signature),
              acceptedFormats.contains(envelope.format),
              envelope.algorithm == .ed25519,
              envelope.keyID == receipt.mintKeyID,
              let payload = try? SpendReceiptSigningPayloadEncoder.encode(receipt: receipt)
        else {
            return false
        }

        if let embeddedPayload = envelope.payload, embeddedPayload != payload {
            return false
        }

        return publicKey.isValidSignature(envelope.signature, for: payload)
    }
}

public enum SpendReceiptSignatureSigner {
    public static func signEd25519(
        receipt: SpendReceipt,
        keyID: String,
        privateKeySeed: Data,
        envelopeFormat: SignatureEnvelopeFormat = SignatureEnvelopeFeatureFlags.preferredFormat()
    ) throws -> String {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeySeed)
        let payload = try SpendReceiptSigningPayloadEncoder.encode(receipt: receipt)
        let signature = try privateKey.signature(for: payload)
        return try PaymentSignatureEnvelopeCodec.encode(
            format: envelopeFormat,
            algorithm: .ed25519,
            keyID: keyID,
            payload: payload,
            signature: signature
        )
    }
}

public enum CoinSigningPayloadEncoder {
    public static func encode(coin: Coin) throws -> Data {
        let payload = CoinSigningPayload(
            version: 1,
            denomMinorUnits: coin.denomMinorUnits,
            serial: coin.serial,
            mintKeyID: coin.mintKeyID,
            keyEpoch: coin.keyEpoch
        )
        return try CanonicalEncoding.encode(payload)
    }
}

public enum SpendReceiptSigningPayloadEncoder {
    public static func encode(receipt: SpendReceipt) throws -> Data {
        let payload = SpendReceiptSigningPayload(
            version: 1,
            bundleHash: receipt.bundleHash,
            merchantCreditRef: receipt.merchantCreditRef,
            merchantID: receipt.merchantID,
            mintKeyID: receipt.mintKeyID,
            keyEpoch: receipt.keyEpoch,
            issuedAtMS: receipt.issuedAt.epochMilliseconds
        )
        return try CanonicalEncoding.encode(payload)
    }
}

public enum HexCodec {
    public static func decode(_ hex: String) -> Data? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count.isMultiple(of: 2) else {
            return nil
        }

        var data = Data()
        data.reserveCapacity(cleaned.count / 2)

        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        return data
    }
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ raw: String) -> Data? {
        var normalized = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = normalized.count % 4
        if padding != 0 {
            normalized.append(String(repeating: "=", count: 4 - padding))
        }

        return Data(base64Encoded: normalized)
    }
}

private enum CBORMapKey: Hashable, Comparable {
    case integer(UInt64)

    var integerValue: UInt64 {
        switch self {
        case .integer(let value):
            return value
        }
    }

    static func < (lhs: CBORMapKey, rhs: CBORMapKey) -> Bool {
        lhs.integerValue < rhs.integerValue
    }
}

private enum CBORValue: Hashable {
    case unsignedInt(UInt64)
    case negativeInt(Int64)
    case byteString(Data)
    case text(String)
    case array([CBORValue])
    case map([CBORMapKey: CBORValue])
    case null
}

private enum CBORCodec {
    static func encode(_ value: CBORValue) throws -> Data {
        var out = Data()
        try append(value: value, to: &out)
        return out
    }

    static func decode(_ data: Data) throws -> CBORValue {
        var index = data.startIndex
        let value = try readValue(from: data, index: &index)
        guard index == data.endIndex else {
            throw SignatureEnvelopeError.invalidCOSEEnvelope
        }
        return value
    }

    private static func append(value: CBORValue, to out: inout Data) throws {
        switch value {
        case .unsignedInt(let value):
            appendUnsigned(majorType: 0, value: value, to: &out)
        case .negativeInt(let value):
            guard value < 0 else {
                throw SignatureEnvelopeError.invalidCOSEEnvelope
            }
            let magnitude = UInt64((-1) - value)
            appendUnsigned(majorType: 1, value: magnitude, to: &out)
        case .byteString(let bytes):
            appendUnsigned(majorType: 2, value: UInt64(bytes.count), to: &out)
            out.append(bytes)
        case .text(let text):
            let utf8 = Data(text.utf8)
            appendUnsigned(majorType: 3, value: UInt64(utf8.count), to: &out)
            out.append(utf8)
        case .array(let members):
            appendUnsigned(majorType: 4, value: UInt64(members.count), to: &out)
            for member in members {
                try append(value: member, to: &out)
            }
        case .map(let map):
            appendUnsigned(majorType: 5, value: UInt64(map.count), to: &out)
            for (key, member) in map.sorted(by: { $0.key < $1.key }) {
                appendUnsigned(majorType: 0, value: key.integerValue, to: &out)
                try append(value: member, to: &out)
            }
        case .null:
            out.append(0xf6)
        }
    }

    private static func appendUnsigned(majorType: UInt8, value: UInt64, to out: inout Data) {
        switch value {
        case 0...23:
            out.append((majorType << 5) | UInt8(value))
        case 24...0xff:
            out.append((majorType << 5) | 24)
            out.append(UInt8(value))
        case 0x100...0xffff:
            out.append((majorType << 5) | 25)
            out.append(contentsOf: UInt16(value).bigEndian.bytes)
        case 0x1_0000...0xffff_ffff:
            out.append((majorType << 5) | 26)
            out.append(contentsOf: UInt32(value).bigEndian.bytes)
        default:
            out.append((majorType << 5) | 27)
            out.append(contentsOf: value.bigEndian.bytes)
        }
    }

    private static func readValue(from data: Data, index: inout Data.Index) throws -> CBORValue {
        guard index < data.endIndex else {
            throw SignatureEnvelopeError.invalidCOSEEnvelope
        }

        let initial = data[index]
        data.formIndex(after: &index)
        let majorType = initial >> 5
        let additional = initial & 0x1f
        let length = try readLength(additional: additional, from: data, index: &index)

        switch majorType {
        case 0:
            return .unsignedInt(length)
        case 1:
            let signed = Int64(-1) - Int64(length)
            return .negativeInt(signed)
        case 2:
            let bytes = try readData(count: length, from: data, index: &index)
            return .byteString(bytes)
        case 3:
            let bytes = try readData(count: length, from: data, index: &index)
            guard let text = String(data: bytes, encoding: .utf8) else {
                throw SignatureEnvelopeError.invalidCOSEEnvelope
            }
            return .text(text)
        case 4:
            var items: [CBORValue] = []
            items.reserveCapacity(Int(length))
            for _ in 0..<length {
                items.append(try readValue(from: data, index: &index))
            }
            return .array(items)
        case 5:
            var result: [CBORMapKey: CBORValue] = [:]
            result.reserveCapacity(Int(length))
            for _ in 0..<length {
                let keyValue = try readValue(from: data, index: &index)
                guard case .unsignedInt(let keyInt) = keyValue else {
                    throw SignatureEnvelopeError.invalidCOSEEnvelope
                }
                let member = try readValue(from: data, index: &index)
                result[.integer(keyInt)] = member
            }
            return .map(result)
        case 7:
            guard initial == 0xf6 else {
                throw SignatureEnvelopeError.invalidCOSEEnvelope
            }
            return .null
        default:
            throw SignatureEnvelopeError.invalidCOSEEnvelope
        }
    }

    private static func readLength(
        additional: UInt8,
        from data: Data,
        index: inout Data.Index
    ) throws -> UInt64 {
        switch additional {
        case 0...23:
            return UInt64(additional)
        case 24:
            let bytes = try readData(count: 1, from: data, index: &index)
            return UInt64(bytes[bytes.startIndex])
        case 25:
            let bytes = try readData(count: 2, from: data, index: &index)
            return UInt64(UInt16(bigEndianBytes: bytes))
        case 26:
            let bytes = try readData(count: 4, from: data, index: &index)
            return UInt64(UInt32(bigEndianBytes: bytes))
        case 27:
            let bytes = try readData(count: 8, from: data, index: &index)
            return UInt64(bigEndianBytes: bytes)
        default:
            throw SignatureEnvelopeError.invalidCOSEEnvelope
        }
    }

    private static func readData(
        count: UInt64,
        from data: Data,
        index: inout Data.Index
    ) throws -> Data {
        let intCount = Int(count)
        guard intCount >= 0,
              data.distance(from: index, to: data.endIndex) >= intCount
        else {
            throw SignatureEnvelopeError.invalidCOSEEnvelope
        }
        let next = data.index(index, offsetBy: intCount)
        let slice = data[index..<next]
        index = next
        return Data(slice)
    }
}

private extension UInt16 {
    var bytes: [UInt8] {
        [
            UInt8((self >> 8) & 0xff),
            UInt8(self & 0xff)
        ]
    }

    init(bigEndianBytes data: Data) {
        self = data.reduce(0) { ($0 << 8) | UInt16($1) }
    }
}

private extension UInt32 {
    var bytes: [UInt8] {
        [
            UInt8((self >> 24) & 0xff),
            UInt8((self >> 16) & 0xff),
            UInt8((self >> 8) & 0xff),
            UInt8(self & 0xff)
        ]
    }

    init(bigEndianBytes data: Data) {
        self = data.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

private extension UInt64 {
    var bytes: [UInt8] {
        [
            UInt8((self >> 56) & 0xff),
            UInt8((self >> 48) & 0xff),
            UInt8((self >> 40) & 0xff),
            UInt8((self >> 32) & 0xff),
            UInt8((self >> 24) & 0xff),
            UInt8((self >> 16) & 0xff),
            UInt8((self >> 8) & 0xff),
            UInt8(self & 0xff)
        ]
    }

    init(bigEndianBytes data: Data) {
        self = data.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

private enum CanonicalEncoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

private struct CanonicalSpendBundle: Codable, Hashable, Sendable {
    let version: UInt8
    let requestID: String
    let resourceID: String
    let createdAtMS: UInt64
    let coins: [CanonicalSpendCoin]
}

private struct CanonicalSpendCoin: Codable, Hashable, Sendable {
    let denomMinorUnits: UInt64
    let serial: String
    let mintKeyID: String
    let keyEpoch: UInt32?
    let signature: String
}

private struct CoinSigningPayload: Codable, Hashable, Sendable {
    let version: UInt8
    let denomMinorUnits: UInt64
    let serial: String
    let mintKeyID: String
    let keyEpoch: UInt32?
}

private struct SpendReceiptSigningPayload: Codable, Hashable, Sendable {
    let version: UInt8
    let bundleHash: String
    let merchantCreditRef: String
    let merchantID: String
    let mintKeyID: String
    let keyEpoch: UInt32?
    let issuedAtMS: UInt64
}

private extension Date {
    var epochMilliseconds: UInt64 {
        UInt64((timeIntervalSince1970 * 1000.0).rounded(.down))
    }
}
