# Web sharing deployment repair — 2026-09-15

## Cause

Installed clients called the correct `/v1/shares/<UUID>` route, but the production `note-taker-sync` Worker was still the September 9 version, `5accd5e0-7557-42a0-ac7f-83f673179d6f`. The web-sharing server change had been committed without deployment. Authenticated health returned 200 while the sharing route returned the exact reported 404. The remote migration list also showed `0006_web_shares.sql` pending.

## Repair

- Applied only the pending, additive `0006_web_shares.sql` migration.
- Deployed the current Worker with the existing D1 database, private R2 bucket, and sync-token secret preserved.
- Active Worker version: `f81b20dc-8ca8-45e0-aee9-fb3d31373bf0`.
- No app binary change or reinstall is required for this repair.

## Verification

- Server tests: 76 passed, 0 failed.
- Wrangler deployment dry run and production deployment succeeded.
- Live checks: health, inactive share status, management authentication, creation, seven-day expiry, unauthenticated HTML reading, active status, replacement, old-link invalidation, replacement-link reading, revocation, revoked-link 404, and inactive status all passed.
- The live check used a generated source UUID and synthetic text. Its link was revoked after verification.
- Reopened the installed Mac app's sharing sheet: the status loaded normally, the create-link button was enabled, and the 404 error was absent.

The live HTTP checks exercise the common server contract. Windows and iPhone share creation were not separately driven through their UIs during this repair.
