# AI-NoteTaker for Windows · Preview 0.4.0

최신 Apple 앱의 녹음·회의록 기능을 Windows WPF로 이식한 버전입니다. **집중 파형, 녹음 폴더, 트레이·전역 단축키, 자동 회의록, 참여자 분석과 수동 수정, 내 발화 이어듣기, 프로필과 라이브 본인 표시, 약속·질문·결정 분석, 프로젝트 브리핑, 전사 정리·회의록 보완, 자동/수동 동기화와 지속 웹 공유**를 제공합니다. Apple 소스와 Windows 앱·빌드·버전은 분리되어 있습니다. [전체 이식 상태와 검증 범위](FULL-PORT-PLAN.md)

API 키와 상품화 구조는 [현재 AI 처리 방식](docs/implementation/PRODUCT-AI-ARCHITECTURE.md)에 정리했습니다. 기본 로컬 처리에는 API 키가 필요 없으며, OpenRouter를 선택한 경우 현재는 사용자 키를 입력합니다. 일반 고객용 로그인·결제 서버는 별도 구현 영역입니다.

개발 소스에는 **모델 검색과 별도 보완 모델, 회의록 보완 미리보기/적용, 원문과 분리한 전사 정리, 제목 목차 이동**도 추가했습니다. 전사 정리는 기본 활성화이며 AI 설정에서 끌 수 있습니다. 정리 실패 시 원문으로 회의록을 만듭니다. [구현과 검증 범위](docs/implementation/FULL-PORT-STEP6.md)

동기화는 **녹음·폴더·삭제 상태·회의록·분석·수정 이력·프로필·AI 설정**의 병합, 영속 대기열, 재시도, 중단 복구와 WPF 자동/수동 실행까지 구현했습니다. 도구 막대의 **동기화**에서 진행·오류·대기 항목을 확인하고, 설정에서 서버 주소와 토큰을 입력합니다. 자동 동기화는 기본적으로 꺼져 있으며 녹음·재생·AI·편집 작업이 끝난 뒤 실행합니다. 회의록의 생성 당시 원문과 받은 문서의 바이트/해시는 유지합니다. 기존 서버에서 Windows 기기 등록을 사용하려면 `0008_windows_devices.sql`까지 적용하고 Worker를 배포해야 합니다. 실제 Apple 기기/배포 서버 검증과 최종 포터블 배포는 남아 있습니다. [동기화 검증과 남은 범위](docs/implementation/FULL-PORT-STEP10.md)

Apple 앱의 컴포넌트 구성을 유지한 Windows 데스크톱 앱입니다. WPF 화면과 WASAPI 녹음 엔진을 사용합니다. 0.3에서는 **무료 로컬 전사·회의록**과 **클로바노트 파일 연동**을 추가했습니다. 원래 Swift 프로젝트는 그대로 유지됩니다.

Windows 소스·프로젝트 설정·의존성·테스트·문서·배포 스크립트는 모두 이 `Windows/` 폴더 안에서 관리합니다. Windows의 `Directory.Build.props`는 이 하위 프로젝트에만 적용되고, Apple의 Xcode/Swift 빌드와 버전을 공유하지 않습니다. Windows 빌드는 저장소 루트에서 `Windows/build.ps1`을 명시적으로 실행합니다.

## 실행

최신 upstream 병합, 빈 녹음 보호와 공유 오류 처리를 포함하는 단계 19 후보입니다. 새 압축 해제본의 전체 13개 실행 게이트 중 **12개가 통과하고 Windows 시스템 오디오 공유가 실패**했습니다. 파일 탐색기와 독립 텍스트 공유 진단에서도 창이 열리지 않았으며, 허용받은 공유 호스트 재시작으로 해결되지 않았습니다. 실제 폴더 이동·순서 변경과 재실행 후 보존은 확인했습니다. 최종 검증 완료 릴리스는 아닙니다. 버전·해시·실행 결과는 ZIP 옆 `.verification.json`, 파일 무결성 결과는 `.static-verification.json`을 참고하세요. [실행 검증과 공유 비교](docs/implementation/FULL-PORT-STEP20.md)

