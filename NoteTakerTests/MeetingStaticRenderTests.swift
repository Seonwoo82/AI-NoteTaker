#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import NoteTaker

@MainActor
final class MeetingStaticRenderMacTests: XCTestCase {
    func testSharedMeetingViewsRenderKoreanDarkSnapshots() throws {
        let fixture = try MeetingStaticFixture.make()
        let profileStore = MeetingProfileStore(root: temporaryProfileRoot())
        try profileStore.updateProfile { profile in
            profile.displayName = fixture.profile.displayName
            profile.aliases = fixture.profile.aliases
            profile.role = fixture.profile.role
            profile.automaticallyAnalyze = fixture.profile.automaticallyAnalyze
            profile.terms = fixture.profile.terms
        }
        try profileStore.saveVoiceProfile(LocalVoiceProfile(
            modelID: "fixture-owner-voice-v1",
            embedding: [0.11, 0.21, 0.34, 0.55],
            enrolledAt: Date(timeIntervalSince1970: 1_788_508_800),
            sampleDuration: 24
        ))

        let profileImage = try renderPNG(
            MeetingProfileView(
                store: profileStore,
                voice: VoiceProfilePresentation(
                    modelsReady: true,
                    isPreparing: false,
                    isEnrolling: false,
                    isProcessing: false,
                    elapsed: 24,
                    status: "내 목소리 프로필이 준비되었습니다.",
                    error: nil
                ),
                recordingIsBusy: false,
                prepareVoiceModels: {},
                beginEnrollment: {},
                finishEnrollment: {},
                cancelEnrollment: {},
                deleteEnrollment: {}
            ),
            name: "meeting-profile-mac-dark",
            width: 560,
            height: 900
        )
        let conversationCases: [(name: String, attachment: String, section: MeetingConversationTab, height: CGFloat)] = [
            ("meeting-conversation-transcript-mac-dark", "Meeting Conversation Transcript macOS dark 680pt", .transcript, 920),
            ("meeting-conversation-actions-mac-dark", "Meeting Conversation Actions macOS dark 680pt", .actions, 820),
            ("meeting-conversation-questions-mac-dark", "Meeting Conversation Q&A macOS dark 680pt", .questions, 820),
            ("meeting-conversation-decisions-mac-dark", "Meeting Conversation Decisions macOS dark 680pt", .decisions, 860),
            ("meeting-conversation-speakers-mac-dark", "Meeting Conversation Speakers macOS dark 680pt", .speakers, 760)
        ]
        let conversationImages = try conversationCases.map { item in
            let image = try renderPNG(
                conversationView(fixture: fixture, initialSection: item.section),
                name: item.name,
                width: 680,
                height: item.height
            )
            attach(image, name: item.attachment)
            return image
        }
        let briefingImage = try renderPNG(
            MeetingBriefingView(
                sources: fixture.briefingSources,
                initialProject: "AI-NoteTaker 모바일 동기화",
                onOpen: { _, _ in }
            ),
            name: "meeting-briefing-mac-dark",
            width: 680,
            height: 760
        )
        let guideImages = try voiceEnrollmentGuideCases().map { item in
            let image = try renderPNG(
                VoiceEnrollmentGuideView(
                    voice: item.voice,
                    hasExistingProfile: item.hasExistingProfile,
                    recordingIsBusy: false,
                    isStarting: false,
                    isCompleted: item.isCompleted,
                    onStart: {},
                    onFinish: {},
                    onCancel: {},
                    onClose: {}
                ),
                name: item.name,
                width: 460,
                height: 520
            )
            attach(image, name: item.attachment)
            return image
        }

        attach(profileImage, name: "Meeting Profile macOS dark 560pt")
        attach(briefingImage, name: "Meeting Briefing macOS dark 680pt")

        guard profileImage.count > 20_000 else { throw RenderError.blankProfileRender }
        guard conversationImages.allSatisfy({ $0.count > 20_000 }) else { throw RenderError.blankConversationRender }
        guard briefingImage.count > 20_000 else { throw RenderError.blankBriefingRender }
        guard guideImages.allSatisfy({ $0.count > 12_000 }) else { throw RenderError.blankVoiceEnrollmentGuideRender }
        guard fixture.resolvedDocument.myCommitments.count == 1 else { throw RenderError.missingOwnerCommitment }
        guard fixture.resolvedDocument.receivedRequests.count == 1 else { throw RenderError.missingOwnerRequest }
        guard fixture.briefing.decisions.count == 1 else { throw RenderError.missingBriefingDecision }
        guard fixture.briefing.openActions.count == 1 else { throw RenderError.missingBriefingAction }
        guard fixture.briefing.unansweredQuestions.count == 1 else { throw RenderError.missingBriefingQuestion }
    }

