# 최신 Windows 이식 1차 검증

2026-09-16, upstream `2aaf053`, Windows 11 x64, 로컬 .NET 10 SDK. 전체 이식 완료 문서가 아니다. 전체 남은 범위는 [FULL-PORT-PLAN.md](../../FULL-PORT-PLAN.md)에 유지한다.

## 구현

- 집중 파형: 재생 위치 주변 300초, 전체 개요 표시, 절대 시간 탐색, 드래그 동안 뷰포트 고정. 파일 길이에 따라 초당 1개 수준의 피크를 유지하고 최대 86,400개로 제한한다.
- 폴더: 생성/이름 변경/삭제/수동 순서/드래그 순서/녹음 이동/접기·펼치기/개수 표시. 삭제한 폴더는 tombstone으로 보존하고 녹음 파일에는 손대지 않는다. 폴더가 없어져도 녹음은 전체 목록에 남는다. 폴더 생성과 목록 갱신 시 같은 녹음의 player와 재생 위치를 유지한다.
- 트레이: 창을 닫아도 계속 실행하는 설정, 열기/시작/완료/일시정지/재개/종료 메뉴. 종료만 현재 작업 취소·녹음 저장·자원 해제를 수행한다. Shell 아이콘 등록 실패 시 창을 숨기지 않는다. Explorer 재시작 메시지에 아이콘을 재등록한다.
- 선택형 전역 단축키: Ctrl+Alt+Shift+N/R/P. Windows 등록 실패 안내, 설정 해제·프로세스 종료 시 등록 해제. 로컬 Ctrl+Q로 명시적 종료.
- 선택형 자동 생성: 정상 녹음 완료 후 선택된 전사·요약 엔진 실행. 캡처 실패나 명시적 종료 중에는 새 AI 작업을 시작하지 않는다. 키 오류 등 생성 실패 시 저장된 녹음·이전 회의록은 유지한다.

## 증거

- 현재 소스의 자동 테스트: 88개 통과, 실제 장치 테스트 5개 기본 건너뜀. WPF 빌드는 경고/오류 없이 통과했다.
- `Windows/NoteTaker.Tests/WaveformViewportTests.cs`: 2시간 범위의 중간/시작/끝 매핑, 화면 좌표→절대 시간, 비정상 수치, 피크 보존·메모리 상한, 실제 15분 WAV의 피크 위치.
- `Windows/NoteTaker.Tests/RecordingFolderTests.cs`: 오디오 SHA/문서 보존, 순서·이름·tombstone 재시작 지속, 손상 파일 덮어쓰기 방지, 중복 이름과 삭제 대상 거절, remote revision 비교와 구버전 rank 생략 보존. 이 테스트는 전체 동기화를 입증하지 않는다.
- `Windows/artifacts/full-port-step2/result.txt`: 실제 WPF 버튼·이벤트·하위 메뉴, 생성/이동/정렬/삭제 시 재생 위치 20초 유지, 생성 오디오 SHA 보존. `folders.png`, `focused-waveform.png`를 직접 시각 검사했다.
- 최종 UI 재검증: `Windows/artifacts/full-port-final/ui-smoke/result.txt`. 검색 결과에 없는 폴더 내부 녹음을 클릭할 때 검색을 해제하고 정확한 녹음을 선택하는 회귀 검증도 포함한다. `compact-playback.png`의 최소 창 크기 화면을 직접 검사했다.
- `Windows/artifacts/full-port-desktop/result.json`: Windows Shell 아이콘 등록 성공, 창 닫기→숨김, 실제 전역 키 3개 등록/해제/재등록, Show 키의 HWND 메시지 복원, 명시적 종료 후 자원 해제. 물리 키 입력을 자동화한 증거는 아니다.
- 최종 native 재검증: `Windows/artifacts/full-port-final/desktop-smoke/result.json`도 통과했다.
- `Windows/artifacts/full-port-capture-flow/{off,missing-key,local-ai,exit-during-capture}.json`: 실제 WPF 녹음 버튼부터 완료까지 파일 기반 캡처 세션으로 검증했다. 트레이 숨김 중 캡처 유지, 일시정지/재개, 폴더에 녹음 저장, 비활성화/키 오류/종료 경로 확인. 사용자의 마이크를 녹음하지 않았다.
- `local-ai.json`: 68.66초 한국어 합성 음성을 실제 Whisper로 전사하고 실제 Ollama `qwen3.5:4b`로 자동 회의록 생성. 모델 비용 필드는 0. 실회의 품질 평가나 물리 장치 녹음 검증으로 확대 해석하지 않는다.

## 실행

```powershell
./Windows/build.ps1 test
./Windows/build.ps1 smoke-ui -ArtifactRoot Windows/artifacts/full-port-final
./Windows/build.ps1 smoke-desktop -ArtifactRoot Windows/artifacts/full-port-final
./.tools/dotnet/dotnet.exe run --project Windows/NoteTaker.Windows/NoteTaker.Windows.csproj -c Release -- --smoke-capture-flow Windows/artifacts/full-port-capture-flow Windows/artifacts/evaluation/samples/synthetic-meeting-ko.wav "$env:LOCALAPPDATA/AI-NoteTaker"
```

마지막 명령은 이미 준비된 Whisper/Ollama 모델과 별도의 합성 음성 파일이 필요하다. 각 실행은 새 격리 라이브러리를 만들어 기존 사용자 녹음을 건드리지 않는다.

Shell 계약 참고: [Shell_NotifyIconW](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shell_notifyiconw), [NOTIFYICONDATAW](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/ns-shellapi-notifyicondataw), [RegisterHotKey](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey).

화자 모델, 사용자 프로필, F-001–010 분석 기능, AI 보완/정리, 동기화·공유 전체 연동, 새 배포 ZIP과 최종 PR 검증은 아직 남아 있다.
