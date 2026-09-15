# 전체 동기화: 통신 계약과 M4A 교환

2026-09-16, upstream `2aaf0532e48016b32571c7929984a8f474e812ee` 재확인. 이 단계는 실제 서버 계약과 Windows 통신 계층을 연결한 작업이다. **라이브러리 병합 실행기, 영속 전송 대기열, 자동/수동 동기화 UI는 아직 미구현**이며 전체 이식 목표를 완료 처리하지 않는다.

## 현재 구현과 검증

- `SyncModels.cs`: Apple/Worker 전용 메타데이터·회의록·설정·페이지 계약. UUID는 대문자, `recordingID`/`mutationID` 등 필드명은 원본과 동일하다. 날짜는 Apple ISO-8601 디코더에 맞춘 UTC 초 단위이며 충돌 시각은 별도 밀리초 값이다. 알 수 없는 필드와 필수 필드 누락을 거절하고 Swift가 생략한 nullable 항목을 허용한다.
- `SyncTransport.cs`: 인증 상태 확인, 녹음/폴더/회의록/분석 목록, M4A 및 원본 문서 업로드/다운로드, 프로필, 수정 이력, AI 설정 요청. 깨끗한 HTTPS origin만 받으며 기본 HTTP 핸들러는 redirect와 쿠키를 사용하지 않는다. 문서 다운로드는 목록의 SHA-256·바이트 수와 대조한다. 오디오는 95 MiB·타입·길이를 확인하고 임시 파일에서 끝까지 받은 뒤 교체한다. 실패/취소 시 목적지의 이전 파일을 유지한다.
- `SyncAudio.cs`: 설치된 NAudio 2.3.0의 Windows Media Foundation AAC 인코더로 WAV→M4A, 기존 오디오 변환기로 M4A→WAV. 실제 네이티브 인코더로 생성한 1초 오디오의 왕복 길이와 원본 해시, 60초 인코딩 도중 취소, 이전 출력 보존을 검증했다. 원본과 같은 경로로의 변환을 막는다. 마이크나 스피커 장치 사용은 없다.
- Worker의 기기 플랫폼 목록에 Windows를 추가했다. `0008_windows_devices.sql`은 기존 macOS/iOS 행과 null 키 보유 상태를 유지한다. 이 변경은 로컬에서만 검증했으며 배포 서버에 적용하지 않았다.
- 테스트가 Windows에서도 실제 SQLite 검증을 실행하도록 Python 실행 파일을 `PYTHON` 환경변수로 지정할 수 있게 했다.

`SyncTransportTests.WindowsWireContractsRoundTripThroughActualWorkerHttpAndSqlite`는 `Cloudflare/tests/local-sync-server.mjs`를 별도 프로세스로 실행한다. C# 요청은 실제 loopback HTTP를 거쳐 원본 Worker 핸들러와 실제 SQLite SQL에 도달한다. R2는 이 테스트에서 파일 저장소 대역이며 실제 Cloudflare R2 검증은 아니다. 서버 토큰과 오디오·전사·프로필은 모두 작성한 테스트용 자료다.

이 경로에서 확인한 항목:

1. 실제 AAC M4A 업로드·다운로드 및 바이트 일치, 재시도에서 기존 불변 오디오 유지
2. 메타데이터·폴더·회의록·회의 분석의 서버 수락과 목록/다운로드 왕복
3. 문서 해시/크기 확인, 같은 수정 이력 재전송의 멱등성, 프로필 및 Windows AI 설정 등록
4. 과거 메타데이터가 더 최신 삭제 상태를 되돌리지 못함
5. 선택 필드 생략과 명시적 null 구별: `folderAssignment`를 쓰지 않을 때는 필드를 생략하고, 폴더 해제는 `{id:null}`로 표현

실제 HTTP 검증에서 선택 필드 처리 차이를 발견해 수정했다. 테스트용 SQLite 어댑터의 Python이 Windows 기본 문자 인코딩으로 한글 입력을 읽지 못한 문제도 발견해 UTF-8 모드로 실행한다. 모델 응답 대역만으로 서버 연동 성공을 판단하지 않았다.

검증 명령:

Worker HTTP/SQLite 통합 테스트에는 PATH에서 실행할 수 있는 Node.js와 Python 3가 필요하다. Python 실행 파일은 `PYTHON` 환경변수로 지정할 수 있으며, 기본값은 Windows에서 `python`, 그 외 환경에서 `python3`다. 배포 앱의 실행 의존성은 아니다.

```powershell
$env:PYTHON = (Get-Command python).Source
.\.tools\dotnet\dotnet.exe test Windows/NoteTaker.Tests/NoteTaker.Tests.csproj --no-restore
.\.tools\dotnet\dotnet.exe build Windows/NoteTaker.Windows/NoteTaker.Windows.csproj --no-restore
$env:PYTHONUTF8 = '1'
node --test --test-reporter=dot Cloudflare/tests/*.test.mjs
```

Windows 테스트 171개가 통과했고 장치 사용이 필요한 5개는 건너뛰었다. 서버 전체 테스트와 Windows 빌드(경고 0, 오류 0)도 통과했다. 네이티브 AAC 사용법은 [NAudio 공식 문서](https://github.com/naudio/NAudio/blob/main/Docs/MediaFoundationEncoder.md)와 설치된 2.3.0 XML 문서/실제 실행으로 확인했다.

## 이어서 구현할 전체 동기화 범위

- 로컬 수정 시각·mutation ID 유지와 Apple의 tuple 비교, 폴더/삭제 표시/오디오 버전 병합
- 페이지 반복·중복·크기 제한, 일부 항목 실패 후 나머지 진행, 영속 outbox와 endpoint별 acknowledgement/cursor
- M4A 원본 유지 및 WAV 파생본, 취소/충돌 시 기존 데이터 보존, 오디오보다 메타데이터를 먼저 공개하지 않기
- 오디오/메타데이터/전사/회의록 적용 도중 중단되어도 재시작에서 일관된 상태로 복구하는 로컬 트랜잭션
- 내려받은 notes/intelligence 원본 바이트와 revision 보존: 다시 직렬화한 바이트 때문에 불필요한 충돌을 만들지 않기
- 회의록과 연결된 원문 버전 보존: 전사만 바뀐 경우 옛 회의록에 새 원문을 잘못 붙이지 않기
- 프로필·모델 선택의 원격 병합, 다른 기기 키 보유 알림. API 키·토큰·목소리·임베딩 자체는 전송하지 않기
- 자동/수동/취소/연결 테스트/진행·오류 UI, 녹음·AI 작업·창 종료와 작업 수명 조정
- 서로 다른 두 Windows 라이브러리 및 Apple fixture를 통한 전체 왕복/오프라인 재시도/동시 수정/재시작 검증

이후 지속 웹 공유, 긴 오디오 제한 정합성, 실제 한국어 다자 회의·장치 검증, 최종 ZIP과 PR까지 원래 전체 범위를 유지한다.
