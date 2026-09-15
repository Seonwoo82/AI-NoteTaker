# Apple local AI implementation

**Spec:** docs/superpowers/specs/2026-09-15-apple-local-ai-design.md

**Goal:** Free on-device transcription and minutes on supported Mac/iPhone devices, selectable alongside preserved OpenRouter setup.

**Constraints:** No new package dependencies, no cloud fallback in local mode, no production infrastructure changes, unchanged iOS17 minimum. Runtime availability checks for new OS frameworks.

- [x] Backend: implement and test Shared/LocalAI model identifiers, system readiness, strict routing, FoundationModels and on-device Speech adapters. Tests first for dispatch/failure/cancellation and IDs. Runtime smoke when available.
- [x] Integration: implement/test per-device mode and readiness in AIConfiguration; wrap live AIEnvironment; capture local IDs/keyless generation and safe budgets in both MeetingNotesService files; preserve cloud behavior/cache/cancellation.
- [x] UI: mode picker and local readiness/preparation/language card in both AI settings; truthful empty-state and cloud-feature explanations; Korean strings and speech usage descriptions.
- [x] Privacy and verification: guard cloud-only analysis in Shared/MeetingIntelligence, test local no-cloud callback paths, run focused tests and builds serially per derived-data directory; inspect settings UI; document hardware requirements and actual runtime evidence.
- [x] Integrate verified work into local main with Lore commit, preserve prior web-sharing feature. No production deployment or key changes.

## Verification evidence

- Mac final xcresult: build/DerivedData/Logs/Test/Test-NoteTaker-2026.09.15_14-44-07-+0900.xcresult; 83 passed,0 failed,1 runtime-test skipped.
- iPhone final xcresult: build/IOSDerivedData/Logs/Test/Test-NoteTakerIOS-2026.09.15_14-44-07-+0900.xcresult;88 passed,0 failed,1 runtime-test skipped.
- Actual production summary client smoke: /tmp/note-taker-local-ai-production-smoke.swift links Shared/LocalAI production sources; log /tmp/note-taker-local-ai-production-smoke.log confirms Korean output,0cost,completion marker stripped. Support stubs only provide types and unused audio chunking to run the summary entry point outside the app.
- Runtime smoke opt-in inside XCTest is explicitly skipped by default; ordinary xcodebuild environment assignments did not forward to the testhost, so early no-op test results were not counted as inference proof.
- Independent review found no remaining P1/P2 issue. Speech callback cancellation races, output completion checks, availability ordering, cloud-only catalog dispatch and stale locale readiness were corrected.
- Not executed: actual Apple Speech recognition requiring a permission prompt, physical iPhone inference, long-meeting quality benchmark or production app distribution.
