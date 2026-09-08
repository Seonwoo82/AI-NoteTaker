import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Suite("Meeting profile store")
struct MeetingProfileTests {
    @Test("a new profile is valid and does not create a bootstrap upload")
    func defaultProfileDoesNotUpload() throws {
        let store = makeStore()

        try store.profile.validate()

        #expect(store.profile.displayName.isEmpty)
        #expect(!store.profile.automaticallyAnalyze)
        #expect(store.pendingProfileUpload == nil)
    }

    @Test("older profile JSON decodes missing automatic analysis opt-in as false")
    func missingAutomaticAnalysisFlagDefaultsFalse() throws {
        let json = """
        {
          "schemaVersion": 1,
          "displayName": "Legacy",
          "aliases": [],
          "role": "",
          "terms": [],
          "modifiedAt": 10,
          "mutationID": "11111111-2222-3333-4444-555555555555"
        }
        """

        let profile = try JSONDecoder().decode(MeetingUserProfile.self, from: Data(json.utf8))

        #expect(profile.displayName == "Legacy")
        #expect(!profile.automaticallyAnalyze)
    }

    @Test("profile edits persist, notify sync and build bounded prompt context")
    func profileEditsPersistAndNotify() throws {
        let root = temporaryDirectory()
        let store = MeetingProfileStore(root: root)
        var changes = 0
        store.onProfileChanged = { changes += 1 }

        try store.updateProfile { profile in
            profile.displayName = "Seonwoo"
            profile.aliases = ["SW"]
            profile.role = "Product lead"
            profile.automaticallyAnalyze = true
            profile.terms = [
                GlossaryTerm(
                    id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                    term: "Cloudflare D1",
                    spokenAs: "디원",
                    meaning: "Cloudflare serverless SQL database",
                    category: .project
                )
            ]
        }

        let reloaded = MeetingProfileStore(root: root)
        #expect(changes == 1)
        #expect(reloaded.profile.displayName == "Seonwoo")
        #expect(reloaded.profile.automaticallyAnalyze)
        #expect(store.pendingProfileUpload?.displayName == "Seonwoo")
        #expect(store.profile.promptContext.contains("Owner: Seonwoo"))
        #expect(store.profile.promptContext.contains("Cloudflare D1"))
        #expect(!store.profile.promptContext.contains("automaticallyAnalyze"))
    }

    @Test("pending profile uploads survive restart until matching ack")
    func pendingUploadSurvivesRestart() throws {
        let root = temporaryDirectory()
        let store = MeetingProfileStore(root: root)
        try store.updateProfile { profile in
            profile.displayName = "Offline edit"
        }
        let pending = try #require(store.pendingProfileUpload)

        let restarted = MeetingProfileStore(root: root)

        #expect(restarted.pendingProfileUpload == pending)
        restarted.markProfileUploadFinished(MeetingUserProfile(displayName: "Different", modifiedAt: pending.modifiedAt))
        #expect(restarted.pendingProfileUpload == pending)
        restarted.markProfileUploadFinished(pending)
        #expect(restarted.pendingProfileUpload == nil)
        #expect(MeetingProfileStore(root: root).pendingProfileUpload == nil)
    }

