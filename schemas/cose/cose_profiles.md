# COSE-profil (bounded pass)

## Formål
Dette dokumentet beskriver overgangsprofilen for signatur-envelope i `DiMyMicropayments`.

## Aktiv profil i kode (2026-02-25)
- `legacy_triplet`: `alg:kid:base64url(signature)`
- `cose_sign1`: kompakt streng med prefix `cose1:` og Base64URL(CBOR COSE_Sign1)

## Feature flag
- Miljøvariabel: `DIMY_SIGNATURE_ENVELOPE_FORMAT`
- Verdier:
  - `legacy_triplet` (default)
  - `cose_sign1`

## Verifiseringspolitikk
- Når `legacy_triplet` er valgt: verifiser bare `legacy_triplet`.
- Når `cose_sign1` er valgt: verifiser `cose_sign1` + `legacy_triplet` (migreringsmodus).

## COSE_Sign1 felter i bounded implementasjon
- Struktur: `[protected, unprotected, payload, signature]`
- `protected` inneholder:
  - `1` (`alg`) = `-19` (Ed25519)
  - `3` (`content type`) = `application/vnd.dimy.signature.v1`
  - `4` (`kid`) = UTF-8 bytes av `mintKeyID`
- `unprotected` = tom map
- `payload` = canonical signeringspayload bytes
- `signature` = Ed25519 signatur bytes

## Begrensninger (bevisst i denne fasen)
- Dette er kompatibilitetslag, ikke full COSE/CBOR standard-implementasjon.
- `CBOR` dekoder støtter kun delmengden som trengs for denne envelope-typen.
- Full RFC-alignment må fullføres i neste iterasjon med test-vektorer og golden replay.
