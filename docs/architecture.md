# Architecture

WalletCell prepares issue requests, stores an issuer's coins and constructs
exact-amount spend bundles. MintClient abstracts issuance and redemption; its
in-memory implementation is for development, while HTTPMintClient calls an
external mint. AccessCell verifies signatures, the bundle hash, issuer policy,
replay state and the returned receipt before producing an AccessGrant.

Wallet inventory belongs to the wallet actor. Access receipt/replay state belongs
to the access actor. Runtime wrappers persist wallet state and expose actions
through CellProtocol. Global redemption authority belongs to the mint backend.
The client library alone does not establish a durable production spent set.

A bundle must identify one issuer. Verification requires an accepted public key
and a valid signature, in addition to any deployment issuer allowlist. Key epochs
support policy changes; old persisted coins can be quarantined without being
silently credited back. Inspect the runtime migration code and tests before
changing an issuer's keys or epoch policy.

The development blind adapter sends a serial-prefixed placeholder, not a
production blind-signature construction. Ed25519 verification is implemented;
production key management and a reviewed cryptographic profile remain the
operator's responsibility. See the signature-envelope profile for its limits.
