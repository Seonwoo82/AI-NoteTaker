# 최신 Apple 앱 전체 Windows 이식

기준: upstream `2aaf0532e48016b32571c7929984a8f474e812ee` (2026-09-16 원격 main 재확인).
브랜치: `codex/windows-complete-port`. 기존 Windows PR이 합쳐진 최신 main을 fast-forward로 반영했다.
이 문서는 0.3의 완료 기록인 EXECUTION_PLAN.md와 별개다. 기존 기능의 테스트 통과로 아래 전체 이식의 완료를 주장하지 않는다.

## 범위와 검증 증거

| 영역 | 현재 상태 | 완료에 필요한 구현 및 증거 |
| --- | --- | --- |
| 녹음·가져오기·재생·삭제/복원·무료 AI·Clova 파일 연동 | 기존 구현, 회귀 검증 필요 | Windows 빌드/단위/실행/패키지 검증. 원본과 이전 성공 문서 보존 |
| 5분 집중 파형과 전체 개요 | 구현·단위·WPF 검증 | 절대 시간 탐색, 15분 실제 생성 WAV 해상도, 드래그 중 고정 범위, 시작/끝·비정상 값 테스트, 2시간 범위 WPF 렌더링. 아래 검증 기록 참조 |
| 녹음 폴더 | 구현·저장·WPF 검증, 동기화 대기 | 생성/이름/삭제/이동/정렬/접기·펼치기, 삭제 시 오디오 보존, 선택·재생 유지, 재시작 후 지속. 폴더 내 녹음은 파일 입력을 사용한 WPF 캡처 흐름으로 검증. 드래그 실제 포인터 검증과 폴더 내 가져오기 UI 추가 검증 필요 |
| 트레이·전역 단축키·자동 AI | 구현·Windows API·실제 AI 검증 | Shell 트레이 등록, 창 숨김/복원, 3개 키 등록/해제, HWND 단축키 메시지, 명시적 종료 확인. 파일 입력의 녹음 중 트레이 유지·pause/resume·폴더 유지, 자동 생성 off/키 실패/종료 제외, 실제 Whisper/Ollama 완료 확인. 실제 장치 장시간 트레이 녹음·물리 키 입력은 별도 |
| 모델 선택·긴 회의 예산 | 일부 | 모델 목록 검색, 별도 보완 모델, 제공자 출력/문맥 상한과 분할 종합, 키 제거 시 선택 설정 보존 |
| F-001 참여자 구분 | 미구현 | 실제 로컬 화자 모델, 첫 등장 순서의 안정적 라벨, 시간·근거 재생, 긴 목록 가상화, 실패 시 원문/회의록 유지 |
| F-002 목소리 프로필·라이브 본인 표시 | 미구현 | 명시적 10–30초 등록, VAD/음량 품질·실패 시 기존 프로필 유지·재등록/삭제, 기기 로컬 저장, held-out 음성 비교 |
| F-003 내 발화와 연속 재생 | 미구현 | 원본 구간 연속 재생, 녹음/등록 중 오디오 충돌 방지 |
| F-004–006 약속/요청·질문/답변·결정 흐름 | 미구현 | 구조화 분석, 실재 발화 ID 검증, 상태와 근거 이동/재생, 잘못된 모델 응답 및 재분석 테스트 |
| F-007 프로젝트 브리핑 | 미구현 | 이전 회의 결정/미완료 업무/미해결 질문 집계, 한 프로젝트 자동 선택, 원본 회의 이동 |
| F-008 이름·별칭·역할·용어 | 미구현 | 편집 UI/저장/프롬프트 반영/원문 보존 주석 |
| F-009 수동 수정 | 미구현 | 화자명·본인 표시·개별 발화·업무 상태·프로젝트 이력, 재분석 후 보존 |
| 회의록 AI 보완·전사 정리 | 미구현 | 지시→미리보기→적용/버리기, 취소·동시 변경 보호, 번호/시간/숫자/발화 ID 보존, 원본 비교·자동 정리 실패 시 원문 사용 |
| 회의록 목차 | 미구현 | 긴 문서의 제목 탐색 및 본문 위치 이동 |
| 전체 Cloudflare 동기화 및 F-010 | 공유만 구현 | Apple wire schema 호환: M4A/metadata/folders/tombstones/notes/intelligence/edits/profile/AI preferences; hash·size·revision·atomic publication; offline outbox/retry/auto/manual/status |
| 동기화 비밀 제외 | 검증 필요 | 키/토큰/목소리/임베딩 업로드 금지, Windows 플랫폼 인식 서버 계약, fixture 기반 상호운용 테스트 |
| 지속 웹 공유 | 최신 구현 반영, native 검증 필요 | 생성/반복 복사/재시작 복구/취소/만료, title+Markdown만 전송, 실제 WPF 및 local Worker HTTP 검증 |
| 배포·문서·PR | 미완료 | 독립 Windows 버전/폴더형 self-contained ZIP, 새 폴더에서 실행 검증, 기능별 증거/제약 문서와 GitHub PR |

