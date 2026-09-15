# Web sharing implementation plan

**Goal:** Publish, open, copy and revoke a seven-day meeting-notes snapshot from Mac, iPhone and Windows.

**Architecture:** Existing Worker serves the HTML from private R2 after checking a hashed capability token in D1. Existing sync credentials authorize management calls, and Windows gains independent sharing credentials.

**Spec:** docs/superpowers/specs/2026-09-15-web-sharing-design.md

**Constraints:** No new dependencies or infrastructure. Snapshot only title/minutes. Never expose the administrative token. Maintain existing private API behavior. Follow the wire contract in the spec exactly.

## Tasks

- [x] Server: write failing route/security tests in Cloudflare/tests/web-sharing.test.mjs. Implement Cloudflare/web-sharing.mjs, integrate in worker.mjs, and add migrations/0006_web_shares.sql. Exercise PUT -> public GET -> replace -> old GET 404 -> DELETE -> GET 404. Run all node tests. Own Cloudflare/ only.
- [x] Apple: add an HTTP client and common SwiftUI share sheet integrated into both meeting-notes views. Reuse SyncSettings credentials. Test requests and failures using URLProtocol before implementation; build both Xcode projects. Own NoteTaker/, NoteTakerTests/, iOS/ and Shared/WebSharing/ only.
- [x] Windows: add sharing client, protected settings, and a share dialog reachable from selected completed minutes. Test HTTP request bodies, status, revoke and errors before implementing. Build WPF and tests where supported. Own Windows/ only.
- [x] Integration: verify matching source UUID and millisecond expiry conventions; review public-page security and snapshot scope; run Worker, Swift and Windows checks; render local web page and inspect small/wide layouts; document setup and limitations.

## Acceptance probes

```text
PUT /v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE without credentials -> 401
PUT with title + markdown and valid credentials -> 200 url, expiresAt
GET returned url without credentials -> 200 escaped readable HTML
GET /v1/recordings without credentials -> 401
PUT another snapshot -> prior url 404; new url 200
DELETE authenticated source -> 204; new url 404
```

Tests must also cover old share preservation on R2/D1 failure, title/markdown limits, unknown fields, bad UUID, XSS, expiry and server errors without credential disclosure. Client verification must demonstrate no OpenRouter key, audio or transcript in uploads and no authenticated redirect following.

## Verified result

- Cloudflare full suite: 76 tests passed (16 dedicated share tests).
- Real local Wrangler/D1/R2 HTTP lifecycle: 17 status assertions plus HTML/security/body assertions passed. Direct local D1 expiry update returned generic404 without content.
- Mac and iPhone simulator: 6 shared-client tests passed on each platform. Both applications build.
- Windows: WPF and test project cross-build with0warnings/errors; portable harness linked to actual WebShareClient.cs passed payload, auth, origin, status, revoke and near1MiB Korean JSON tests.
- Browser:1280px desktop and390px mobile, light/dark, no overflow or page errors; visual QA94/100. No external visual reference was supplied.
- Independent review addressed public HEAD/malformed namespace handling and strict Windows active-status expiry. Followup checks addressed conditional R2 writes, D1 write failure, interleaved publications, bounded inline/text and sparse-table rendering.
- Not performed: production deployment, signed installers, Windows native GUI/testhost execution, physical iPhone tests. Windows testhost requires Microsoft.WindowsDesktop.App, unavailable on this Mac. Native Windows xUnit tests are committed for execution on Windows.
