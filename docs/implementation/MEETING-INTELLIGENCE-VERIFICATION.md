# 회의 분석 기능 구현·검증 기록

상태: FluidAudio 연결 및 검증 완료. **Mac 1.3 (7) 설치·실행, Cloudflare 배포 완료.** iOS 1.3 (7)은 실물 기기용 서명 빌드와 IPA가 준비되었으며, 실제 iPhone 설치는 CoreDevice 통신 오류로 연결 확인이 남아 있다.

## 구현된 작업 범위

- 발화 시간과 화자를 보존하는 전사 자료, 근거 발화가 연결된 약속·요청·질문/답변·결정 흐름.
- 프로필의 이름·별칭·역할과 용어 사전, 기기 내부의 목소리 등록·삭제 및 녹음 중 상태 표시.
- 화자 이름·본인 표시·개별 발화 수정, 내 발화 필터와 해당 구간 재생.
- 프로젝트별 이전 회의 브리핑과 원본 발화 이동.
- 텍스트 프로필·분석 자료·수정 이력의 Cloudflare 동기화. API 키와 음성 등록 데이터 제외.
- 기존 Markdown 회의록 유지 및 상세 전사 캐시 재사용. 추가 자동 분석은 별도 설정으로 제공.

Mac과 iPhone의 동시 녹음을 한 회의로 합치는 기능은 포함하지 않았다.

## 변경 파일과 공통화

- `Shared/MeetingIntelligence/`: 두 플랫폼이 공유하는 데이터 계약, 분석 서비스, 프로필·화자 화면, 음성 처리와 저장 로직.
- `NoteTaker/App`, `NoteTaker/AI`, `NoteTaker/Playback`, `NoteTaker/Sync`: Mac 화면·설정·재생·동기화 연결.
- `iOS/NoteTaker/App`, `Audio`, `Views`, `Sync`: iPhone 화면·설정과 녹음 관찰 경로 연결.
- `Packages/AudioPipeline`: 선택적으로 PCM을 관찰하는 경로. 모델 추론은 녹음 입출력 콜백에서 실행하지 않음.
- `Cloudflare/worker.mjs`, `migrations/0004_meeting_intelligence.sql`: 텍스트 프로필·분석 자료·수정 이력 API와 저장소.
- Mac/iOS 테스트와 한국어 문자열 카탈로그.

별도의 플랫폼별 분석 구현을 늘리는 대신 공통 Swift 코드를 사용한다. 기존 전사 캐시를 재사용하며 수동 수정은 생성 결과와 독립된 이력으로 저장한다.

## 확인된 검증

| 범위 | 결과 | 로컬 증거 |
| --- | --- | --- |
| Mac 단위 테스트 | 359개 통과 | `build/meeting-intelligence/release-mac-tests.log` |
| iPhone 시뮬레이터 단위 테스트 | 234개 통과 | `build/meeting-intelligence/release-ios-tests.log` |
| 정적 화면 렌더 | Mac 1개 / iOS 2개 XCTest 통과 | 같은 Xcode 로그, `build/visual-qa/` |
| 실제 FluidAudio 모델 | Mac·iOS 시뮬레이터 공개 음성 검증 통과 | `build/fluidaudio-validation/model-validation-*.json` |
| 모델 캐시 복구 | 캐시만으로 재시작, 손상된 캐시 복구 통과 | `build/meeting-intelligence/fluidaudio-cache-recovery-tests.log` |
| AudioPipeline | 237개 통과 | `build/meeting-intelligence/audio-package-tests.log` |
| Cloudflare Worker | 45개 통과 | `build/meeting-intelligence/worker-tests.log` |
| 로컬 workerd·D1·R2 | 마이그레이션 0001–0004, 신규 API와 기존 API 호환 검증 통과 | `build/meeting-intelligence/worker-runtime-tests.log` |