```text
Windows/artifacts/step19/0.4.0/portable-win-x64/AI-NoteTaker.exe
Windows/artifacts/step19/AI-NoteTaker-0.4.0-win-x64.zip
```

ZIP을 **폴더째 풀고** `AI-NoteTaker.exe`를 실행하세요. 옆의 DLL·runtimes 폴더도 필요합니다. .NET 런타임이 포함되어 별도 SDK 설치는 필요 없습니다. 이전 버전이 열려 있다면 닫고 새 버전을 실행합니다. 서명된 설치 프로그램과 자동 업데이트는 아직 없습니다.

검증 환경: Windows 11 x64, i7-13700F, RTX 4070 Ti 12GB. Whisper CPU는 AVX2/FMA/F16C 지원이 필요합니다. Windows ARM은 실행 검증하지 않았으며 Qwen 자동 설치는 x64 전용입니다. NVIDIA GPU가 없으면 GPU 사용을 끄고 CPU로 실행할 수 있지만 느립니다.

## 무료 전사·회의록 시작

1. 상단 톱니바퀴 **AI 설정**을 엽니다.
2. 전사는 **Whisper · 이 PC**, 회의록은 **Ollama · 이 PC**를 선택합니다. 기존 0.2 설정을 불러오면 OpenRouter 선택을 유지하므로 직접 바꿔주세요.
3. 기본 요약 모델은 **Qwen3.5 4B**, 전사 언어는 **한국어**입니다. 다국어 녹음에는 자동 감지를 선택합니다.
4. **선택한 로컬 모델 준비**를 누릅니다. 처음에는 인터넷 다운로드가 필요하며 진행률·취소·이어받기를 지원합니다. 모델 크기와 SHA-256을 검증한 뒤 사용합니다. 이번 개발 PC에는 Whisper, Qwen3-ASR 두 크기, Ollama/Qwen3.5 4B가 준비되어 있습니다.
5. 설정을 저장하고 녹음을 선택합니다. **회의록 생성**은 전사 후 요약, **전사만**은 음성을 글로 저장, **전사문으로 정리**는 저장된 글만 다시 요약합니다.

로컬 모드에는 API 키와 분당 이용료가 없습니다. 다운로드한 모델과 이 PC의 CPU/GPU를 사용합니다. Ollama는 loopback 주소만 허용하고 앱이 시작한 서버에는 `OLLAMA_NO_CLOUD=1`을 적용합니다. 사용자가 이미 실행한 Ollama가 있으면 그 서버를 사용합니다. 로컬 실행의 HTTP 관찰과 검증 범위는 [검증 기록](docs/implementation/FREE-AI-VERIFICATION.md)에 있습니다.

**첫 설치 공간:** Whisper 약 1.62GB, 요약 모델 약 3.4GB, Ollama 다운로드 약 1.47GB와 압축 해제 공간이 추가로 필요합니다. 기본 조합은 여유 공간 **10GB 이상**을 권장합니다. 별도 선택인 Qwen3-ASR 1.7B는 모델·프로젝터 약 2.81GB, 0.6B는 약 1.18GB이고 실행 환경 약 254MB가 추가됩니다. 다운로드 ZIP과 중단 파일도 보관됩니다. 9B 요약 모델은 별도 다운로드가 필요합니다. 개발 PC에서 4B와 9B의 실제 실행을 비교했지만 두 모델 모두 의미 오류가 있어 기본 4B를 유지합니다. [실행 결과와 품질 범위](docs/implementation/FULL-PORT-STEP16.md)

