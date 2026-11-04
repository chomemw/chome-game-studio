# Fruit Fancy CHOX anti-cheat status

## Current protection

The old reward RPC accepted `p_score`, `p_stage`, and `p_extra_time_used` directly from the browser. The game board and scoring were also generated in browser JavaScript. That means a modified client could claim halfway/completion rewards without proving the moves happened.

The database function `private.claim_fruit_fancy_chox` is now fail-closed and returns zero newly awarded CHOX. The public wrapper therefore cannot credit rewards using browser-reported values. The Fruit Fancy page no longer calls the reward-credit RPC and displays a clear pause notice. Gameplay, sign-in, and cloud saves remain available.

**Do not enable USDT payouts or advertise Fruit Fancy CHOX as cash-redeemable while this protection is in place.** Existing CHOX balances and the payout foundation are unchanged.

## Work still required for real server-authoritative rewards

A secure implementation must not trust a final score posted by the browser. It needs:

1. A server-created game session bound to `auth.uid()`, a server-generated random seed, game/version identifier, level, start time, expiry, and one-time session state.
2. A deterministic game engine shared with the server: seeded board generation, deterministic refill/shuffle, ice/bomb rules, score calculation, target thresholds, and timer rules. All gameplay randomness must derive from the server-issued seed.
3. A move stream: the client submits each selected tile path in order with a monotonically increasing move number. The server validates adjacency, matching fruit, ice/bomb rules, and replays each move against the authoritative board. The client must not submit a trusted score or reward amount.
4. Server-side halfway and completion milestones derived from replayed score and server time. Extra-time bonuses must be derived from validated session state, not a browser counter.
5. Idempotency: each session and milestone can credit once; duplicate/replayed requests return the existing result and never add CHOX twice.
6. Abuse controls: per-user active-session limits, rate limits, impossible move/time detection, session expiry, and an auditable verification result.
7. Automated tests covering altered scores, skipped moves, repeated claims, stale sessions, changed board state, invalid paths, impossible timing, and reconnect/cloud-save behavior.

## Current leaderboard limitation

The existing leaderboard RPC also accepts a score submitted by the browser. Those scores are not independently verified and must not be used to determine CHOX, prizes, or cash payouts until the same replay verifier is used.

## Payout safety

The CHOX payout switch remains disabled. Keep it disabled until verified game sessions are live, security checks pass, the treasury and payout operations are ready, and a small end-to-end payout test succeeds.