    @Test("profile edits remain pending after state write failure and restart")
    func recoversPendingEditAfterStateWriteFailure() throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root.appending(path: "meeting-profile-state.json"), withIntermediateDirectories: true)
        let store = MeetingProfileStore(root: root)

        #expect(throws: (any Error).self) {
            try store.updateProfile { profile in
                profile.displayName = "Saved before state failure"
            }
        }

        let restarted = MeetingProfileStore(root: root)
        #expect(restarted.profile.displayName == "Saved before state failure")
        #expect(restarted.pendingProfileUpload?.displayName == "Saved before state failure")
    }

    @Test("glossary display substitutions preserve the original transcript text")
    func glossarySubstitutionsPreserveSourceText() throws {
        let store = makeStore()
        try store.updateProfile { profile in
            profile.terms = [
                GlossaryTerm(
                    id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
                    term: "OpenRouter",
                    spokenAs: "오픈 라우터",
                    meaning: "AI provider gateway",
                    category: .organization
                )
            ]
        }
        let source = "오늘은 오픈 라우터 설정을 확인합니다."

        let substitutions = store.profile.glossaryDisplaySubstitutions(in: source)

        #expect(source == "오늘은 오픈 라우터 설정을 확인합니다.")
        #expect(substitutions == [
            GlossaryDisplaySubstitution(
                termID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
                sourceText: "오픈 라우터",
                displayText: "OpenRouter",
                utf16Range: GlossaryDisplayRange(location: 4, length: 6)
            )
        ])
    }

    @Test("local voice profile stays outside the shared profile file and can be deleted")
    func voiceProfileIsLocalOnly() throws {
        let root = temporaryDirectory()
        let store = MeetingProfileStore(root: root)
        try store.updateProfile { profile in
            profile.displayName = "Seonwoo"
        }
        let voice = LocalVoiceProfile(
            modelID: "fixture-speaker-model",
            embedding: [0.1, -0.2, 0.3],
            enrolledAt: Date(timeIntervalSince1970: 1_788_310_923),
            sampleDuration: 12
        )

        try store.saveVoiceProfile(voice, allowedDimensions: 3...3)

        let sharedJSON = try String(contentsOf: root.appending(path: "meeting-profile.json"), encoding: .utf8)
        let localJSON = try String(contentsOf: root.appending(path: "local-voice-profile.json"), encoding: .utf8)
        #expect(sharedJSON.contains("automaticallyAnalyze"))
        #expect(!sharedJSON.contains("fixture-speaker-model"))
        #expect(!sharedJSON.contains("embedding"))
        #expect(localJSON.contains("fixture-speaker-model"))
        #expect(MeetingProfileStore(root: root).localVoice == voice)

        try store.deleteVoiceProfile()

        #expect(store.localVoice == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "local-voice-profile.json").path))
    }

    @Test("corrupt local voice data does not hide a valid shared text profile")
    func corruptVoiceDoesNotResetSharedProfile() throws {
        let root = temporaryDirectory()
        let store = MeetingProfileStore(root: root)
        try store.updateProfile { profile in
            profile.displayName = "Seonwoo"
        }
        try Data(#"{"schemaVersion":1,"modelID":"broken","embedding":["bad"]}"#.utf8)
            .write(to: root.appending(path: "local-voice-profile.json"), options: .atomic)

        let reloaded = MeetingProfileStore(root: root)

        #expect(reloaded.profile.displayName == "Seonwoo")
        #expect(reloaded.localVoice == nil)
        #expect(reloaded.lastError != nil)
    }

    @Test("voice profile validation rejects unbounded embeddings")
    func voiceValidationRejectsBadEmbeddings() throws {
        let store = makeStore()

        #expect(throws: MeetingProfileValidationError.self) {
            try store.saveVoiceProfile(
                LocalVoiceProfile(modelID: "fixture", embedding: [], enrolledAt: Date(), sampleDuration: 5)
            )
        }
        #expect(throws: MeetingProfileValidationError.self) {
            try store.saveVoiceProfile(
                LocalVoiceProfile(modelID: "fixture", embedding: [Float.infinity], enrolledAt: Date(), sampleDuration: 5)
            )
        }
    }

    @Test("oversize shared profiles are rejected before they become unsyncable")
    func rejectsOversizeSharedProfile() throws {
        let store = makeStore()
        let terms = (0..<200).map { index in
            GlossaryTerm(
                id: UUID(),
                term: "Term \(index)",
                spokenAs: "Spoken \(index)",
                meaning: String(repeating: "x", count: 500),
                category: .general
            )
        }

        #expect(throws: MeetingProfileValidationError.self) {
            try store.updateProfile { profile in
                profile.terms = terms
            }
        }
        #expect(store.pendingProfileUpload == nil)
    }

    @Test("stale remote profiles cannot overwrite a pending local edit")
    func staleRemoteDoesNotOverwritePendingLocalEdit() throws {
        let store = makeStore()
        try store.updateProfile { profile in
            profile.displayName = "Local"
            profile.modifiedAt = 100
            profile.mutationID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        }
        let remote = MeetingUserProfile(
            displayName: "Remote",
            aliases: [],
            role: "",
            terms: [],
            modifiedAt: 99,
            mutationID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        )

        let applied = try store.applyRemoteProfile(remote)

        #expect(!applied)
        #expect(store.profile.displayName == "Local")
        #expect(store.pendingProfileUpload?.displayName == "Local")
    }

    @Test("newer remote profiles replace local profiles without creating a sync echo")
    func newerRemoteAppliesWithoutUploadEcho() throws {
        let store = makeStore()
        var changes = 0
        store.onProfileChanged = { changes += 1 }
        let remote = MeetingUserProfile(
            displayName: "Remote",
            aliases: ["R"],
            role: "Decision maker",
            terms: [],
            modifiedAt: 10,
            mutationID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        )

        let applied = try store.applyRemoteProfile(remote)

        #expect(applied)
        #expect(store.profile.displayName == "Remote")
        #expect(store.pendingProfileUpload == nil)
        #expect(changes == 0)
    }

    @Test("sync workspace attach preserves pending edits but workspace switch clears old namespace state")
    func syncWorkspaceAttachAndSwitchControlPendingState() throws {
        let root = temporaryDirectory()
        let store = MeetingProfileStore(root: root)
        try store.updateProfile { profile in
            profile.displayName = "Old workspace edit"
            profile.modifiedAt = 500
            profile.mutationID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
        }
        let pending = try #require(store.pendingProfileUpload)

        store.setSyncWorkspace("https://first.example.test")

        #expect(store.pendingProfileUpload == pending)

        store.setSyncWorkspace("https://second.example.test")
        let olderRemote = MeetingUserProfile(
            displayName: "Second workspace profile",
            modifiedAt: 10,
            mutationID: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        )
        let applied = try store.applyRemoteProfile(olderRemote)

        #expect(store.pendingProfileUpload == nil)
        #expect(applied)
        #expect(store.profile.displayName == "Second workspace profile")
        #expect(MeetingProfileStore(root: root).pendingProfileUpload == nil)
    }

    @Test("failed workspace switch does not enable old remote adoption")
    func failedWorkspaceSwitchDoesNotChangeScopeInMemory() throws {
        let root = temporaryDirectory()
        let store = MeetingProfileStore(root: root)
        try store.updateProfile { profile in
            profile.displayName = "First workspace"
        }
        let pending = try #require(store.pendingProfileUpload)
        store.setSyncWorkspace("https://first.example.test")
        store.markProfileUploadFinished(pending)
        try FileManager.default.removeItem(at: root.appending(path: "meeting-profile-state.json"))
        try FileManager.default.createDirectory(at: root.appending(path: "meeting-profile-state.json"), withIntermediateDirectories: true)

        store.setSyncWorkspace("https://second.example.test")
        let olderRemote = MeetingUserProfile(displayName: "Older second workspace", modifiedAt: 1)

        #expect(!((try? store.applyRemoteProfile(olderRemote)) ?? true))
        #expect(store.profile.displayName == "First workspace")
        #expect(store.pendingProfileUpload == nil)
    }

    private func makeStore() -> MeetingProfileStore {
        MeetingProfileStore(root: temporaryDirectory())
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "MeetingProfileTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