Qwen3-ASR은 설정의 전사 엔진에서 선택할 수 있습니다. 언어를 자동 감지하며 1.7B·0.6B를 제공합니다. Whisper는 문장 구간 시간을, Qwen은 처리한 120초 구간 범위를 저장합니다. **Qwen의 구간 시간은 단어별 정렬이 아닙니다.** 현재 개발 소스에서는 **참여자 분석**으로 별도의 상세 시간 전사와 로컬 화자 구분을 실행할 수 있습니다. 최대 6시간 파일의 구간 처리 검증과 정확도 범위는 [단계 11](docs/implementation/FULL-PORT-STEP11.md)에 있습니다.

68.66초 한국어 합성 회의의 GPU 전사는 Whisper 4.50초, Qwen 1.7B 7.93초, Qwen 0.6B 4.35초였습니다. 모델 확인·로딩을 포함한 단일 실행이며 실제 다중 화자 회의의 정확도나 모든 PC의 속도를 보장하는 벤치마크는 아닙니다. 이름·숫자·담당자·기한과 AI가 덧붙인 해석을 원문과 대조하세요.

## 클로바노트와 함께 사용

1. 녹음 화면에서 **클로바노트용 내보내기**를 누르고 저장 폴더를 선택합니다.
2. 앱이 원본을 유지한 채 16kHz/16bit/모노 WAV로 변환합니다. **최대 90분·약 173MB씩** 분할하므로 조사 당시의 파일당 180분·300MB 제한 안에 들어갑니다.
3. 본인 클로바노트에서 파일을 직접 업로드해 전사합니다. 계정별 무료 시간은 클로바노트에서 확인하세요. 이 앱이 600분 제공을 보장하지는 않습니다.
4. 전사 결과를 TXT로 내려받거나 복사한 뒤, 앱에서 같은 녹음을 선택하고 **전사문 가져오기**를 누릅니다. TXT·표준 SRT·Markdown 파일 또는 붙여넣기를 미리 확인한 후 **이 녹음에 연결**합니다.
5. **전사문으로 정리**로 무료 로컬 회의록을 만듭니다. 여러 파일을 올렸다면 TXT를 시간 순서대로 합쳐 붙여넣으세요. 분할된 SRT는 각각 0초부터 시작하므로 원본 시간에 맞춘 오프셋 조정이 필요합니다.

가져온 파일 바이트와 발언자·시간 표기를 원문으로 보존합니다. TXT의 화자 표시를 임의로 추정하지 않습니다. SRT는 표준 시간 형식을 검증합니다. 기존 전사문은 이력에 보관하며 기존 회의록은 새 요약이 성공할 때까지 유지됩니다. 가져온 전사문은 전사 모델 설정을 바꿔도 유지합니다.

개인 클로바노트 자동 로그인·업로드 API 연동은 포함되지 않습니다. NAVER WORKS 유료 API와 개인 무료 계정은 다른 서비스입니다. [공식 자료 조사](docs/implementation/FREE-TRANSCRIPTION-RESEARCH.md)

## 웹 공유

완성된 회의록에서 **웹 공유**를 누르면 개인 Cloudflare 공유 서버에 7일짜리 읽기 전용 스냅샷을 만들 수 있습니다. 링크를 가진 사람은 만료 전까지 회의록을 읽을 수 있습니다. 링크 주소나 오른쪽 **복사** 버튼을 누르면 클립보드에 복사됩니다. 앱이 업로드하는 내용은 녹음 제목과 회의록 Markdown뿐입니다. 오디오, 전사문, 로컬 파일 경로, OpenRouter 키는 보내지 않습니다.

사용 전 **AI 설정 → 웹 공유**에서 개인 배포의 HTTPS 서버 주소와 `SYNC_TOKEN`을 저장하세요. 이 토큰은 OpenRouter API 키와 별도로 Windows DPAPI CurrentUser로 암호화됩니다. 서버 주소는 `https://`만 허용합니다.

