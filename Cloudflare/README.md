# AI-NoteTaker Cloudflare Sync

This Worker stores voice-note metadata, completed meeting-note descriptors, shared AI preferences, text profile data, meeting intelligence descriptors, and manual meeting edits in Cloudflare D1. Immutable audio, completed meeting notes, and meeting intelligence documents live in a private R2 bucket for a personal iOS/macOS install.

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
- `GET /v1/profile` returns `{ "profile": document|null }`.
- `PUT /v1/profile` accepts `{ "profile": document|null }`. A non-null profile is last-write-wins by `(modifiedAt, mutationID)` and returns the server winner. A null profile only reads the current winner.
- `GET /v1/intelligence?cursor=<UUID:0000000001>` lists up to 100 meeting-intelligence descriptors ordered by recording ID and ten-digit audio version, with a nullable `nextCursor`.
- `PUT /v1/recordings/<UUID>/intelligence/<audioVersion>` accepts a completed meeting-intelligence document after matching recording metadata exists and its current `audioVersion` matches. Returns `{ "intelligence": descriptor }`, where the descriptor has `recordingID`, `audioVersion`, `generatedAtMillis`, `revision` (SHA-256), and `byteCount`.
- `GET /v1/recordings/<UUID>/intelligence/<audioVersion>/<revision>` returns the exact completed JSON bytes from `recordings/<UUID>/intelligence/<audioVersion>/<revision>.json` in private R2.
- `GET /v1/meeting-edits?after=<sequence>` lists append-only manual edit entries as `{ "entries": [{ "sequence": number, "edit": document }], "nextCursor": number|null }`, ordered by sequence.
- `PUT /v1/meeting-edits/<UUID>` accepts one immutable manual edit document. Repeating the same ID with the same payload succeeds and returns the existing entry; repeating the same ID with a different payload returns `409 edit_conflict`.

Responses include `Cache-Control: no-store` so private metadata, audio, and documents are not cached by intermediary clients. The health route reads both the `recordings` and `meeting_notes` tables and performs an R2 metadata lookup; a missing migration or broken bucket binding fails health. Apply all migrations before deploying the Worker.

## Limits And Conflicts

Metadata is limited to 64 KiB. Chunked metadata bodies are read incrementally and rejected as soon as they cross the limit. Each audio upload is limited to 95 MiB and must include `Content-Length`; this lets the Worker pass the known-length request stream to R2 without buffering the file in memory. Larger requests return `413 payload_too_large` with an actionable message.

Metadata conflicts use last-edit-wins by the lexicographic tuple `(modifiedAt, mutationID)`. `modifiedAt` is Unix milliseconds and `mutationID` is a canonical uppercase UUID. The higher tuple wins atomically in D1; stale clients receive and should adopt the returned winner. This depends on device clocks being reasonably close. Audio is immutable for this scope, and cloud audio or tombstones are not purged automatically.

Completed notes are limited to 2 MiB and use `(generatedAtMillis, revision)` conflict order. Meeting intelligence documents are limited to 4 MiB and use `(modifiedAt, mutationID)` conflict order while still storing immutable content-addressed R2 objects. Clients verify size, schema, recording/audio version, references, and SHA-256 before atomic publication. A failed transfer preserves the local document. `ai-transcript.json` is an unfinished generation cache and remains local; the complete transcript already travels inside `meeting-notes.json`. OpenRouter API keys remain device-local and are never uploaded. AI model IDs, output language, and the requested automatic-generation preference sync separately through D1.

## Profile And Meeting Intelligence

Apply `0004_meeting_intelligence.sql` for the text profile, meeting intelligence descriptors, and append-only manual edits.

The text profile document includes `schemaVersion: 1`, `displayName`, `aliases`, `role`, `terms`, `automaticallyAnalyze`, `modifiedAt`, and `mutationID`. `automaticallyAnalyze` defaults to false when omitted by older clients, so extra speaker/conversation analysis remains opt-in. Terms are text-only entries with `id`, `term`, `spokenAs`, `meaning`, and `category` (`person`, `organization`, `project`, `abbreviation`, or `general`). The profile route is bounded to 64 KiB and rejects unsupported keys, including API keys, audio samples, embeddings, voice profiles, and device secrets.

The meeting intelligence root document includes `schemaVersion: 1`, `recordingID`, `audioVersion`, `modifiedAt`, `mutationID`, `projectName`, `transcript`, `insights`, `actionStates`, and `analysisModelID`. `transcript` stores speaker-separated turns and marks the owner speaker when known. `insights` may be null or include commitments, requests, questions, answers, and decision evolution, with all evidence pointing to known transcript turn IDs. `actionStates` is a dictionary from known action IDs to `open`, `done`, or `dismissed`.

Manual edit documents include `schemaVersion: 1`, `id`, `recordingID`, `audioVersion`, `modifiedAt`, `kind`, `targetID`, and `value`. Supported kinds are `speakerName`, `speakerOwner`, `turnSpeaker`, `actionStatus`, and `projectName`. Clients reduce edits per target field by `(modifiedAt, id)`, so speaker corrections and action status changes survive regenerated AI intelligence documents.


## AI Preferences

Apply `0003_ai_settings.sql` for the singleton preference document and per-device key-presence records.

- `GET /v1/ai-settings?deviceID=<UUID>` returns `{ preferences: document|null, otherDevicesHaveAPIKey: boolean }`.
- `PUT /v1/ai-settings` accepts `{ preferences: document|null, device: { id, platform, hasAPIKey } }` and returns the same response shape, excluding the caller when checking other devices.
- The document includes `schemaVersion: 1`, `modelID`, `transcriptionModelID`, `outputLanguage` (`ko`, `en`, `source`), `autoGenerate`, `modifiedAt` (Unix milliseconds), and `mutationID` (uppercase UUID). Conflicts use `(modifiedAt, mutationID)`.
- A null preference only updates device presence. `hasAPIKey` is a boolean; null or omission preserves the last known presence when Keychain is temporarily unavailable. Platforms are `macOS` or `iOS`.
- Requests and responses are bounded to 16 KiB. Only explicitly supported fields are accepted; API keys, key fragments, catalogs, and device names are never part of the payload.

A new client reads existing preferences before publishing. Explicit offline edits are preserved for retry. Generation is still gated by a local API key even when shared automatic generation is enabled.
