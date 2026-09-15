# 무료 전사·회의록 실행 계획

시작/구현 검증: 2026-09-14. 승인 범위: 무료 로컬 전사·요약 → Qwen3-ASR 비교 → 클로바노트 파일 연동. 원본 Swift 앱과 기존 Windows 데이터는 유지한다.

| 완료 기준 | 상태 | 증거 |
| --- | --- | --- |
| 전사/요약 공급자 분리, 기존 설정 호환 | 완료 | 독립 선택·전사만·재요약, 기존 OpenRouter 설정 유지 테스트 |
| Whisper + Ollama/Qwen 무료 실행 | 완료 | 실제 Windows UI와 배포 파일의 한국어 전사·요약, API 키 불필요, GPU 및 명시적 CPU 확인 |
| Qwen3-ASR 대안과 동일 입력 비교 | 완료 | 1.7B/0.6B 구현·실행, 합성/공개 한국어 표본, CER·시간·RAM 및 장치 전체 GPU 관찰 기록 |
| 클로바노트 파일 연동 | 완료 | 90분/173MB 분할, 90분 1초 실파일 경계 확인, TXT/SRT 미리보기·확인·원문 보존 |
| 캐시·중단·데이터 보존 | 완료 | 실제 206초 전사 중단 후 재개, 모델/언어/오디오 식별, 이전 캐시 이력, 가져온 원문 유지, 이전 회의록 안내 |
| UI·배포·사용 안내 | 완료 | 51개 자동 테스트, WPF 렌더링/버튼, 폴더형 self-contained Windows 0.3 ZIP, README와 검증 문서 |

로컬 처리 경계는 소스 및 loopback TCP 관찰로 확인했다. 네트워크 차단 재현은 테스트용 프록시 변경이 자동 승인 검토에서 차단되어 미실시다. 실제 클로바노트 계정 업로드·600분 여부, 실제 다중 화자 회의 품질, 9B/ARM은 별도 확인 대상이며 완료한 것처럼 표시하지 않는다.

세부 근거·측정 한계: [무료 AI 검증 기록](docs/implementation/FREE-AI-VERIFICATION.md). 연구 근거: [무료 전사 조사](docs/implementation/FREE-TRANSCRIPTION-RESEARCH.md). 실행: [Windows README](README.md).
