# 시스템 공유 요청 처리와 실제 폴더 드래그

2026-09-16. Windows 시스템 공유는 아직 완료로 판정하지 않는다. 보안 진단 안내창을 닫은 뒤에도 `DataRequested`가 오지 않았으며, 공식 C#/WinRT 어댑터로 교체한 개발 실행에서도 같은 timeout이 발생했다. 이후 사용자가 컴퓨터를 사용해야 한다고 알려왔으므로 네이티브 앱·공유 창·탐색기를 더 열거나 조작하지 않고 코드와 창 없는 검증만 진행했다.

## 이전 데스크톱 검증에서 확인한 내용

단계 17의 동일한 포터블 EXE와 생성한 2초 무음 WAV 두 개를 사용했다. 격리 라이브러리는 `Windows/artifacts/native-step18/library`이며 사용자 녹음은 사용하지 않았다.

- 실제 포인터로 녹음을 폴더 A에 드래그해 UI 개수와 저장된 `folderId`가 A로 바뀌는 것을 확인했다.
- 같은 녹음을 미분류 영역으로 옮겨 `folderId`가 null로 돌아오는 것을 확인했다.
- 폴더 C를 A 앞에 넣어 C/A/B 순서, 다시 B 뒤에 넣어 A/B/C 순서가 되는 것을 UI와 `recording-folders.json`의 `sortOrder`에서 확인했다.
- 이 물리 입력 직후의 앱 재시작은 별도로 확인하지 않았다. 기존 자동 재시작 검증과 구분한다. 화면은 도구 결과로 확인했으며 별도 스크린샷 파일은 저장하지 않았다.

보안 진단 안내창이 없는 상태에서 시스템 공유를 다시 실행했지만 15초 후 timeout이었다. 활성 owner와 실제 `StorageFile` 준비는 확인됐고 공유 창은 나타나지 않았다. 일반적인 창 표시 방식으로 실행한 기존 포터블 EXE도 같은 결과였다. 공식 어댑터 교체만으로 해결됐다고 주장하지 않으며 특정 보안 앱이나 숨김 시작 옵션을 원인으로 확정하지 않는다. 탐색기 공유 비교는 완료하지 않았다.

관련 로컬 증거는 `Windows/artifacts/audio-share-step18-clear/prepared.json`, 같은 폴더의 `error.txt`, `audio-share-step18-official/error.txt`, `audio-share-step18-visible/error.txt`다. 이 실행들은 아래 요청 수명 처리 수정 이전 결과다.

## 응답·취소·오류 처리 수정

`WindowsAudioShare`가 직접 선언한 COM 인터페이스 대신 SDK의 `DataTransferManagerInterop.GetForWindow`와 `ShowShareUIForWindow`를 사용한다. Microsoft의 [데스크톱 공유 문서](https://learn.microsoft.com/en-us/windows/apps/develop/windows-integration/integrate-sharesheet-send)와 [C#/WinRT 어댑터 구현](https://github.com/microsoft/CsWinRT/blob/master/src/cswinrt/strings/ComInteropHelpers.cs)을 따른다.

`ShowShareUIForWindow`가 반환됐다는 이유만으로 성공 안내를 하지 않는다. 요청마다 별도 `AudioShareRequest`와 데이터 패키지를 유지하며 Windows의 `DataRequested` 콜백에서 데이터를 전달했을 때만 대기를 완료한다. 이는 Windows에 데이터를 제공했다는 의미이며 받는 앱 선택이나 외부 전송 완료를 뜻하지 않는다.

15초 내 응답이 없으면 오디오 내보내기도 사용할 수 있다는 오류를 표시한다. 취소·종료·timeout으로 끝난 요청의 콜백과 중복 콜백은 데이터를 다시 공급하지 못한다. 데이터 지정 중 예외는 네이티브 콜백 바깥으로 던지지 않고 대기 중인 작업으로 전달한다. MainWindow는 완료될 때까지 작업 상태를 유지하고 공유 COM 오류를 마이크 권한 오류로 잘못 안내하지 않는다.

## 창을 열지 않은 검증

- WPF Release 빌드: 경고 0, 오류 0.
- `AudioShareRequestTests` 6개와 기존 `AudioShareFilesTests` 6개, **총 12개 통과 / 실패 0 / 건너뜀 0**. `Windows/artifacts/test-step18/share-lifecycle.trx`.
- 무응답 timeout, 사용자 취소와 재시도, 데이터 지정 오류, 종료 후 늦은 콜백, 동시 중복 콜백, 이미 취소된 요청을 확인했다. 파일 사본 검사와 함께 UI·마이크·외부 전송 없이 실행했다.
- WPF smoke에 공유 실패 후 재시도 가능 상태와 COM 오류 안내 검사를 추가하고 컴파일했다. **새 WPF 검사는 실행하지 않았다.** 사용자의 데스크톱 사용 요청이 해제되기 전에는 숨김 창을 포함한 WPF smoke도 실행하지 않는다.
- 단계 17의 전체 테스트 230개 통과/장치 6개 건너뜀은 수정 전 결과다. 이번 12개 중 기존 파일 검사가 포함되므로 두 숫자를 합쳐 전체 통과 수로 표시하지 않는다.

## 배포 상태

새 ZIP은 만들지 않았다. 최신 후보는 계속 단계 17의 `0.4.0+4922af1217ad6e855585a6aa5d0ae3e4dd5d2408`이며 **이번 공유 요청 수정은 포함하지 않는다**. 후보의 `.verification.json`에 물리 폴더 드래그 결과를 별도로 기록하되 `Passed=false`는 유지한다.

남은 작업은 데스크톱을 다시 사용할 수 있을 때 실제 공유 창과 `DataRequested` 문제를 조사하고, 새 WPF 오류 경로를 실행한 뒤 최신 소스·문서의 새 ZIP으로 전체 배포 검증을 완료하는 것이다. 실제 사용자 마이크·Apple 기기·배포 Cloudflare 서버와 자연 회의 정확도의 기존 검증 한계도 유지한다.