최종 통합 Xcode·패키지 검증은 순서대로 실행하고 병렬 작업 수를 2로 제한했다. 회의 내용 분석 테스트는 가짜 AI 서비스를, 오디오 경로 테스트는 합성 오디오를 사용했다. 실제 음성 모델 검증에는 출처를 기록한 공개 LibriSpeech 음성을 사용했다. 유료 OpenRouter 요청, 실제 사용자 목소리 수집, 전역 키보드·마우스 조작이나 XCTest UI runner를 사용하지 않았다.

Mac과 iPhone 390pt 화면에서 프로필·전사·약속/요청·질문/답변·결정·화자 수정·브리핑을 확인했다. 한국어 줄바꿈, 근거 재생 버튼, 주요 화면의 가로 잘림을 확인했다. 정적 자료에는 테스트용 회의와 프로필이 사용되었다.

발화 구간 재생 종료·늦은 시작 취소·새 재생 보호와 단어별 시간 우선 처리도 양쪽 단위 테스트에 포함했다.

## 실제 모델 검증

FluidAudio 0.15.6을 두 앱에 정확한 버전으로 연결했다. 화자 인식은 `pyannote_segmentation.mlmodelc`와 `wespeaker_v2.mlmodelc`를 사용하고, 로컬 모델 폴더는 앱 지원 디렉터리의 `AI-NoteTaker/VoiceModels/speaker-diarization`이다. 라이브러리·모델의 고지와 라이선스 원문을 함께 포함했다.

공개된 30.9초 두 화자 음성에서 서로 다른 화자 ID 2개를 확인했다. 한 발화로 등록하고 다른 발화로 확인한 목소리 비교는 동일 화자 약 0.843, 다른 화자 약 0.211의 코사인 유사도를 보였다. 실제 `OwnerVoiceManager`의 실시간 상태도 동일 화자 `owner`, 다른 화자 `other`를 반환했다. 이 수치는 해당 공개 테스트 자료의 결과이며 일반적인 정확도 보장이 아니다.

기본 설정에서 다른 목소리를 하나로 합치는 현상을 재현한 뒤, SDK가 문서화한 스트리밍 화자 비교 기준(거리 0.65, 임베딩 갱신 0.45)을 사용하도록 수정했다. 손상된 모델 폴더가 있어도 사용자가 모델 준비를 다시 실행하면 SDK의 검증·복구 경로를 사용한다. 캐시를 읽는 시작 경로는 새 다운로드를 시작하지 않는다.

## 배포·설치

- Mac: 버전 1.3, 빌드 7. 서명을 검증하고 `/Applications/AI-NoteTaker.app`에 교체 설치한 뒤 실행을 확인했다. 이전 앱과 라이브러리는 `~/Library/Application Support/NoteTaker Backups/`에 보관했다.
- Cloudflare: 마이그레이션 0004 적용, Worker `05739fdc-f5e9-4403-b0c5-7d4ecd87e962` 배포. 기존 녹음 수 2개가 유지되었고, 인증된 health/profile/intelligence/meeting-edits/recordings 조회가 모두 HTTP 200을 반환했다. 검증용 가짜 녹음은 운영 서버에 쓰지 않았다.
- iOS: 버전 1.3, 빌드 7의 Release 앱·IPA 서명을 검증했다. 서명 프로필에 대상 iPhone이 포함됨을 확인했다. `build/releases/AI-NoteTaker-iOS-1.3-build7.ipa`는 개인 설치용이며 공개 저장소에 올리지 않는다.
- 실물 iPhone: 기기 조회는 가능했으나 설치 시 CoreDevice 연결 시간 초과/기기 탐색 오류가 발생했다. USB 연결과 잠금 해제 후 설치 및 기기 내 모델 준비를 확인해야 한다. 설치 완료로 기록하지 않는다.

실제 사용자 목소리는 수집하지 않았다. 개인 목소리 인식은 설치된 앱의 설정 → 프로필에서 직접 등록한 뒤 사용할 수 있다. OpenRouter 유료 요청에 대한 새 실서비스 생성 테스트는 수행하지 않았다.

소스의 기준은 `Shared/MeetingIntelligence/`와 플랫폼 소스다. `build/meeting-intelligence/*.draft.swift`는 검토 중간 자료이므로 소스 위에 다시 복사하지 않는다.
