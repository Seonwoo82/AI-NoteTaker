# Windows 참여자 분석과 수정 이력 검증

날짜: 2026-09-16. upstream `2aaf0532e48016b32571c7929984a8f474e812ee` 재확인.
전체 범위와 남은 항목은 [FULL-PORT-PLAN.md](../../FULL-PORT-PLAN.md)에 있다.

## 구현한 동작

- 참여자 탭에서 실제 로컬 전사·화자 구분을 실행하고 시간/참여자/원문을 가상화 목록에 표시한다. 자동 인원 추정 또는 사용자가 알고 있는 인원 수를 선택한다. 발화에 여러 화자가 포함되면 미지정으로 남긴다.
- 화자 이름, 나로 표시/해제, 개별 발화 참여자 변경은 분석 문서와 별도의 append-only 이력에 저장한다. 같은 발화 ID를 유지하는 재분석 뒤에도 적용한다. 사라진 발화의 수정 이력은 보존하고 미연결 개수를 표시한다.
- 내 발화 필터와 선택 발화/내 발화 이어듣기를 추가했다. 오디오 제공자가 선택한 PCM 프레임만 연결하므로 구간 사이의 다른 발화는 출력하지 않는다. 겹치는 선택 범위는 합친다.
- Apple JSON 필드명에 맞춘 transcript/intelligence/insights/edits 계약과 근거·시간·화자·UTF-8 크기 검증을 추가했다. 아직 Apple와의 실제 동기화 기능은 연결하지 않았다.
- 녹음·전사문·기존 회의록은 보존한다. 분석 게시 전에 오디오와 전사 해시를 재확인하고, 문서가 동시에 변경되면 저장을 거부한다. 손상된 문서/수정 이력을 빈 값으로 덮어쓰지 않는다.

## 실제 런타임

Sherpa-ONNX 1.13.8 (NuGet), ONNX Runtime 1.28.2 (번들 DLL 버전 확인), Pyannote segmentation-3.0 + 3D-Speaker ERes2Net-Base 512차원 모델. 총 다운로드 약 47MB이며 파일 크기/SHA-256을 고정 검증한다. [Sherpa 공식 모델 안내](https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/models.html), [3D-Speaker 모델 카드](https://modelscope.cn/models/iic/speech_eres2net_base_sv_zh-cn_3dspeaker_16k).

네이티브 모델의 진행 콜백이 취소 반환값을 처리하지 않아 분석을 앱 소유의 별도 worker에서 실행한다. 취소 시 그 worker 프로세스 트리만 종료한다. 실행 파일은 포터블 폴더의 `SpeechWorker`에 .NET 런타임과 함께 게시한다. Sherpa 의존성은 worker 프로젝트에만 선언하며, 최종 포터블 루트에는 Sherpa 네이티브 DLL이 없고 `SpeechWorker`에 DLL과 `coreclr.dll`이 있음을 확인했다.

Apple의 FluidAudio/WeSpeaker와 Windows 3D-Speaker의 목소리 벡터는 호환되지 않는다. 모델 ID와 차원을 명시하며 기기 로컬 데이터로 보관한다. Windows 목소리 등록 UI/라이브 본인 표시는 아직 연결하지 않았다.

## 검증 결과

- `dotnet test`: **98 통과, 5 하드웨어 테스트 건너뜀**. wire 필드명, 허구 근거·기한 거부, 잘못된 시간/화자 거부, 문화권에 독립적인 발화 ID, 재분석 후 수정 이력 유지, 문서 변경 충돌/손상 보존, 정확한 PCM 구간 연결 등을 포함한다.
- 공개 중국어 4인 WAV: 자동 분석으로 4명/10개 화자 구간, 6.34초. 공식 예제의 구간 경계와 순서가 일치했다. 취소 500ms 요청으로 소유 worker 종료 확인. `artifacts/speaker-evaluation/final-runtime/diarization.json`과 로그.
- 실측 WPF 흐름: 해당 파일을 실제 Whisper(`zh`)로 전사하고 화자 분석하여 4개 그룹/13개 발화를 저장했다. 세그먼트가 화자 경계에 걸치는 5개 발화는 미지정이다. 이름/나 표시/내 발화 필터/재분석 보존과 원본 오디오·전사·회의록 해시/내용 보존 확인.
- 개발 빌드와 **self-contained 포터블 EXE** 모두 위 WPF 흐름 통과. `artifacts/participants-native/result.txt`, `artifacts/participants-portable-smoke/result.txt`. 밝은 화면과 좁은 어두운 화면을 렌더링해 검사했고 어두운 화면의 글자 대비를 수정했다.
- 의존성을 worker로 분리한 최종 포터블에서 실제 전사/분석/수정 보존/3,000개 목록 검사를 다시 통과했다. `artifacts/participants-isolated-smoke/result.txt`.
- 별도 화자 비교: 같은 사람의 서로 겹치지 않는 발화로 등록/비교해 코사인 유사도 **0.7707**, 다른 사람 **0.1829**. 무음/난수 잡음 등록 거부. 짧은 원음에 무음을 덧붙여 10초를 만든 공개 fixture이며 사용자 마이크는 열지 않았다. `artifacts/speaker-evaluation/voice-3dspeaker/voice-result.json`.
- 기존 녹음/파형/폴더/회의록/설정 WPF 회귀 smoke 통과. `artifacts/participants-regression-ui/result.txt`.
- 마지막 WPF 검사에서 별도 생성한 3,000개 발화 fixture를 표시하고 마지막 행의 컨테이너가 미실현 상태임을 검사해 목록 가상화 확인. `artifacts/participants-final-ui/result.txt` 및 `virtualized-3000-turns.png`. 이 데이터는 목록 검사 전용이며 실제 전사 결과가 아니다.

## 현재 한계와 남은 검증

- 자동 화자 수는 완벽하지 않다. 공개 `1-two-speakers-en.wav`는 1개, `3-two-speakers-en.wav`는 4개 그룹으로 추정했다. 다른 공개 `2-two-speakers-en.wav`와 중국어 4인 파일은 각각 2/4개로 추정했다. 예상 인원 수를 지정한 결과를 자동 인식 정확도의 증거로 계산하지 않는다.
- Whisper 세그먼트 단위 시간만으로는 한 구간 안의 단어별 화자를 확정할 수 없다. 상세 단어 시각과 경계 조합, Qwen/가져온 전사문의 상세 시간 처리, 겹쳐 말하는 실제 한국어 회의 검증이 남아 있다.
- 이름과 나 표시는 현재 수동 지정이다. 목소리 등록/재등록/삭제/라이브 표시, 프로필 재적용, 화자 모델/구간 변화에 따른 수동 수정 재연결은 후속 작업이다.
- 실제 출력 장치로 이어듣는 청취 테스트, 장시간 파일 성능과 메모리, 최대 목록에서의 사용자 탐색, 전체 동기화/회원/결제는 이 단계의 통과 범위가 아니다.
- 실행 엔진은 최대 4시간 파일을 허용하지만 4시간 실제 회의 분석을 완료한 증거는 아직 없다.

비교 과정에서 사용한 WeSpeaker-LM 조합은 이 샘플에서 다른 사람의 유사도가 0.83으로 높아 본인 표시 기준에 부적합했다. 현재 기본값/다운로드에서 제외했다. 최종 선택 이유와 실패 표본을 숨기지 않으며, 제한된 공개 샘플 결과를 제품의 전체 화자 정확도로 일반화하지 않는다.