공유 창을 다시 열거나 앱을 재시작하면 서버에서 활성 링크 주소를 다시 불러옵니다. 주소와 오른쪽 복사 버튼이 계속 표시되며, 둘 중 어느 쪽을 눌러도 링크가 복사됩니다. 공유 중에는 새 링크 생성·링크 열기 버튼을 표시하지 않습니다. **공유 취소**는 공개 링크만 비활성화하며 로컬 녹음 삭제와는 별개입니다. 로컬 녹음을 삭제해도 이미 만든 공개 스냅샷이 자동으로 취소되지는 않으므로 필요하면 웹 공유 창에서 따로 취소하세요.

## 녹음과 Apple UI

260px 사이드바, 빨간 원형 녹음 버튼, 파란 선택 상태, 녹음/AI 회의록 분할 탭, 실제 파형·15초 이동, 밝은/어두운 외관을 적용했습니다. [컴포넌트 대응](docs/implementation/WINDOWS-APPLE-UI.md)

- 녹음 버튼 아래 **마이크 + 시스템** 또는 우클릭 팝업에서 장치·모드와 마이크/시스템 소리의 개별 음량을 선택합니다. 1.00은 기본값, 0.00은 해당 소스 음소거입니다. 모드·장치·음량은 이 PC에 저장되며 녹음 중에는 바꿀 수 없습니다. 빨간 버튼 → 일시정지/재개 → 완료로 저장합니다. [녹음 설정 검증](docs/implementation/FULL-PORT-STEP17.md)
- WAV·MP3·M4A 등 Windows에서 디코딩 가능한 오디오를 가져올 수 있습니다. 제목 검색·이름 변경·즐겨찾기·최근 삭제·복원과 Markdown 복사/내보내기를 지원합니다.
- 최근 삭제된 녹음은 30일 동안 복원할 수 있습니다. 30일이 지나면 앱 시작/목록 갱신 때 파일을 정리합니다. **영구 삭제…**로 확인 후 바로 정리할 수도 있습니다. 이 기기의 오디오·문서·수정 이력과 식별 가능한 동기화 복사본을 지우고 삭제 메타데이터는 동기화용으로 남깁니다. 서버·다른 기기·앱 밖으로 내보낸 사본은 별도로 유지됩니다.
- 녹음 화면 또는 우클릭 메뉴의 **오디오 내보내기…**는 보관된 WAV를 변환 없이 복사합니다. 가져오기 전에 사용한 MP3 등의 컨테이너를 되돌리는 기능은 아닙니다. 파일 저장이 실패하거나 취소되면 기존 내보내기 파일을 보존합니다.
- **오디오 공유…**는 Windows 공유 창에서 받을 앱을 선택하는 기능입니다. 제목이 붙은 WAV 사본을 준비하며 내부 공유 사본은 24시간 이후 목록 갱신 시 정리됩니다. 현재 검증 PC에서 시스템 공유 창이 응답하지 않는 문제가 남아 있습니다. 개발 소스에는 응답 대기·취소·timeout 안내를 추가했으며 **오디오 내보내기**로 WAV를 저장할 수 있습니다. 실제로 받은 앱에 저장된 사본은 이 앱에서 지우지 않습니다. [현재 공유 상태](docs/implementation/FULL-PORT-STEP18.md)
- `Ctrl+N` 녹음, `Ctrl+Enter` 완료, `Ctrl+O` 가져오기, `Ctrl+F` 검색, `Ctrl+,` 설정, `Space` 재생/일시정지. `Ctrl+←/→` 15초 이동, 파형에서 `Home/End` 처음/끝. `F2`/`Enter` 이름 변경, `Delete` 최근 삭제로 이동. 글을 편집하는 동안 녹음/라이브러리 편집·재생 이동 단축키는 동작하지 않습니다.
- `Ctrl+Shift+E` 오디오 내보내기, `Ctrl+Shift+R` 탐색기에서 오디오 선택, `Ctrl+Shift+L` 즐겨찾기, `Ctrl+Shift+S` 동기화. Windows 창과 EXE에는 원본 저장소의 앱 아이콘을 적용했습니다. [명령·오디오 공유 검증](docs/implementation/FULL-PORT-STEP15.md)
- 시스템 녹음은 선택한 출력 장치의 전체 소리입니다. 온라인 회의는 이어폰을 권장합니다. 마이크가 차단되면 Windows 개인정보 설정에서 데스크톱 앱 접근을 허용하세요.
- 원본 WAV는 48kHz/16bit/스테레오로 시간당 약 691MB입니다. 4시간 또는 여유 공간 100MB 미만에서 종료를 시도합니다. 현재 개발 소스는 기본적으로 창을 닫아도 트레이에서 녹음을 계속합니다. **트레이 메뉴 → 종료** 또는 `Ctrl+Q`는 녹음을 저장한 뒤 앱을 종료합니다. AI 설정에서 백그라운드 실행을 끌 수 있습니다.
- 사이드바 **폴더 +**로 폴더를 만듭니다. 폴더를 선택하면 새 녹음과 가져온 파일이 그 폴더에 들어갑니다. 녹음의 우클릭 메뉴 또는 드래그로 이동하고, 폴더 화살표로 목록을 펼칩니다. 폴더 삭제는 녹음을 삭제하지 않습니다.
- 큰 파형은 재생 위치 주변 5분을, 아래 개요는 전체 녹음을 보여줍니다. 드래그 중에는 표시 구간을 고정해 포인터 위치와 실제 오디오 시간이 어긋나지 않게 합니다.
- AI 설정에서 **녹음 완료 후 회의록 자동 생성**과 **전역 단축키**를 각각 켤 수 있습니다. 전역 단축키는 `Ctrl+Alt+Shift+N` 앱 열기, `R` 녹음 시작/완료, `P` 일시정지/재개입니다. 자동 생성은 선택한 엔진을 사용하므로 OpenRouter 선택 시 키와 크레딧이 필요합니다.