근거: 루트 README.md, docs/FEATURE-BACKLOG.md (F-001–010과 후속 릴리스), NoteTaker/Playback, Shared/MeetingIntelligence, NoteTaker/Sync, Shared/WebSharing, Cloudflare/README.md.

Apple 전용 런타임은 Windows에서 실행 가능한 로컬 모델로 같은 사용자 기능을 제공한다. 멀티기기 동시 녹음의 자동 병합·음성 인증은 upstream의 명시적 제외 범위를 따른다. 일반 고객용 회원/결제/다중 고객 서버는 현재 upstream 기능에 없으며 별도 상품화 과제다.

## 진행 기록

- 2026-09-16: 원격 main과 현재 HEAD가 일치함을 확인. 이전 질의 응답에서 API 구조와 서비스 한도를 검증했으며 구현 완료로 계산하지 않음. 전체 이식은 진행 중이다.
- 2026-09-16: 집중 파형, 폴더 관리, 트레이·단축키·자동 생성 구현. [첫 이식 단계 검증](docs/implementation/FULL-PORT-STEP1.md). 화자/프로필/회의 분석/정리·보완/전체 동기화/최종 배포는 계속 미완료다.

## 다음 단계 조사 메모

- Apple 화자 런타임은 `Shared/MeetingIntelligence/LocalSpeakerBackend.swift`의 FluidAudio/Core ML이므로 Windows용 실행 엔진이 필요하다. Sherpa-ONNX의 공식 C# 오프라인 화자 구분과 speaker embedding API를 확인 중이다. NuGet `org.k2fsa.sherpa.onnx`의 현재 최신 인덱스는 1.13.8이며 패키지 repository commit은 `dc5583f49917e4c95f6e7d862bb378e4ed5e9076`이다. 아직 의존성을 추가하거나 화자 모델을 설치하지 않았다.
- 공식 예제: https://github.com/k2-fsa/sherpa-onnx/blob/master/dotnet-examples/offline-speaker-diarization/Program.cs . 바인딩 소스는 `scripts/dotnet/OfflineSpeakerDiarization.cs`, `OfflineSpeakerDiarizationConfig.cs`, `SpeakerEmbeddingExtractor.cs`에 있다. 모델·공개 다중 화자 WAV는 공식 `speaker-segmentation-models`, 임베딩은 `speaker-recongition-models` release에 있다.
- 데이터 호환은 `Shared/MeetingIntelligence/MeetingContracts.swift`, `MeetingWorkspace.swift`, `MeetingProfile.swift`, `MeetingStorage.swift`를 기준으로 한다. transcript의 발화 ID/시작·끝/화자 ID, insights 근거 검증, append-only edits와 재분석 후 적용, 텍스트 프로필과 로컬 음성 프로필 분리를 함께 구현해야 한다. Windows JSON에 그대로 저장하는 것과 Apple/Worker wire 호환은 별도 검증 대상이다.
