# Payment object alignment (bounded schema pass)

Dette dokumentet binder CDDL-labels til canonical payload-vektorer.

## PaymentEvent.v1
- Schema: `schemas/cddl/payment_event_v1.cddl`
- Vector file: `Tests/vectors/payment_event_v1.payload.hex`
- Labels:
  - `0=v`
  - `1=event_id`
  - `2=psp_id`
  - `3=psp_event_ref`
  - `4=occurred_at_ms`
  - `5=received_at_ms`
  - `6=value_units`
  - `7=currency`
  - `8=identity_domain`
  - `9=commons_keypath`

## Token.v1
- Schema: `schemas/cddl/token_v1.cddl`
- Vector file: `Tests/vectors/token_v1.payload.hex`
- Labels:
  - `0=v`
  - `1=token_id`
  - `2=mint_id`
  - `3=value_units`
  - `4=currency`
  - `5=scope_keypath`
  - `6=owner_binding`
  - `7=expires_at_ms`

## Spend.v1
- Schema: `schemas/cddl/spend_v1.cddl`
- Vector file: `Tests/vectors/spend_v1.payload.hex`
- Labels:
  - `0=v`
  - `1=spend_id`
  - `2=token_ids`
  - `3=value_units`
  - `4=currency`
  - `5=payee`
  - `6=created_at_ms`
  - `7=nonce`

## RedeemReceipt.v1
- Schema: `schemas/cddl/redeem_receipt_v1.cddl`
- Vector file: `Tests/vectors/redeem_receipt_v1.payload.hex`
- Labels:
  - `0=v`
  - `1=receipt_id`
  - `2=spend_id`
  - `3=status`
  - `4=value_units`
  - `5=currency`
  - `6=redeemed_at_ms`
  - `7=audit_epoch`

## Canonical payload hex
- PaymentEvent.v1:
  `aa00010150000102030405060708090a0b0c0d0e0f02677073705f666f6f03686576745f30303031041b00000192cc09147b051b00000192cc0915c80618c707634e4f4b087169642d646f6d61696e3a6578616d706c650974636f6d6d6f6e733a7376632f7061796d656e7473`
- Token.v1:
  `a800010150101112131415161718191a1b1c1d1e1f0250202122232425262728292a2b2c2d2e2f0319138804634e4f4b0574636f6d6d6f6e733a7376632f7061796d656e7473065820a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0071b000001952014f418`
- Spend.v1:
  `a800010150303132333435363738393a3b3c3d3e3f028150101112131415161718191a1b1c1d1e1f0319138804634e4f4b05781a70617965653a636f6d6d6f6e733a7376632f7061796d656e7473061b00000192cc0917e70750404142434445464748494a4b4c4d4e4f`
- RedeemReceipt.v1:
  `a800010150505152535455565758595a5b5c5d5e5f0250303132333435363738393a3b3c3d3e3f03000419138805634e4f4b061b00000192cc091bcf07182a`