실제 장치 분리·절전·Bluetooth 재연결·수시간 혼합 녹음의 샘플 클록 정렬은 추가 검증 대상입니다. 4B 모델에는 결정/업무·질문 구분 오류가 관찰됐으므로 원문 근거를 확인해야 합니다. [자연 한국어 대화의 측정 결과와 한계](docs/implementation/FULL-PORT-STEP12.md). [영구 삭제·보관 기간·오디오 내보내기 검증](docs/implementation/FULL-PORT-STEP14.md). 전체 요구사항의 최종 점검과 실제 Apple 기기/배포 서버 검증은 남아 있습니다.

## 데이터와 기존 OpenRouter

```text
%LOCALAPPDATA%/AI-NoteTaker/
  settings.json                       # 공급자·모델·DPAPI 암호화 키
  capture-settings-local.json         # 이 PC의 녹음 모드·장치·개별 음량
  Models/                             # 검증된 모델·다운로드 중간 파일
  Models/Ollama/                      # 앱이 설치한 요약 모델
  Tools/                              # 로컬 추론 실행 환경
  Recordings/<UUID>/
    meta.json, audio.wav
    transcript.json                   # 엔진·모델·언어·오디오 해시·구간·출처
    TranscriptHistory/                # 교체 전 전사 캐시
    ImportedSources/                  # 가져온 전사문 원본
    notes.json                        # 성공한 회의록만 교체
```

다운로드·AI 작업을 취소하면 완료된 전사 구간과 기존 회의록을 보존합니다. 엔진/모델/언어가 변경된 로컬 전사는 이전 캐시를 이력에 보관하고 다시 처리합니다. 파일은 임시 저장 후 교체하고 손상된 원본은 유지합니다.

OpenRouter 전사/요약도 각각 선택할 수 있습니다. 해당 단계에서만 오디오 또는 전사문이 선택한 외부 제공자에게 전송되며 유료일 수 있습니다. 기존 키는 Windows DPAPI CurrentUser로 보호하며 빈칸 저장은 키를 유지합니다. 유료 API 실제 호출은 이번 검증에서 수행하지 않았습니다.

