# DiMyMicropayments

Reusable Swift payment contracts, wallet/access actors and CellProtocol adapters
maintained by Digipomps as part of HAVEN.

## Modules

- `DiMyPaymentTypes`: issue/spend/redeem contracts, signatures and accounting projections.
- `DiMyMintClient`: mint protocols, HTTP client and in-memory development mint.
- `DiMyWalletCell`: issuer-bound inventory, spend selection and rollback.
- `DiMyAccessCell`: signature verification, replay checks and online redemption.
- `DiMyCellProtocolCells`: runtime wallet, access, pricing and projection cells.
- `DiMyMicropayments`: facade and compatibility aliases.

## Install

Requires Swift 5.9 or later, macOS 13 or iOS 16 or later.

```swift
.package(url: "https://github.com/Digipomps/DiMyMicropayments.git",
         .upToNextMinor(from: "2026.10.1"))
```

## Local development example

```swift
import DiMyMintClient
import DiMyWalletCell
import DiMyAccessCell

let mint = InMemoryMintClient()
let wallet = WalletCell(mintClient: mint)
let access = AccessCell(merchantID: "merchant.demo", mintClient: mint)
_ = try await wallet.issue(amountMinorUnits: 37, strategy: .oneTwoFive)
let bundle = try await wallet.spend(priceMinorUnits: 12, resourceID: "cell://demo/article-1")
let grant = try await access.verifyAndRedeem(bundle: bundle)
print(grant.receiptHash)
```

The example uses public development key material and creates no real payment.
For a separate server implementation, see
[DiMyMint](https://github.com/Digipomps/DiMyMint).

## Status and safety boundaries

This is a development/integration implementation, not a production payment
service or regulatory approval. Online flow, signature verification and replay
checks exist. The blind adapter is a development placeholder. Key custody,
rotation procedures and production cryptographic contracts require further
review. Public development private seeds in this package are test fixtures;
they must never be trusted for production issuance.

A deployment must enforce its accepted issuer keys on the server. Do not rely on
a key name or on a client-selected allowlist as authority. Some lower-level APIs
have development defaults; production configuration must explicitly replace them.

## Test and technical documentation

```sh
swift test --disable-automatic-resolution --jobs 2
```

- [Architecture](docs/architecture.md)
- [API reference](docs/api-reference.md) (selected public API; source is authoritative)
- [Runtime configuration](docs/operations.md)
- [Wire schemas and vectors](docs/examples/payment_objects_alignment.md)
- [Signature envelope profile](schemas/cose/cose_profiles.md)

Version `2026.10.1` starts this public repository's release line. Applications
should review and lock their dependency graph before deployment.

## License and official services

The source code and technical documentation in this repository, including its
DiMy modules, are licensed under Apache License 2.0. See [LICENSE](LICENSE) and
[NOTICE](NOTICE). Digipomps maintains this repository as part of HAVEN.
[GOVERNANCE.md](GOVERNANCE.md) describes official releases;
[TRADEMARK.md](TRADEMARK.md) covers names and certification marks. Those policies
do not add restrictions to the Apache code license. The license does not grant
access to official hosted services or private signing keys, or authority to
issue value accepted by DiMy. Dependencies retain their own license terms.
