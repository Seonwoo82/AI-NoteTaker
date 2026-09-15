# Meeting notes web sharing

## Scope and authorization
Implement the user-requested web sharing on Mac, iPhone and Windows using existing Cloudflare Workers, D1 and private R2. The prior feasibility proposal and explicit implementation request authorize this work. No new service or dependency. Existing personal deployment credentials remain the administrative trust boundary; this is not a multi-tenant account system.

## User experience
A completed meeting note offers Web Share. Explain that anyone with the link can read the minutes, the snapshot expires after 7 days, and creating a new link disables the previous one. Only the title and minutes markdown are uploaded, never audio or full transcript. Show progress, copy/open/share link, expiry, errors and revoke. Revocation remains available after relaunch/on another device through authenticated status lookup. The link is displayed only on its creation device/session; other devices can revoke or replace it. A meeting edit does not silently change a published snapshot.

Mac/iOS reuse SyncSettings endpoint and token without requiring synchronization enabled. Windows adds HTTPS sharing server URL and a DPAPI-protected sync token, independent from OpenRouter. No production secret is embedded. New users must be configured with their personal deployment credentials; the UI explains missing configuration.

## Wire contract (shared by all platforms)
All administrative calls use Authorization: Bearer <SYNC_TOKEN>. sourceID is a canonical uppercase UUID for the recording, accepted case-insensitively then normalized. The source need not exist in the sync recordings table, allowing Windows to upload just the minutes.

- PUT /v1/shares/<sourceID>, application/json: {"title":"...","markdown":"..."}. Replaces the previous share for this source. HTTP 200: {"url":"https://worker/s/<random-token>","expiresAt":<Unix milliseconds>}. Server generates 32 cryptographically random bytes encoded as base64url, stores only its SHA-256, and returns the raw token only on creation. Exactly 7 days expiry.
- GET /v1/shares/<sourceID>: HTTP 200 {"active":true,"expiresAt":<Unix milliseconds>} or {"active":false}. Does not return a token or private content.
- DELETE /v1/shares/<sourceID>: idempotent HTTP 204, immediately disables that source's public link.
- GET /s/<token>: public read-only responsive HTML, only while active and unexpired. Missing, expired, revoked and invalid tokens all return a generic 404 page. No redirect to authentication. Other private APIs still require the existing token.

Title: trimmed nonempty, at most 300 Unicode code points. Markdown: nonempty, at most 1 MiB UTF-8. Total request limit 1 MiB + 8 KiB, enforced while streaming. Reject unknown request fields. R2 snapshot is immutable and addressed independently for each publication; D1 row contains source_id, token_hash UNIQUE, object_key, title, created_at, expires_at. Publish R2 before atomic D1 upsert; failures do not replace an existing live share. Concurrent requests must not delete the winning object's contents. DELETE removes the D1 authorization record; orphan snapshots may remain private for later lifecycle cleanup.

## Web rendering and security
Use a small escaped Markdown renderer without dependencies: headings, paragraphs, lists, quotes, code blocks and tables if practical. Never execute raw HTML, scripts or arbitrary links. Strict CSP, no third-party assets, Referrer-Policy: no-referrer, X-Robots-Tag: noindex/nofollow/noarchive, nosniff and Cache-Control: no-store for both active and error pages. R2 stays private. Public routes do not expose sync credentials, source IDs, original documents or transcript. A recipient can save content they already saw; revoking cannot retract copies.

## Validation and deployment
Test public/private boundaries, snapshot contents, token expiry, replacement, revoke, malformed/oversized/hostile content and publication failure. Verify Swift clients and WPF client payload/auth/status/error handling. Build macOS/iOS and cross-compile Windows if supported by local tooling; Windows runtime checks require Windows. Run existing Worker regression tests. Prepare migration 0006, deployment instructions and local public-page visual verification. Do not claim production live without a verified deployment.