    private func conversationView(fixture: MeetingStaticFixture, initialSection: MeetingConversationTab) -> some View {
        MeetingConversationView(
            content: fixture.resolvedDocument,
            status: "AI 회의록 분석이 완료되었습니다. iPhone과 Mac에서 같은 회의 정보를 볼 수 있습니다.",
            isBusy: false,
            hasAPIKey: true,
            editable: true,
            initialSection: initialSection,
            canPlayTurns: true,
            profile: fixture.profile,
            onAnalyze: {},
            onCancel: {},
            onOpenAISettings: {},
            onOpenProfile: {},
            onPlayTurns: { _ in },
            onEdit: { _, _, _ in }
        )
    }

    private func voiceEnrollmentGuideCases() -> [(name: String, attachment: String, voice: VoiceProfilePresentation, hasExistingProfile: Bool, isCompleted: Bool)] {
        [
            (
                "voice-enrollment-guide-ready-mac-dark",
                "Voice Enrollment Guide Ready macOS dark 460pt",
                VoiceProfilePresentation(modelsReady: true, status: "음성 모델이 준비되었습니다."),
                false,
                false
            ),
            (
                "voice-enrollment-guide-recording-mac-dark",
                "Voice Enrollment Guide Recording macOS dark 460pt",
                VoiceProfilePresentation(modelsReady: true, isEnrolling: true, elapsed: 8.4, status: "내 목소리를 녹음하고 있습니다..."),
                false,
                false
            ),
            (
                "voice-enrollment-guide-error-mac-dark",
                "Voice Enrollment Guide Error macOS dark 460pt",
                VoiceProfilePresentation(modelsReady: true, elapsed: 4, status: "목소리 프로필을 저장하지 않았습니다.", error: "또렷한 음성을 조금 더 녹음하세요."),
                true,
                false
            ),
            (
                "voice-enrollment-guide-completed-mac-dark",
                "Voice Enrollment Guide Completed macOS dark 460pt",
                VoiceProfilePresentation(modelsReady: true, elapsed: 18, status: "내 목소리 프로필이 준비되었습니다."),
                true,
                true
            )
        ]
    }

