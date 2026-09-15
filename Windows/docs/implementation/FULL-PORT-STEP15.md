# 단계 15: Windows 오디오 공유·명령·앱 아이콘

확인일: 2026-09-16. upstream `2aaf0532e48016b32571c7929984a8f474e812ee`를 다시 fetch했으며 이미 현재 브랜치에 포함되어 있다. Apple Swift 소스는 변경하지 않는다.

## 이식한 동작

- 녹음 화면과 우클릭 메뉴의 **오디오 공유…**에서 실제 Windows DataTransferManager 공유 창을 연다. Apple `SharedAudioFile`/`ShareLink`에 대응하며 웹 회의록 공유와 별개다. 선택한 녹음의 저장된 WAV를 제목에 맞는 파일명으로 복사하고 WinRT StorageFile로 전달한다. 원본 오디오와 메타데이터는 바꾸지 않는다.
- 받는 앱이 나중에 읽을 수 있도록 공유 사본을 사용자 임시 폴더의 `AI-NoteTaker-Share/<라이브러리 해시>-<녹음 ID>-<공유 ID>/`에 둔다. 녹음의 `SharedAudio/<공유 ID>/`로 소유 관계를 추적하고 임의 저장 경로는 신뢰하지 않는다. Windows StorageFile 경로 제한을 피하도록 사본 경로를 240자 이하로 유지한다. 24시간이 지난 사본은 다음 목록 로드에서 정리하며 해당 녹음의 영구 삭제에도 포함한다. 공유 사본은 동기화 업로드 대상이 아니다. 경로 경계·연결 폴더 검사, 취소·상태 변경 검사와 원자적 파일 복사를 적용했다. 받는 앱이 파일을 잠그면 소유 표식을 유지하고 이후 정리를 재시도한다.
- 원본 `LibraryCommands.swift`의 키 조합을 Windows Ctrl로 대응했다. `Ctrl+Enter` 녹음 완료, `Ctrl+Shift+E` 오디오 내보내기, `Ctrl+Shift+R` 탐색기에서 파일 선택, `Ctrl+Shift+S` 동기화, `Ctrl+Shift+L` 즐겨찾기, `Enter`/`F2` 이름 변경, `Ctrl+←/→` 15초 이동. 기존 Ctrl+N/O/F/쉼표/Q와 Space도 유지한다. 텍스트 입력 중 새 녹음·라이브러리 편집·재생 이동을 막고 반복 키 입력으로 작업이 중복 시작되지 않게 한다.
- 파일 가져오기 대화상자를 모달 작업으로 취급해 자동 동기화가 끼어들지 않게 했다. 선택한 폴더로 가져오기와 취소도 실제 가져오기 경로에서 검증했다. 휴지통의 동작 막대는 복원·영구 삭제를 중심으로 표시한다.
- 저장소의 원본 AppIcon PNG 16/32/64/128/256px를 변경 없이 ICO 컨테이너에 넣었다. `tools/Create-AppIcon.ps1`로 재생성할 수 있으며 WPF 창과 EXE 아이콘에서 같은 자산을 사용한다. 트레이는 기존 소형 파형 아이콘을 유지한다.

## 빌드와 배포 의존성

WinRT 공유 API를 위해 WPF 앱만 `net10.0-windows10.0.19041.0`으로 지정하고 SDK projection 버전을 `10.0.19041.57`로 고정했다. Core·음성 worker는 기존 TFM을 유지한다. 부모와 worker의 TFM이 달라도 MSBuild `GetTargetPath`로 worker 출력 폴더를 찾아 복사하며 publish에서도 부모 TFM을 전달하지 않는다. 공유 DLL과 C#/WinRT 런타임, 해당 배포 고지를 폴더형 self-contained ZIP에 포함한다. 실제 확인 환경은 Windows 11 x64이며 Windows 10 실기기 검증은 아니다.

`Microsoft.Windows.SDK.NET.dll`의 SDK 배포 조건과 C#/WinRT 소스의 MIT 고지를 구분했다. 원문은 `licenses/WINDOWS-SDK-LICENSE.rtf`, `licenses/CSWINRT-LICENSE.txt`다. 공식 근거: [데스크톱 WinRT 공유](https://learn.microsoft.com/en-us/windows/apps/develop/ui/display-ui-objects), [WPF ShareSource 예제](https://github.com/microsoft/Windows-classic-samples/blob/main/Samples/ShareSource/wpf/MainWindow.xaml.cs), [SDK 라이선스](https://aka.ms/WinSDKLicenseURL), [C#/WinRT 라이선스](https://github.com/microsoft/CsWinRT/blob/master/LICENSE).

## 검증