오디오·전사·회의록은 로컬 일반 파일이며 앱 암호화는 하지 않습니다. 백업하려면 앱 종료 후 위 폴더를 복사하세요. Windows와 Apple의 로컬 저장 폴더를 직접 섞지 마세요. **기기 간 이동은 공용 Worker 동기화 계약을 통해** 처리하며 Windows WAV는 원본을 보존하고 M4A로 변환해 전송합니다. 텍스트 프로필·분석·수정 이력·AI 설정도 동기화하고, API 키·목소리·화자 임베딩·생성 도중 캐시는 기기에만 보관합니다.

## 개발·검증

.NET 10 SDK가 필요합니다. build.ps1은 `.tools/dotnet/dotnet.exe`를 우선 사용하고 없으면 PATH의 dotnet을 사용합니다.

```powershell
.\Windows\build.ps1 build
.\Windows\build.ps1 test
.\Windows\build.ps1 smoke-ui
.\Windows\build.ps1 run
.\Windows\build.ps1 publish

# 실행 중인 배포 폴더와 분리해서 패키지 검증
.\Windows\build.ps1 publish -ArtifactRoot .\Windows\artifacts\pr-validation

# 준비된 합성/공개 음성 파일과 모델로 새 ZIP 검증. 사용자 마이크는 열지 않음
# 전체 검사에는 Node와 Python이 필요하며 로컬 Worker/SQLite를 사용
.\Windows\verify-package.ps1 -AllFeatures -Archive .\Windows\artifacts\step19\AI-NoteTaker-0.4.0-win-x64.zip

# 실제 장치를 여는 별도 검증 (짧은 테스트음/테스트 녹음)
.\Windows\build.ps1 audio-smoke
.\Windows\build.ps1 ui-audio-smoke

# 준비된 로컬 모델로 파일 평가. 결과는 지정한 격리 폴더에 저장
& ./.tools/dotnet/dotnet.exe run --project Windows/NoteTaker.Evaluation -c Release -- <오디오> <결과폴더> "$env:LOCALAPPDATA/AI-NoteTaker" whisper no-summary
# whisper 대신 qwen, 추가 옵션 small(0.6B), cpu, cancel-resume(120초 초과 파일)
```

최신 소스의 비장치 자동 테스트는 **241개 통과/실패 0**이며 실제 장치 테스트 6개는 필터로 제외했습니다. WPF Release 빌드도 경고·오류 없이 통과했습니다. 최신 ZIP의 UI·재생 보호·Whisper·Qwen·트레이·파일 기반 녹음·참여자·프로필·회의 분석·문서 보완·동기화·웹 공유 12개 실행 경로는 통과했고, 마지막 Windows 시스템 공유는 timeout으로 실패했습니다. 실제 사용자 마이크·배포 서버·Apple 기기 검증과 구분합니다. [단계 20](docs/implementation/FULL-PORT-STEP20.md)에 실행 결과를, [단계 19](docs/implementation/FULL-PORT-STEP19.md)에 최신 병합·빈 녹음 보호를 기록했습니다.

명령·아이콘은 [단계 15](docs/implementation/FULL-PORT-STEP15.md), 녹음 음량과 등록 입력 표시는 [단계 17](docs/implementation/FULL-PORT-STEP17.md), 지속 웹 공유·6시간 화자 처리·WPF 회귀는 [단계 11](docs/implementation/FULL-PORT-STEP11.md), 기존 0.3 검증은 [무료 AI 검증 기록](docs/implementation/FREE-AI-VERIFICATION.md)을 참고하세요. [전체 이식 계획](FULL-PORT-PLAN.md), [0.3 실행 계획](EXECUTION_PLAN.md), [배포 라이선스 고지](THIRD-PARTY-NOTICES.md).
