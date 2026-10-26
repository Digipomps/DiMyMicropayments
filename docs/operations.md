# Runtime configuration

Runtime wrappers use these environment variables:

| Variable | Role |
|---|---|
| `DIMY_MINT_BASE_URL` | External mint URL; absence selects the in-memory development mint. |
| `DIMY_MINT_INTERNAL_TOKEN` | Optional `X-DiMy-Mint-Token` HTTP header. The receiving service must independently enforce authorization. |
| `DIMY_MINT_KEY_ID` | Wallet issuer key ID and access-policy fallback. |
| `DIMY_MINT_PUBLIC_KEYS_JSON` | Authoritative JSON object of key IDs to 32-byte Ed25519 public keys encoded as hex. |
| `DIMY_MINT_KEY_EPOCHS_JSON` | Minimum accepted unsigned epoch by known key ID. |
| `DIMY_ACCEPTED_MINT_KEY_IDS_JSON` | Runtime merchant issuer allowlist, a JSON array of nonempty IDs. |
| `DIMY_SIGNATURE_ENVELOPE_FORMAT` | `legacy_triplet` or experimental `cose_sign1`. |
| `DIMY_WALLET_INSTANCE_ID` | Optional wallet instance identifier. |
| `DIMY_MERCHANT_ID` | Runtime merchant identifier. |

Malformed explicit key/issuer policies fail closed. With no public-key
configuration, the registry retains the development key. An absent runtime
issuer policy rejects all issuers when `VAPOR_ENV` is `production` or `staging`;
other environments retain development behavior. These defaults are not a
production startup gate. Explicitly configure real keys and accepted issuers and
verify rejection of development keys, foreign keys and invalid configuration.

The generic HTTP client expects POST `/issue` and `/redeem` with JSON and ISO-8601
dates. The reference DiMyMint server currently leaves legacy monetary routes
unexposed by default; configuring a client URL does not enable those routes.
Do not expose or deploy a mint without its own reviewed authorization, key
custody, persistence and product/regulatory decisions.

Run `swift test --disable-automatic-resolution --jobs 2` on the committed lockfile.
Consumer applications must test their selected dependency graph independently.
