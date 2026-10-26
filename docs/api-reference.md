# API Reference

This document summarizes the public API exposed by each package module.

## `DiMyPaymentTypes`

### Value types

- `Coin`
  - `denomMinorUnits: UInt64`
  - `serial: String`
  - `mintKeyID: String`
  - `keyEpoch: UInt32?`
  - `signature: String`

- `BlindedCoinRequest`
- `BlindSignature`
  - `keyEpoch: UInt32?`
- `IssueRequest`
- `IssueResponse`
- `SpendBundle`
  - computed `totalMinorUnits`
- `RedeemRequest`
- `SpendReceipt`
  - `keyEpoch: UInt32?`
- `RedeemResponse`
  - static helpers: `accepted(_:)`, `rejected(_:)`
- `AccessGrant`

- Crypto helpers
  - `SignatureAlgorithm`
  - `SignatureEnvelopeFormat`
  - `SignatureEnvelopeFeatureFlags`
  - `SignatureEnvelopeCodec`
  - `PaymentSignatureEnvelopeCodec`
  - `COSESign1EnvelopeCodec`
  - `CoinSigningPayloadEncoder`
  - `CoinSignatureSigner`
  - `CoinSignatureVerifier`
  - `SpendReceiptSigningPayloadEncoder`
  - `SpendReceiptSignatureSigner`
  - `SpendReceiptSignatureVerifier`
  - `MintPublicKeyRegistry`
  - `DevelopmentMintKeyMaterial`
  - `HexCodec`
  - `Base64URL`

### Enums

- `RedeemRejectionReason`
  - `.doubleSpend`
  - `.invalidBundleHash`
  - `.invalidCoinSignature`
  - `.unknown`

- `DenominationStrategy`
  - `.oneTwoFive`
  - `.unit` for exact variable-price micropayments
  - `.powersOfTwo`
  - `split(amountMinorUnits:) -> [UInt64]`

- `BundleHasher`
  - `hash(bundle:) throws -> String`

## `DiMyMintClient`

### Protocols

- `MintIssuingClient`
  - `issue(_:) async throws -> IssueResponse`
- `MintRedeemingClient`
  - `redeem(_:) async throws -> RedeemResponse`
- `MintClient = MintIssuingClient & MintRedeemingClient`

### Types

- `MintClientError`
  - `.invalidResponse`
  - `.invalidIssueRequest`
  - `.unsupportedMintKey(_:)`
  - `.signingFailed`
  - `.notImplemented`

- `MintClientEnvironment`
  - `defaultBaseURL(from:) -> URL?`

- `MintClientRegistry` (actor)
  - `shared`
  - `setFactory(_:)`
  - `makeClient()`
  - `useEnvironmentDefault()`

- `InMemoryMintClient` (actor, dev/test client)
  - `init(signingKeyID:signingKeyEpoch:envelopeFormat:verificationRegistry:)`
  - `issue(_:)`
  - `redeem(_:)`

- `HTTPMintClient` (actor, network client)
  - `init(baseURL:session:)`
  - `issue(_:)`
  - `redeem(_:)`

## `DiMyWalletCell`

### Error type

- `WalletCellError`
  - `.unsupportedAmount(UInt64)`
  - `.insufficientBalance(required:available:)`
  - `.unableToCreateExactChange(UInt64)`
  - `.issueMismatch`

### Blind signature adaptation

- `BlindSignatureAdapting`
  - `prepareIssueRequest(...) throws -> PreparedIssueRequest`
  - `finalizeIssuedCoins(...) throws -> [Coin]`

- `DevelopmentBlindSignatureAdapter`
  - default development implementation

### Wallet actor

- `WalletCell`
  - `init(walletInstanceID:mintKeyID:mintClient:blindAdapter:)`
  - `issue(amountMinorUnits:strategy:) async throws -> [Coin]`
  - `spend(priceMinorUnits:resourceID:) throws -> SpendBundle`
  - `rollback(bundle:)`
  - `deposit(_:)`
  - `balanceMinorUnits() -> UInt64`
  - `coinInventory() -> [Coin]`

## `DiMyAccessCell`

### Error type

- `AccessCellError`
  - `.invalidCoinSignature(serial:)`
  - `.invalidReceiptSignature`
  - `.replayedBundle`
  - `.missingReceipt`
  - `.mismatchedBundleHash`
  - `.redemptionRejected(RedeemRejectionReason)`

### Verification abstraction

- `CoinVerifying`
  - `verify(_:) -> Bool`
  - `verify(_ receipt:) -> Bool`
- `DevelopmentCoinVerifier`
  - development Ed25519 signature validation against `MintPublicKeyRegistry.development`

### Access actor

- `AccessCell`
  - `init(merchantID:mintClient:verifier:)`
  - `verifyAndRedeem(bundle:) async throws -> AccessGrant`
  - `receipt(bundleHash:) -> SpendReceipt?`

## `DiMyCellProtocolCells`

### Registration

- `DiMyCellRuntimeRegistration`
  - `registerScaffoldCells(resolver:identityDomain:)`
  - `registerBindingCells(resolver:identityDomain:)`
  - `registerDefaultCells(resolver:identityDomain:walletScope:accessScope:pricingScope:persistency:)`

### Runtime cells

- `DiMyWalletRuntimeCell` (`GeneralCell`)
- `DiMyAccessRuntimeCell` (`GeneralCell`)
- `DiMyPricingPolicyCell` (`GeneralCell`)

### Runtime key surface

#### `DiMyWalletRuntimeCell`

- `GET state` -> wallet summary object
- `SET issue` payload:
  - `{ "amountMinorUnits": UInt64, "strategy": "oneTwoFive" | "powersOfTwo"? }`
- `SET spend` payload:
  - `{ "priceMinorUnits": UInt64, "resourceID": String }`
- `SET rollback` payload:
  - `{ "requestID": UUID }` or `{ "bundle": SpendBundle }` or direct `SpendBundle`
- `SET depositCoins` payload:
  - `[Coin]`

#### `DiMyAccessRuntimeCell`

- `GET state`
- `GET merchantID`
- `SET merchantID` payload:
  - `"merchant-id"` or `{ "value": "merchant-id" }`
- `SET verifyAndRedeem` payload:
  - `SpendBundle` or `{ "bundle": SpendBundle }`
- `SET receipt` payload:
  - `{ "bundleHash": String }` or direct hash string

#### `DiMyPricingPolicyCell`

- `GET state`
- `SET setPrice` payload:
  - `{ "resourceID": String, "priceMinorUnits": UInt64 }`
- `SET removePrice` payload:
  - `{ "resourceID": String }`
- `SET quote` payload:
  - `{ "resourceID": String, "defaultPriceMinorUnits": UInt64? }`

## `DiMyMicropayments`

- `DiMyMicropaymentsBootstrap.version`
- Typealiases:
  - `MicropaymentWalletCell`
  - `MicropaymentAccessCell`
  - `MicropaymentMintClient`
  - `MicropaymentRuntimeRegistration`
