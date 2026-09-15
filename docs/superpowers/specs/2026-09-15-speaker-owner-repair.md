# Speaker and owner recognition repair

## User objective
1. A real two-person meeting must not appear as four speakers.
2. Registered owner voice recognition and its application to meeting results must work correctly.

Target reference is the user-provided screenshot, recording38BE34C6-96A6-4A9B-892C-321C83EEDD51,394.784seconds. Do not redefine completion as passing synthetic tests or hiding extra rows. Verify actual acoustic assignments, owner identity, displayed/persisted results, and future behavior. Preserve original recording, transcript text, notes, edits and registered voice profile through backups.

## Verified baseline
- Main56a0f6b includes prior web-sharing/local-AI work, which must be preserved.
- Current native backend reproduced6 acoustic IDs,4 used IDs (speaker1:25turns,2:23,3:2,6:1),32unknown turns. Two acoustic IDs emitted no spans.
- Registered owner cosine scores: group1 .7600, group2 .2370, othergroups -.0373 through .0966. Current absolute owner threshold .82 misses the user-confirmed group1.
- Actual manual edits move one turn to owner then mark speaker1 as owner, explaining duplicate Me rows. An unused owner row is always synthesized in the assembler.
- Streaming diarization uses greedy independent10second windows without global reclustering. SDK creation quality uses total activity although embeddings use clean-only masks; short slots can create unstable IDs.
- Live owner path uses mixed recording audio,3second windows andRMS.01; enrollment accepts much quieter speech. 239of790 actual halfsecond chunks lie between.0003 and.01.
- Existing code discards live results when new chunks are pending, which can starve publication under continuous audio. Reenrollment does not invalidate/reapply owner attribution to saved transcripts.

## Work plan and safeguards
1. Snapshot actual data locally under ignored build/speaker-repair/input; run baseline and report scores without exposing private transcript/vector content in user-facing output.
2. Compare SDK offline global clustering with unconstrained speaker count and retained overlap in an isolated model cache. No hard-coded two-speaker cap. Confirm both principal voices and rare-ID intervals.
3. Repair live observation RMS/pause handling and slow-inference publication with regression tests. Preserve cancellation/gap/profile-change staleness protections.
4. Choose owner thresholds/attribution from held-out clean actual spans and negative spans, retain embedding model compatibility. Do not change model ID while comparing incompatible embeddings.
5. Correct phantom/displayed owner identities and voice profile reapplication without losing manual ownership corrections or reuploading audio unnecessarily.
6. Run synthetic and actual-local-model verification; integrate latest main safely, then verify installed-app state and corrected target meeting. Do not disrupt an active recording.

## Completion evidence required
- Actual target resolves to two coherent human speaker identities, not a forced numerical count, with meaningful assignment coverage and no noise-only speakers.
- Owner matches the manually confirmed person and does not match the other person; owner turns and owner-specific views are consistent.
- Quiet speech/pauses and delayed live inference produce useful bounded-freshness results; silence, capture changes and old profiles never publish stale owner results.
- Reenrollment/owner correction applies predictably to saved meeting data and UI; original data remains recoverable.
- Mac/iPhone builds and relevant tests pass; actual app/recording result inspected where applicable. Record limitations instead of treating indirect checks as completion.