    private func renderPNG<Content: View>(_ content: Content, name: String, width: CGFloat, height: CGFloat) throws -> Data {
        let outputURL = try outputDirectory().appending(path: "\(name).png")
        let rootView = content
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "ko_KR"))
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(width: width, height: height)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hostingView.wantsLayer = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw RenderError.couldNotCreateBitmap
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw RenderError.couldNotEncodePNG
        }
        try png.write(to: outputURL, options: .atomic)
        return png
    }

    private func attach(_ png: Data, name: String) {
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func outputDirectory() throws -> URL {
        let url = repositoryRoot.appending(path: "build/visual-qa", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func temporaryProfileRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "NoteTakerMeetingRenderProfile-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private var repositoryRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private enum RenderError: Error {
        case couldNotCreateBitmap
        case couldNotEncodePNG
        case blankProfileRender
        case blankConversationRender
        case blankBriefingRender
        case blankVoiceEnrollmentGuideRender
        case missingOwnerCommitment
        case missingOwnerRequest
        case missingBriefingDecision
        case missingBriefingAction
        case missingBriefingQuestion
    }
}

private struct MeetingStaticFixture {
    let profile: MeetingUserProfile
    let resolvedDocument: MeetingResolvedDocument
    let briefingSources: [MeetingBriefingSource]
    let briefing: MeetingBriefing

    static func make() throws -> Self {
        let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let previousID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let profile = MeetingUserProfile(
            displayName: "선우",
            aliases: ["Seonwoo", "SW"],
            role: "제품과 개발을 함께 보는 앱 소유주",
            automaticallyAnalyze: true,
            terms: [
                GlossaryTerm(term: "AI-NoteTaker", spokenAs: "에이아이 노트테이커", meaning: "Mac과 iPhone에서 동기화되는 음성 회의록 앱", category: .project),
                GlossaryTerm(term: "OpenRouter", spokenAs: "오픈 라우터", meaning: "AI 회의록 분석 모델 연결", category: .organization),
                GlossaryTerm(term: "Cloudflare Workers", spokenAs: "클라우드플레어 워커스", meaning: "기기 간 동기화 서버", category: .project)
            ],
            modifiedAt: 1_788_508_800_000,
            mutationID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )
        let transcript = makeTranscript(recordingID: recordingID, audioVersion: 3)
        let insights = makeInsights()
        let document = MeetingIntelligenceDocument(
            recordingID: recordingID,
            audioVersion: 3,
            modifiedAt: 1_788_508_860_000,
            mutationID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            projectName: "AI-NoteTaker 모바일 동기화",
            transcript: transcript,
            insights: insights,
            actionStates: ["action-owner-summary": MeetingActionStatus.open.rawValue],
            analysisModelID: "openrouter/fixture-meeting-model"
        )
        let resolved = try document.resolved(edits: [])
        let previousDocument = MeetingIntelligenceDocument(
            recordingID: previousID,
            audioVersion: 2,
            modifiedAt: 1_788_422_400_000,
            mutationID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            projectName: "AI-NoteTaker 모바일 동기화",
            transcript: makeTranscript(recordingID: previousID, audioVersion: 2),
            insights: insights,
            actionStates: ["action-owner-review": MeetingActionStatus.done.rawValue],
            analysisModelID: "openrouter/fixture-meeting-model"
        )
        let previousResolved = try previousDocument.resolved(edits: [])
        let sources = [
            MeetingBriefingSource(recordingID: recordingID, title: "iPhone 회의록 품질 점검", createdAt: Date(timeIntervalSince1970: 1_788_508_860), resolvedDocument: resolved),
            MeetingBriefingSource(recordingID: previousID, title: "Mac 동기화 설계 회의", createdAt: Date(timeIntervalSince1970: 1_788_422_400), resolvedDocument: previousResolved)
        ]
        return MeetingStaticFixture(
            profile: profile,
            resolvedDocument: resolved,
            briefingSources: sources,
            briefing: MeetingBriefingBuilder.build(projectName: "AI-NoteTaker 모바일 동기화", sources: sources, excluding: recordingID)
        )
    }

    private static func makeTranscript(recordingID: UUID, audioVersion: Int) -> MeetingTranscript {
        MeetingTranscript(
            recordingID: recordingID,
            audioVersion: audioVersion,
            transcriptionModelID: "openrouter/whisper-fixture",
            speakers: [
                MeetingSpeaker(id: "owner", name: "선우", isOwner: true, manuallyAssigned: true),
                MeetingSpeaker(id: "speaker-product", name: "민지 PM", isOwner: false),
                MeetingSpeaker(id: "speaker-design", name: "도윤 디자이너", isOwner: false)
            ],
            turns: [
                TranscriptTurn(id: "turn-owner-1", start: 0, end: 13, speakerID: "owner", text: "제가 다음 주 화요일까지 OpenRouter 설정 안내 문구와 iPhone 동기화 확인 화면을 정리하겠습니다. API 키는 각 기기에 안전하게 저장하고 나머지 모델 설정은 Cloudflare를 통해 맞춰지면 좋겠습니다."),
                TranscriptTurn(id: "turn-product-1", start: 13, end: 27, speakerID: "speaker-product", text: "iOS 앱에서 회의록 전사문이 발화자별로 나뉘어 보이고, 미답변 질문과 요청 사항이 Mac에서 보던 것처럼 같은 순서로 노출되는지 확인해야 합니다. 특히 한국어 긴 문장이 줄바꿈될 때 버튼이 밀리지 않는지 보고 싶습니다."),
                TranscriptTurn(id: "turn-design-1", start: 27, end: 39, speakerID: "speaker-design", text: "프로필 탭에는 내 목소리 등록 상태가 분명히 보여야 합니다. 녹음 중 앱 소유주로 추정되는 발화에는 작은 파란 배지를 보여주고, 확신이 낮으면 검토가 필요하다는 색으로 처리하는 방향을 제안합니다."),
                TranscriptTurn(id: "turn-owner-2", start: 39, end: 52, speakerID: "owner", text: "좋습니다. 오늘 결정은 Mac과 iPhone 모두에서 AI 회의록, 발화자 구분, 작업 상태, 질문 답변 기록이 같은 자료를 기준으로 렌더되는지 정적 화면으로 먼저 잠그는 것입니다."),
                TranscriptTurn(id: "turn-product-2", start: 52, end: 64, speakerID: "speaker-product", text: "그럼 배포 전에 남은 질문은 음성 프로필이 없는 새 iPhone에서 어떤 안내 문구를 보여줄지입니다. API 키와 목소리 샘플은 동기화하지 않는 이유도 함께 설명되어야 합니다.")
            ]
        )
    }

    private static func makeInsights() -> MeetingInsights {
        MeetingInsights(actions: [
            MeetingAction(id: "action-owner-summary", kind: .commitment, text: "OpenRouter 설정 안내 문구와 iPhone 동기화 확인 화면을 다음 주 화요일까지 정리한다.", actorSpeakerID: "owner", targetSpeakerID: nil, dueText: "다음 주 화요일", evidenceTurnIDs: ["turn-owner-1"]),
            MeetingAction(id: "action-owner-review", kind: .request, text: "iOS 앱에서 회의록 전사문, 미답변 질문, 요청 사항이 Mac과 같은 순서로 보이는지 검토한다.", actorSpeakerID: "speaker-product", targetSpeakerID: "owner", dueText: nil, evidenceTurnIDs: ["turn-product-1"])
        ], questions: [
            MeetingQuestion(id: "question-profile-empty", question: "음성 프로필이 없는 새 iPhone에서는 어떤 안내 문구를 보여줘야 하나요?", questionTurnIDs: ["turn-product-2"], answer: nil, answerTurnIDs: [], status: .unanswered),
            MeetingQuestion(id: "question-owner-badge", question: "앱 소유주로 추정되는 발화는 어떻게 표시하나요?", questionTurnIDs: ["turn-design-1"], answer: "작은 파란 배지를 사용하고 확신이 낮으면 검토가 필요하다는 색을 사용합니다.", answerTurnIDs: ["turn-design-1"], status: .answered)
        ], decisions: [
            MeetingDecision(id: "decision-static-render", topic: "모바일과 데스크톱 회의록 정적 렌더 검증", status: .decided, steps: [
                MeetingDecisionStep(kind: .proposal, text: "Mac과 iPhone에서 같은 회의 자료를 기준으로 렌더 화면을 고정합니다.", speakerID: "owner", evidenceTurnIDs: ["turn-owner-2"]),
                MeetingDecisionStep(kind: .concern, text: "한국어 긴 문장이 줄바꿈될 때 버튼과 카드가 밀리지 않는지 확인해야 합니다.", speakerID: "speaker-product", evidenceTurnIDs: ["turn-product-1"]),
                MeetingDecisionStep(kind: .decision, text: "AI 회의록, 발화자 구분, 작업 상태, 질문 답변 기록을 정적 화면으로 먼저 검증합니다.", speakerID: "owner", evidenceTurnIDs: ["turn-owner-2"])
            ])
        ])
    }
}
#endif