- Release 전체 테스트 **227 통과 / 5 실제 장치 테스트 건너뜀 / 0 실패**: `Windows/artifacts/test-step15/step15-final.trx`. 공유 사본의 제목/바이트/불변성, 원본 교체 후 사본 보존, 영구 삭제, 취소·삭제 상태 거부, 오래된 사본만 정리, Windows 예약 파일명, 깊은 라이브러리와 잠긴 공유 파일 정리 재시도를 검증했다.
- WPF Release 빌드 **경고 0 / 오류 0**. 서로 다른 TFM의 speech worker가 앱 출력 폴더에 복사되는 것을 확인했다.
- `Windows/artifacts/audio-share-step15/result.json`: 생성한 1초 무음 WAV를 실제 Windows 공유 API에 전달했으며 네이티브 `DataRequested` 이벤트와 단일 파일의 바이트 해시를 확인했다. 받을 앱을 선택하거나 메시지를 보내지 않았다. 외부 수신 완료와 실제 공유 창 렌더링을 증명하는 검사는 아니다.
- `Windows/artifacts/ui-step15-final/library-commands.json`: 실제 단축키 dispatcher와 WPF 이름 변경 창, 선택 폴더로 실제 WAV 가져오기, 취소, 편집 중 보호, 즐겨찾기·파일 위치·내보내기·삭제·휴지통 보호, 15초 앞뒤 이동 검증. 파일 선택/탐색기 실행은 fixture 콜백이므로 물리 키 입력이나 OS 파일 대화상자 조작을 주장하지 않는다.
- `library-files.json`: 공유 버튼에 연결된 실제 WinRT 파일의 해시, 내부 공유 사본과 영구 삭제의 연결, 이전 삭제/내보내기 회귀 검증. EXE에서 추출한 아이콘과 작은 창의 동작 막대·휴지통 화면도 렌더링해 확인했다.

이 단계의 코드가 포함된 새 ZIP과 완료/동기화 단축키의 통합 검증은 아래 배포 결과에 기록한다. 기존 단계 14 ZIP에는 새 시스템 공유 기능이 없다. 실제 사용자 마이크, 다른 앱으로 파일 전송, Apple 실기기 및 공개 Cloudflare 서버는 이번 검사에 사용하지 않았다.

## 현재 후보 ZIP의 검증 결과

공유 경로 수정을 반영한 후보는 `AI-NoteTaker-0.4.0-win-x64.zip`, `0.4.0+7f7e4f51621b9d51d37795b3d29e1281bb2af37d`, 657,292,868바이트다. SHA256: `76079C4AF88DFA260E9F294F3FA033888D0E521543CCF79C7B10CD5B7B1FE012`.

새 `Windows/artifacts/verify-step15-3d484db0` 폴더의 UI·Whisper·Qwen·트레이·파일 입력 녹음·참여자·프로필·회의 분석·회의록 보완 **9개가 통과**했다. Ctrl+Enter로 녹음을 완료하고 실제 Whisper/Ollama 자동 생성을 마치는 경로도 포함한다. `step15-core-package.json` 및 ZIP 옆 `.verification.json`은 네이티브 오디오 공유 1개가 남아 있으므로 `Passed: false`와 `Pending`을 명시한다. 이전 ZIP의 성공 보고서를 현재 ZIP의 성공으로 재사용하지 않는다. 정상 검증 스크립트도 실패 시 해시·완료 항목·실패 원인을 먼저 저장하도록 보완했다.

같은 새 ZIP의 `sync-step15-cache-portable/result.json`은 실제 WPF/Worker/SQLite에서 자동/수동·Ctrl+Shift+S·모달 대기·완료 재진입 차단·오프라인 재시작·취소 대기·오디오 버전 갱신 검증 통과다. R2는 파일 시스템 대체 구현이며 배포된 서버 검증이 아니다.

추가 실제 출력 장치 검사 **1개 통과**: `test-step15/selected-output.trx`. 생성한 무음 WAV의 두 선택 구간을 NAudio 출력 장치에서 끝까지 처리하고 최종 위치·일반 재생 복귀·일시정지를 확인했다. 마이크/환경 오디오/실제 회의 파일을 사용하지 않았으며 사람이 들은 음성 품질의 증거는 아니다. 이 opt-in 검사 추가 후 장치 검사 항목은 6개이며, 앞선 전체 227개 통과/5개 건너뜀 기록과 실행 시점을 구분한다.

## 포터블 검사에서 발견한 긴 경로

첫 후보 `326e194`의 새 압축 해제 위치 `verify-package-d8f14660`에서 공유 파일 경로가 265자가 되어 `StorageFile.GetFileFromPathAsync`가 실패했다. 오류를 비대화형 smoke 로그에 기록하는 목록에서도 신규 모드를 빠뜨려 메시지 창이 떠 있었으므로 함께 수정했다. 확장 경로 접두사도 실제 Windows API에서 같은 오류가 났다(`audio-share-step15-long/error.txt`). 짧은 사용자 임시 캐시를 도입한 뒤 `audio-share-step15-active/prepared.json`에서 원본 271자·공유 경로 150자와 실제 WinRT 파일 준비를 확인했다. 긴 제목/깊은 라이브러리/잠긴 사본의 purge 재시도 회귀 검사도 추가했다.

이후 네이티브 DataRequested 검사는 제한 시간 안에 이벤트를 받지 못했다. 컴퓨터 사용 도구로 확인한 시점에는 별도 PC 보안 진단 창이 앱 위를 가리고 있었다. 해당 창의 사용자 조치를 요청했으며 이를 직접 조작하지 않았다. 창을 치운 뒤 원인을 더 확인해야 하므로, 이 현상을 보안 창 때문이라고 확정하거나 현재 후보의 네이티브 공유 검사가 통과했다고 기록하지 않는다. 첫 개발 실행 성공과 배포본의 전체 성공은 구분한다. 같은 첫 후보의 `sync-step15-portable/result.json`은 완료 중 중복 요청 차단·Ctrl+Shift+S를 포함한 실제 WPF/Worker 동기화 검사 통과다.
