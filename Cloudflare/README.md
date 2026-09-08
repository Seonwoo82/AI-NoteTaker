# AI-NoteTaker Cloudflare Sync

This Worker stores voice-note metadata and completed meeting-notes descriptors in Cloudflare D1, with immutable audio and completed AI documents in a private R2 bucket for a personal iOS/macOS install.

Use your own Cloudflare account and deployment. Copy the database ID returned by Wrangler into `wrangler.toml`; store the sync token as a Worker secret. Local `.dev.vars` and Wrangler state are ignored by Git.

## Resources

Prerequisites: a Cloudflare account with Workers, D1 and R2 enabled, and Wrangler access from npm. Log in first:

```sh
npx wrangler login
```

Create the Cloudflare resources from this directory:

```sh
npx wrangler d1 create note-taker-sync
npx wrangler r2 bucket create note-taker-audio
npx wrangler r2 bucket list
```

Copy the returned D1 `database_id` into `wrangler.toml`, then apply the migration:

```sh
npx wrangler d1 migrations apply note-taker-sync --local
npx wrangler d1 migrations apply note-taker-sync --remote
```

Create a long random sync token and store it as a Worker secret:

```sh
openssl rand -base64 48
npx wrangler secret put SYNC_TOKEN
```

Deploy when you are ready to use your own Cloudflare account:

```sh
npx wrangler deploy
```

The app settings should use the deployed Worker HTTPS origin and the same token. Cloudflare account API keys are never entered into the app.

## HTTP Contract

All routes require `Authorization: Bearer <SYNC_TOKEN>`.

- `GET /v1/health` returns `{ "ok": true, "schemaVersion": 1 }` after DB and R2 binding checks.
- `GET /v1/recordings?cursor=<UUID>` returns up to 100 metadata records ordered by uppercase UUID with `nextCursor` set to the last returned UUID when another page exists.
- `PUT /v1/recordings/<UUID>` accepts `Recording` JSON and returns the server winner. Swift may omit nil `deletedAt` and `transcriptionError`; the Worker normalizes those fields to `null` before storing. Live metadata is accepted only after `audio/<audioVersion>` exists. Tombstones with `deletedAt` can be stored without audio.
- `PUT /v1/recordings/<UUID>/audio/<audioVersion>` accepts `audio/mp4` with `Content-Length` and stores `recordings/<UUID>/audio/<audioVersion>.m4a`. The key is immutable: duplicate retries succeed but keep the first bytes.
- `GET /v1/recordings/<UUID>/audio/<audioVersion>` streams the private R2 object.
- `GET /v1/notes?cursor=<UUID:0000000001>` lists up to 100 completed-document descriptors ordered by recording ID and ten-digit audio version, with a nullable `nextCursor`.
- `PUT /v1/recordings/<UUID>/notes/<audioVersion>` accepts a completed `MeetingNotesDocument` (including its transcript) after matching recording metadata exists. Returns `{ "note": descriptor }`, where the descriptor has `recordingID`, `audioVersion`, `generatedAtMillis`, `revision` (SHA-256), and `byteCount`.
- `GET /v1/recordings/<UUID>/notes/<audioVersion>/<revision>` returns the exact completed JSON bytes from `recordings/<UUID>/notes/<audioVersion>/<revision>.json` in private R2.

Responses include `Cache-Control: no-store` so private metadata, audio, and documents are not cached by intermediary clients. The health route reads both the `recordings` and `meeting_notes` tables and performs an R2 metadata lookup; a missing migration or broken bucket binding fails health. Apply all migrations before deploying the Worker.

## Limits And Conflicts

Metadata is limited to 64 KiB. Chunked metadata bodies are read incrementally and rejected as soon as they cross the limit. Each audio upload is limited to 95 MiB and must include `Content-Length`; this lets the Worker pass the known-length request stream to R2 without buffering the file in memory. Larger requests return `413 payload_too_large` with an actionable message.

Metadata conflicts use last-edit-wins by the lexicographic tuple `(modifiedAt, mutationID)`. `modifiedAt` is Unix milliseconds and `mutationID` is a canonical uppercase UUID. The higher tuple wins atomically in D1; stale clients receive and should adopt the returned winner. This depends on device clocks being reasonably close. Audio is immutable for this scope, and cloud audio or tombstones are not purged automatically.

Completed documents are limited to 2 MiB and use a separate `(generatedAtMillis, revision)` conflict order. Clients verify size, schema, recording/audio version, and SHA-256 before atomic publication. A failed transfer preserves the local document. `ai-transcript.json` is an unfinished generation cache and remains local; the complete transcript already travels inside `meeting-notes.json`. OpenRouter API keys remain device-local and are never uploaded. AI model IDs, output language, and the requested automatic-generation preference sync separately through D1.


## AI Preferences

Apply `0003_ai_settings.sql` for the singleton preference document and per-device key-presence records.

- `GET /v1/ai-settings?deviceID=<UUID>` returns `{ preferences: document|null, otherDevicesHaveAPIKey: boolean }`.
- `PUT /v1/ai-settings` accepts `{ preferences: document|null, device: { id, platform, hasAPIKey } }` and returns the same response shape, excluding the caller when checking other devices.
- The document includes `schemaVersion: 1`, `modelID`, `transcriptionModelID`, `outputLanguage` (`ko`, `en`, `source`), `autoGenerate`, `modifiedAt` (Unix milliseconds), and `mutationID` (uppercase UUID). Conflicts use `(modifiedAt, mutationID)`.
- A null preference only updates device presence. `hasAPIKey` is a boolean; null or omission preserves the last known presence when Keychain is temporarily unavailable. Platforms are `macOS` or `iOS`.
- Requests and responses are bounded to 16 KiB. Only explicitly supported fields are accepted; API keys, key fragments, catalogs, and device names are never part of the payload.

A new client reads existing preferences before publishing. Explicit offline edits are preserved for retry. Generation is still gated by a local API key even when shared automatic generation is enabled.
