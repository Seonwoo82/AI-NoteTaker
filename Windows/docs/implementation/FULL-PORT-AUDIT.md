# Windows 전체 이식 감사

2026-09-16. 기준은 원격 `origin/main`의 `14172b2ee89fe26e6dd16ccb7619654629a40491`, 루트 README, `docs/FEATURE-BACKLOG.md`의 F-001–010 및 이후 출시 기능, 실제 Swift 설정·라이브러리·재생 코드다. 최신 iOS 녹음 시작·빈 파일 수정까지 병합하고 Windows 대응을 대조했다. Windows의 현재 기능만 기준으로 완료 범위를 줄이지 않는다. **전체 목표는 아직 완료가 아니다.**

## 요구사항과 증거

| 요구사항 | 현재 구현과 확인한 증거 | 미확인 범위 |
| --- | --- | --- |
| 최신 git 버전 반영, Apple 코드와 Windows 분리 | fetch한 원격 main이 HEAD의 조상임을 확인. `git diff origin/main --name-only -- NoteTaker Shared iOS`가 비어 있다. Windows 앱·버전·빌드·배포가 `Windows/` 아래에 있음 | PR 병합은 수행하지 않음 |
| Apple UI 컴포넌트·아이콘 | `Components/AppleTheme.xaml`, WindowControls, AppleIcon, WaveformControl; 원본 PNG를 ICO로 묶은 앱 아이콘. 밝은/어두운·작은 창의 WPF 렌더와 실제 EXE 아이콘, 단계 18의 실제 폴더 드래그 확인 | 모든 컴포넌트의 물리 입력·다른 DPI 환경 |
| 마이크/시스템/혼합 녹음, 일시정지·완료·종료 | `AudioRecorder`, 파일 입력을 사용하는 `SmokeCaptureFlow`와 `SmokeDesktop`의 실제 WPF 흐름; 저장 WAV·폴더·자동 AI·종료 대기 확인 | 사용자 마이크, Bluetooth/장치 분리/절전/실제 수시간 혼합 입력 |
| 원본 설정의 개별 음량·모드·장치 보존 | 단계 17의 `CapturePreferencesTests`, `SmokeUi.CapturePreferences`; 실제 PCM 믹서 값·음소거·포화·재시작·녹음 중 잠금 확인 | WASAPI 장치에서 증폭량 실측 |
| 최신 녹음 시작·세션 소유권·빈 파일 보호 | 단계 19의 세션별 콜백·시작 보호 소스 대조와 Core 완료/복구 검사. 단계 20 최신 EXE의 파일 기반 WPF 녹음·완료·종료·자동 AI와 PCM 설정 적용 통과 | WPF 빈 입력 실패의 별도 실행·실제 장치 중단 검증 |
| 라이브러리 검색·즐겨찾기·이름·가져오기·내보내기 | `SmokeUi`, `SmokeUi.Commands`, `SmokeUi.Files`, `CoreTests`, `LibraryFilesTests`; 원본 해시/취소/기존 파일 보존 확인 | OS 파일 선택창의 물리 입력 |
| 삭제·복원·영구 삭제·30일 정리 | `LibraryFilesTests`, `AudioShareFilesTests`, 실제 WPF 확인/취소/오래된 확인 거부. Worker 왕복에서 원격 복원 시 오디오·문서·수정 이력 재수신 | 배포된 개인 서버·Apple 기기의 왕복 |
| 폴더 생성/이름/삭제/이동/펼침/순서·선택 유지 | `RecordingFolderTests`, `SmokeUi` 폴더 흐름, `SmokeSync`; 생성 시 목록 유지·선택 폴더 녹음/가져오기·삽입선 앞/뒤·재시작 보존. 단계 18 실제 포인터로 폴더 안팎 이동·앞뒤 정렬과 저장 JSON 확인 | 물리 이동 직후 앱 재시작은 별도 미실행 |
| 집중 5분 파형·전체 개요·탐색 | `WaveformViewportTests`, 실제 생성 WAV와 WPF 좌표→시간·드래그 범위 유지 검사 | 다른 DPI/다중 모니터 환경 |
| 트레이·키보드·자동 생성 | `SmokeDesktop`, `SmokeCaptureFlow`, `SmokeUi.Commands`, `SmokeSync`; Windows 트레이/단축키 등록·메시지 전달·Ctrl 완료/동기화·편집 중 보호 확인 | 모든 물리 키 조합과 장시간 트레이 녹음 |
| 무료 로컬 전사/회의록, 선택적 클라우드, 모델 준비 | 실제 Whisper/Qwen3-ASR/Ollama 4B 및 9B 추론·취소/캐시; `LocalAiTests`, `ModelCatalogTests`, `CoreTests`의 API·오류·출력 예산 계약 | 유료 API 실제 청구·일반 PC별 성능 |
| 출력 언어·재생성·캐시·생성일·제공자 비용 | `SettingsWindow`, `MeetingNotesService`, `SmokeUi`; 알려진 비용과 미보고 비용을 구분. 전사 재사용·이전 성공 문서 보존 | 실제 제공자의 모델별 비용 보고 차이 |
| F-001 발화 시간·화자·번호·미확인·목록 가상화 | `TranscriptTimingTests`, `MeetingIntelligenceTests`, 실제 Whisper/Sherpa `SmokeParticipants`; 3,000개 발화 중 마지막 컨테이너가 생성되지 않은 것을 확인 | 한국어 실제 다자 회의 DER/정답 기반 정확도 |
| F-002 등록/재등록/취소/삭제·입력 표시·라이브 나 | `VoiceEnrollmentSession`, `SmokeProfile`; 공개 음성으로 10초 등록·기존 프로필 보존·3초 실시간 추론·pause/cancel·기기 로컬 저장. 단계 17 PCM 입력 감지 표시 확인 | 사용자 목소리와 혼합 회의의 정확도 |
| F-003 내 발화·연속 재생·오디오 충돌 차단 | PCM 선택 구간 단위 검사, 실제 출력 장치의 종료/일시정지 검사, `SmokePlaybackGuards`의 실제 프로필 창·전환·삭제 상태 보호 | 사람의 실제 음성 청취 |
| F-004–006 약속/요청·업무 상태·질문답변·결정 흐름 | `MeetingAnalysisTests`, `SmokeMeetingAnalysis`, 근거 ID·범주 검증·원자적 저장·필터·실제 Qwen 호출 | 4B/9B 모두 의미 오류 존재. 파이프라인 통과를 업무 정확도 보장으로 사용하지 않음 |
| F-007 프로젝트와 이전 회의 브리핑 | `MeetingBriefing`, WPF 프로젝트/단일 선택/원본 근거 이동, Worker 계약 왕복 | 실제 Apple 기기 UI |
| F-008 프로필·별칭·역할·용어·프롬프트·원문 보존 | `MeetingProfileTests`, `SmokeProfile`, `SyncDocumentsTests`; 프롬프트 크기·표시 주석·비밀 제외 확인 | 배포 서버 사용자 데이터 왕복 |
| F-009 수동 이름/본인/발화/업무/프로젝트 수정 | 별도 edit 문서, 재분석 동일 화자 연결·상태 보존, 모호한 수정은 미연결로 보관; 실제 Worker 재시작/재수신 검사 | 한국어 다자 음성의 그룹 재연결 정확도 |
| F-010 전체 동기화와 기기별 키 안내 | `LibrarySyncTests`, `SyncDocumentsTests`, `SmokeSync`; Worker HTTP+SQLite·영속 대기/수신함·충돌·중단/재시작·자동/수동·완료 재진입 보호 | R2는 파일 시스템 fixture. 실제 Cloudflare 배포/Apple 기기는 미검증 |
| 전사 정리·보완 미리보기/적용/취소·목차 | `NotesEditingTests`, `SmokeNotesEditing`; 원문/숫자/시간/발화 ID 보존·중단/충돌 보호·실제 로컬 모델·WPF 목차 이동 | 자연 업무 회의의 의미 보존 |
| 지속 웹 공유·7일 만료·교체/해제 | `SmokeWebSharing`의 실제 WPF+Worker 왕복·익명 열람·재시작·응답 유실 복구; 제목/Markdown만 전송 | 공개 배포 서버 연결 |
| Windows 시스템 오디오 파일 공유 | 실제 WinRT StorageFile·사본 해시·정리/purge 및 요청별 응답·timeout·취소·중복 콜백 검사. 단계 20 새 EXE에서 실패 후 재시도와 올바른 COM 오류 안내 WPF 검사 통과 | **DataRequested timeout. 탐색기 공유에서도 창 미표시. 시스템 프로세스 재시작 승인 대기, 최종 게이트 미통과** |
| Windows 배포·PR·라이선스 | 폴더형 self-contained ZIP, 별도 음성 worker/native DLL, 배포 고지, Draft PR #5. 단계별 ZIP 해시와 새 폴더 검사 기록 | **최신 ZIP의 전체 게이트 통과와 Draft 해제 전 최종 확인 필요** |

