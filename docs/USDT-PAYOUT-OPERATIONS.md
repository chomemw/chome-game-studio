# CHOME USDT Payout Operations

## Current state

- Network configured for player receiving addresses: TRON USDT (TRC20).
- CHOX conversion setting currently stored in Supabase: 20,000 CHOX = 1 USDT.
- Player dashboard allows a signed-in player to save one receiving address.
- Payout requests are deliberately disabled: `private.reward_settings.payouts_enabled = false`.
- No private keys, seed phrases, wallet-provider credentials, or paid API credentials are stored in the app.
- A submitted payout request, when the programme is enabled, reserves CHOX and enters a pending queue. It does not send USDT automatically.

## Why payouts are disabled

Do not enable cash redemptions until all of the following are complete:

1. Server-side game-score validation and anti-cheat controls are implemented. Current Fruit Fancy reward claims include client-reported score data, which is not sufficient proof for cash rewards.
2. CHOME has obtained appropriate legal advice for the countries where cash prizes/redemptions will be offered.
3. The treasury wallet is funded and the operator has budgeted TRX for TRON Energy/Bandwidth or delegated Energy.
4. Testnet and small-value mainnet payout tests have been completed.
5. The minimum redemption amount, fees (if any), payout timing, and dispute rules have been published.

## Admin review workflow (only after launch approval)

Inspect pending requests in the Supabase SQL Editor:

```sql
select id, user_id, points_amount, usd_amount, network,
       destination_address, created_at
from private.payout_requests
where status = 'pending'
order by created_at asc;
```

Before sending, check the treasury's available USDT and TRX resources. Send the exact USDT amount to the saved destination using a CHOME-controlled wallet. Verify the confirmed transaction on an independent TRON explorer and confirm the token contract, network, amount, and destination.

After successful confirmation, mark the request paid:

```sql
select private.admin_mark_usdt_payout_paid(
  '<payout-request-uuid>',
  '<64-character-transaction-hash>',
  'Verified on TRON explorer'
);
```

If a request must be rejected, return the reserved CHOX using the protected reversal function:

```sql
select private.admin_reject_usdt_payout(
  '<payout-request-uuid>',
  'Explain the reason to the player'
);
```

The rejection function restores the reserved CHOX and writes a reversal entry to the reward ledger.

## Security rules

- Never put a treasury private key or seed phrase in GitHub, browser code, chat, or a public Supabase table.
- Never expose Supabase secret/service-role keys in the browser.
- Never mark a request paid before the matching on-chain transaction is confirmed.
- Never reuse a transaction hash for two payout requests.
- Keep the treasury reserve separate from the operational hot wallet.
- The player-provided address is a receiving destination, not a unique CHOME deposit address. Players must verify the address and TRC20 network themselves.
- Keep cash payouts disabled until all launch gates above are complete.
