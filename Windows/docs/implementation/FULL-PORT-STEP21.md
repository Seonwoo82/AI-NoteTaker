# 빈 녹음의 실제 WPF 완료·종료·재시작 검증

2026-09-16. 원격 main을 다시 fetch했고 `14172b2ee89fe26e6dd16ccb7619654629a40491`이 기존 HEAD의 조상이며 Apple 소스 차이가 없음을 확인했다. 제품 코드와 단계 19 ZIP은 그대로다. **전체 이식 완료 판정은 아직 보류한다.**

## 배포 DLL을 검사하는 독립 도구

`Windows/verify-recording-completion.ps1`과 `tools/RecordingCompletionCheck/`를 추가했다. 앱을 다시 빌드하지 않고 지정한 패키지의 `AI-NoteTaker.dll`·`NoteTaker.Core.dll`을 직접 로드한다. 실제 WPF 창의 녹음/완료/닫기/다시 열기 경로를 실행하되 녹음 입력만 생성 파일로 대체한다. 내부 완료 Task는 검사에서만 reflection으로 기다린다.

```powershell
./Windows/verify-recording-completion.ps1 -PackageDirectory ./Windows/artifacts/verify-package-18d27d9f
```

Windows 및 .NET 10 SDK가 필요하며, 검사 중 격리 WPF 창을 생성하므로 데스크톱 사용이 허용됐을 때만 실행한다. 출력 라이브러리는 매번 새 GUID 폴더다. 마이크·실제 시스템 소리·사용자 라이브러리·API 키를 사용하지 않는다. 모델은 OpenRouter로 설정하되 키를 넣지 않아 잘못된 AI 시작도 외부 요청 전 키 검사에서 실패하도록 했다. 자동 AI를 호출했다면 `LastWorkError`나 결과 파일 검사에서 실패한다.

## 결과

프로젝트 빌드 경고·오류 0. 체크 스크립트가 새 fixture에서 두 시나리오 모두 통과했고 프로세스가 정상 종료했다. `Windows/artifacts/recording-completion-2112634a/result.json`, `stop-empty-retry.json`, `exit-empty.json`이 현재 증거다.

- 세션은 경과 시간 37초를 보고하지만 실제 WAV는 0프레임이다. 완료 버튼을 누르면 빈 녹음 오류를 표시하고 성공 저장으로 바꾸지 않는다.
- 완료 실패 후 녹음 버튼이 다시 활성화되고 같은 창에서 새 녹음을 시작할 수 있다. 정상 재시도는 세션의 37초 대신 실제 PCM 1초로 저장된다.
- 녹음 중 창을 닫는 경로에서도 빈 입력을 완료로 저장하지 않는다. 세션의 stop/dispose와 창 종료가 끝난다.
- WPF 창을 새로 열면 빈 녹음 길이는 0이고 복구 실패 안내가 남는다. 정상 복구로 오인하지 않으며 원본 WAV 해시를 유지한다.
- 빈 녹음의 전사·회의록 파일은 생성되지 않는다. 사용자 오디오를 녹음하거나 실제 장치 장애를 주입한 검사는 아니다.

로드한 앱 DLL SHA-256은 `BE3A1E9D8FDA30AF7BC10C3F38E0105EC850E791477338E4385DA4A1DD21038F`, Core DLL은 `D66EE3128CCD2EC4FEE2A3D41C4D3237402FAF0DCF33492007E548F421662FF0`이다. 체크 스크립트에서 보고된 로드 경로와 실제 패키지 해시가 일치함도 검사했다. 별도 검사 호스트에서 실행한 패키지 WPF 어셈블리 검증이며, self-contained EXE의 전체 게이트 재실행으로 표시하지 않는다.

## 시스템 공유의 남은 제한

설치된 ShellExperienceHost manifest에는 일반 `App` 외에 공유 target을 가진 `FullTrustApp`이 별도 등록돼 있었다. 앞서 허용받은 호스트 실행 범위에서 이 등록 항목을 정상 활성화해 두 실행 경로가 모두 살아 있는 것을 확인했다. 새 PID 41216의 명령행은 `FullTrustApp` 서버였다.

그 상태에서 같은 최신 EXE의 단독 `--smoke-audio-share`를 한 번 실행했으나 다시 DataRequested timeout이었다. `Windows/artifacts/audio-share-fulltrust-165749/prepared.json`·`error.txt`와 종료한 프로세스를 확인했다. 일반/FullTrust 활성화 차이만으로 해결되지 않았으며 새 Windows 설정 변경·패키지 재등록·전체 Explorer 종료·재부팅은 하지 않았다.

13개 전체 실행 게이트의 기존 결과는 12개 통과·시스템 공유 실패 그대로다. 이번 독립 WPF 검사 두 시나리오를 그 숫자에 합산하거나 최종 성공으로 바꾸지 않는다. 정상 동작하는 Windows 공유 환경에서 실제 공유 창과 DataRequested를 확인한 후 최종 배포 게이트를 완료해야 한다.