## 현재 결론과 다음 순서

소스 대조에서 발견한 녹음 설정·입력 감지·생성 시각/비용 누락은 단계 17에서 수정했다. 기존 자동 검사, 실제 로컬 모델, 실제 WPF/로컬 Worker 왕복은 각각 그 범위의 증거로 유지한다. 모델 의미 오류, 생성 무음의 장치 출력 검사와 실제 음성 품질, 로컬 Worker와 배포 서버를 같은 성공으로 취급하지 않는다.

최신 upstream 병합과 실제 PCM 프레임 기반 완료/복구 보호를 반영한 단계 19 소스에서 비장치 테스트 241개와 WPF Release 빌드가 통과했다. 단계 20에서 같은 후보를 새로 압축 해제해 전체 실행 스크립트를 수행했고 12개 경로 통과·마지막 시스템 오디오 공유 실패로 종료했다. 정적 파일 검증과 실행 결과는 별도 보고서로 보존하며 `Passed=false`를 유지한다. 이전 단계 17 EXE의 물리 폴더 드래그 4개 동작도 그 버전의 증거로 구분한다. [단계 20](FULL-PORT-STEP20.md).

사용자가 데스크톱 사용을 다시 허용했다. 최신 EXE에서도 시스템 공유 timeout이 재현됐고 같은 생성 무음 WAV를 파일 탐색기의 공유 버튼으로 열어도 공유 창이 나타나지 않았다. 설치된 패키지·실행 서비스·기존 이벤트 로그의 읽기 확인으로는 원인을 확정하지 못했다. 앱 외부의 문제 가능성을 조사하되 이를 앱 구현의 정상 동작 증명으로 취급하지 않는다. ShellExperienceHost만 재시작하는 조치는 사용자 승인 전이며 실제 공유 창과 DataRequested 성공은 여전히 필요하다.

이후 추가 폴더 보존 검증에서 사용자가 Escape로 Computer Use를 중단했다. 최신 후보의 폴더 A 이동만 UI와 저장 파일에서 확인했고 정렬·재실행은 미완료다. 데스크톱 조작 재허용과 시스템 공유 프로세스 재시작 승인을 기다리며 자동 UI 조작을 중단한다. 자세한 중단 범위는 단계 20에 기록했다.

개인용 Cloudflare 서버의 기존 배포에는 Windows 플랫폼 마이그레이션/Worker 갱신이 필요하다. 사용자·upstream 소유 서버를 임의로 배포하거나 Apple 기기 검증을 로컬 fixture로 대신하지 않는다. 회원·결제·다중 고객 SaaS 서버, 다중 기기 동시 녹음 자동 병합, 음성 인증과 backlog의 향후 후보는 원본 Windows 이식의 구현 완료로 새로 포함하거나 이미 구현됐다고 주장하지 않는다.
