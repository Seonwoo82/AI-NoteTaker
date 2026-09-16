# 최신 ZIP 실행 검증과 Windows 공유 비교

2026-09-16. 사용자가 데스크톱 사용을 다시 허용한 뒤 단계 19 후보를 검증했다. 코드나 ZIP은 변경하지 않았다. 앱 버전은 `0.4.0+f39c563ef5b3325d775e4626eb52594b875c6985`, upstream은 `14172b2ee89fe26e6dd16ccb7619654629a40491`이다.

## 같은 새 압축 해제본의 전체 게이트

`Windows/verify-package.ps1 -AllFeatures -Archive Windows/artifacts/step19/AI-NoteTaker-0.4.0-win-x64.zip`을 실행했다. 새 폴더 `Windows/artifacts/verify-package-18d27d9f`에서 **13개 중 12개 통과, 마지막 시스템 오디오 공유 실패**로 종료했다. 보고서 `Windows/artifacts/step19/AI-NoteTaker-0.4.0-win-x64.verification.json`의 `Passed=false`가 현재 결과다.

| 경로 | 결과와 범위 |
| --- | --- |
| ui | 통과. 밝은/어두운 UI, 명령·폴더·파일·녹음 설정. 공유 실패 후 재시도 활성화 및 공유 COM 오류를 마이크 권한으로 안내하지 않는 새 WPF 검사도 실행됨 |
| playback-guards | 통과. 프로필·녹음 전환·삭제 상태의 재생 보호 |
| whisper / qwen | 각각 통과. 제공한 음성 파일의 실제 로컬 모델 실행 |
| desktop / capture-flow | 각각 통과. 트레이·단축키 등록, 생성 파일 기반 녹음·일시정지·완료·종료와 자동 AI. 새 프레임 기반 완료 경로가 실제 WPF에서 실행됨 |
| participants / profile | 각각 통과. 공개 음성의 실제 Whisper/Sherpa 및 프로필·실시간 owner·자동 분석 |
| meeting / notes | 각각 통과. 실제 로컬 요약 모델, 회의 분석·문서 보완과 UI 흐름 |
| sync / sharing | 각각 통과. 독립 WPF 라이브러리와 실제 로컬 Worker HTTP/SQLite, 동기화·웹 공유·재시작·실패/복구. R2는 파일 시스템 대체 구현 |
| audio-share | 실패. 실제 WinRT StorageFile은 준비했으나 15초 내 DataRequested가 오지 않음 |

WPF의 정상 녹음 완료는 이번 실행으로 확인했다. 빈/불완전 파일 거부는 단계 19의 Core 테스트로 확인했으며 별도의 실제 WPF 빈 입력 동작을 실행한 것으로 확대하지 않는다. 이전 ZIP의 결과를 새 버전의 성공으로 옮겨 적지 않았다. UI의 `meeting.png`와 `dark-notes.png`를 열어 렌더링도 확인했다.

ZIP SHA-256은 `9DB74DD0D63B8D35FC527AFF2112EB65AD3A32CBF1FBF40A259EAABB15FF6877`, 크기는 657,329,437 bytes다. 앞서 835개 파일을 비교한 정적 증거는 같은 폴더의 `AI-NoteTaker-0.4.0-win-x64.static-verification.json`에 별도로 보존했다. ZIP 내 문서는 빌드 시점의 단계 19 기록이며 이후 실행 결과는 이 문서와 sidecar 보고서를 따른다.

## 앱 밖의 공유 경로 비교

최신 후보의 단독 `--smoke-audio-share`도 동일하게 timeout이었다. `Windows/artifacts/audio-share-resume-162226`에 준비 상태와 오류가 남아 있다. owner 창은 표시됐지만 공유 창은 표시되지 않았다.

이전에 생성한 무음 `native-step18/library/Recordings/3d8940ea-530a-423a-aa8c-b0e0dece12fa/audio.wav`를 파일 탐색기에서 선택했다. 활성화된 공유 버튼을 클릭한 뒤 다시 창 목록과 화면을 확인했지만 시스템 공유 창은 나타나지 않았다. 받는 앱 선택·외부 전송은 하지 않았다. 확인 화면은 Computer Use 도구 출력이며 별도 스크린샷 파일은 저장하지 않았다.

Windows 빌드 26200.9457에서 ShellExperienceHost와 Client.CBS 패키지는 정상 상태로 등록돼 있고 관련 서비스는 실행 중이었다. 가까운 시각의 기존 Application/TWinUI/AppModel 기록에서 원인을 특정할 공유 오류를 찾지 못했다. 이는 OS 정상 동작을 증명하지 않으며, 특정 서비스나 보안 프로그램을 원인으로 확정하지 않는다.

[Microsoft의 공유 소스 문서](https://learn.microsoft.com/en-us/windows/apps/develop/windows-integration/integrate-sharesheet-send)는 WPF의 packaged/unpackaged 앱 모두 HWND별 interop을 사용하도록 설명하며 현재 구현도 이 경로를 따른다. 탐색기에서의 재현은 앱 외부 문제 가능성을 보여주지만 앱 구현의 정상 작동을 대신 증명하지는 않는다.

Windows 공유 UI 프로세스 `ShellExperienceHost`만 한 번 재시작하는 제안을 사용자에게 확인 요청했다. 앱 바깥의 시스템 프로세스에 영향을 주므로 답변 전에는 실행하지 않는다. 현재까지 Windows 프로세스 종료·패키지 재등록·보안/개인정보 설정 변경은 하지 않았다. 원인 해결과 실제 공유 요청 성공 전까지 Draft와 미완료 판정을 유지한다.

## 추가 수동 검증의 중단

같은 후보를 `Windows/artifacts/native-step21/library`의 격리 무음 fixture로 실행해 녹음을 폴더 A에 드래그했다. UI의 녹음 1개 표시와 저장된 `folderId=a4e75c42-1541-46f8-942d-3a2747b3f01d`를 확인했다. 이어 폴더 순서를 바꾸려던 중 사용자가 물리 Escape 키로 Computer Use를 중단했다. 저장 순서는 A/B/C 그대로였으며 정렬·앱 재실행 후 보존은 확인하지 않았다. 이는 중단된 검증이지 정렬 기능 실패 판정이 아니다.

이후 화면·입력 조작을 멈추고 저장 파일만 읽어 결과를 기록했다. 사용자가 다시 데스크톱 조작을 허용하기 전에는 자동으로 재개하지 않는다. 공유 UI 프로세스 재시작도 승인되지 않았고 실행하지 않았다. 12개 실행 경로의 통과와 시스템 공유 실패, Draft 상태는 유지한다.
