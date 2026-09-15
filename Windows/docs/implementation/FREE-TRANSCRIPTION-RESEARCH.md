# Windows 무료 전사·회의록 구성 조사

조사일: 2026-09-14. 공식 모델 카드, 프로젝트 문서, 네이버 고객센터·개발자 문서를 확인했다. 아래는 도입 제안이며 아직 앱에 로컬 모델이나 클로바 연동을 설치하지 않았다. 실제 한국어 회의 음성으로 모델별 정확도와 처리 속도를 측정하지 않았다.

## 권장 방향

**로컬 전사 + 로컬 회의록 요약을 기본으로 제공하고, 개인용 클로바노트는 전사문 가져오기로 연결한다.** 전사와 요약을 분리하면 전사는 무료로 처리하고 필요한 경우 요약만 기존 OpenRouter를 사용하는 선택도 가능하다.

이번 PC에서 직접 확인한 사양은 i7-13700F, RAM 31.8GB, RTX 4070 Ti, GPU 메모리 12,282MiB다. 이 사양은 아래 소형 모델들을 순차 실행하는 구성을 시험하기에 적합하다는 판단이다. 모델 다운로드 크기는 실행 중 메모리 사용량과 다르며, 긴 입력과 다른 GPU 프로그램의 사용량도 고려해야 한다. 로컬 실행에는 API 분당 요금과 서비스 월간 쿼터가 없지만 전력·저장 공간·처리 시간은 필요하다.

## 전사 후보

| 후보 | 확인한 내용 | 이 앱에서의 판단 |
| --- | --- | --- |
| Whisper large-v3-turbo | 공개 모델, MIT 라이선스. [공식 모델 카드](https://huggingface.co/openai/whisper-large-v3-turbo) | Windows 기본 엔진 1차 후보. 기존 C# 앱에서 Whisper.net으로 직접 연결하고 한국어 회의 기준선을 만든다. |
| Qwen3-ASR 1.7B / 0.6B | Alibaba Qwen의 공개 전사 모델. 한국어를 포함한 30개 언어와 중국어 방언 지원. Apache-2.0. [공식 프로젝트](https://github.com/QwenLM/Qwen3-ASR), [모델 카드](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) | 중국 모델 중 우선 비교 후보. 1.7B와 Whisper를 같은 녹음으로 비교하고, 0.6B는 가벼운 옵션으로 검토한다. 한국어 회의에서 더 정확하다고 아직 단정할 수 없다. |
| SenseVoiceSmall | 한국어·중국어·광둥어·영어·일본어 지원. 코드 MIT와 모델 가중치의 FunASR 라이선스가 별도다. 화자 분리는 별도 모델을 조합하는 기능이다. [공식 프로젝트](https://github.com/QwenAudio/SenseVoice) | 가벼운 대안 후보. sherpa-onnx의 공개 ONNX 모델 경로가 있다. 배포할 변환 가중치의 라이선스를 함께 확인해야 한다. [공식 실행 문서](https://k2-fsa.github.io/sherpa/) |

Windows 연결 방법도 구분해야 한다.

- **Whisper.net / whisper.cpp:** C# 바인딩과 CPU·CUDA·Vulkan 실행 경로가 있다. 현재 WPF/.NET 구조와 맞는다. 런타임별 Visual C++ 및 GPU 라이브러리 요구사항을 고정하고 새 Windows 환경에서 배포 검증해야 한다. [Whisper.net](https://github.com/sandrohanea/whisper.net)
- **faster-whisper:** CPU/GPU INT8을 지원하는 비교·실험용 대안이다. Python과 GPU 사용 시 CUDA/cuDNN 구성이 필요해, 앱 배포 시 별도 실행 환경 관리가 추가된다. 프로젝트 벤치마크의 처리 시간을 이 PC의 한국어 회의 처리 시간으로 환산하지 않는다. [공식 프로젝트](https://github.com/SYSTRAN/faster-whisper)
- **Qwen3-ASR:** 공식 Transformers 경로 외에 llama.cpp가 두 크기의 ASR 모델을 지원하고 ggml-org가 GGUF를 제공한다. Windows에는 이 별도 실행 파일을 로컬 프로세스로 연결하는 방향을 검토한다. 기존 OpenRouter의 `audio/transcriptions` 요청을 URL만 바꾸어 보내는 방식은 아니다. llama.cpp의 오디오 입력 및 출력 형식에 맞는 어댑터가 필요하다. [llama.cpp 멀티모달 문서](https://github.com/ggml-org/llama.cpp/blob/master/docs/multimodal.md), [GGUF 배포](https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF)

음성 구간 검출(VAD), 단어 시간 정렬, 화자 분리는 각각 다른 기능이다. Qwen의 ForcedAligner는 시간 정렬용이며 사람을 구분하는 기능으로 간주하지 않는다. 회의록에 발언자 이름·담당자를 넣으려면 별도 화자 처리와 사용자 확인이 필요하다. [Qwen 공식 설명](https://github.com/QwenLM/Qwen3-ASR)

## 회의록 요약까지 무료로 처리하기

전사 모델은 음성을 글로 바꾸고, 요약 모델은 그 글에서 안건·결정·할 일을 정리한다. 전사만 무료로 바꾸고 현재 OpenRouter 요약을 유지하면 요약 비용은 남는다.

로컬 요약 후보는 **Ollama + Qwen3.5 4B**, 비교 후보는 **9B**다. 공식 모델 카드는 Apache-2.0을 명시한다. Ollama 배포 목록에서 4B는 약 3.4GB, 9B는 약 6.6GB이며 이는 다운로드 크기다. [4B 모델 카드](https://huggingface.co/Qwen/Qwen3.5-4B), [Ollama 모델 목록](https://ollama.com/library/qwen3.5)

Ollama는 Windows와 NVIDIA GPU를 지원하며 로컬 API를 제공한다. 구현 시 클라우드 태그가 아닌 로컬 모델을 선택하고, 전사 완료 후 ASR 모델을 내려 GPU 메모리를 확보한 다음 요약을 실행한다. [Windows 공식 문서](https://docs.ollama.com/windows)

4B부터 실제 한국어 회의록을 평가하고 9B가 결정사항·고유명사·담당자 보존을 개선하는지 비교한다. 긴 회의는 모델의 최대 문맥 길이를 그대로 쓰기보다 실제 메모리에 맞는 구간 요약과 전체 종합으로 처리한다. 원문 근거가 없는 담당자·일정은 만들지 않도록 현재 프롬프트의 제약을 유지한다. 이 구성의 한국어 요약 품질과 실행 시간은 미검증이다.

## 클로바노트: 개인용, 비즈니스용, Speech API의 차이

| 구분 | 공식 자료로 확인한 범위 | 무료 구성에 대한 판단 |
| --- | --- | --- |
| 개인용 클로바노트 | 네이버의 정식 출시 발표에 월 최대 600분 프로모션 안내가 있다. 현재 고객센터는 데이터 수집 동의 시 월 300분 추가 지급을 명시한다. [출시 발표](https://www.navercorp.com/media/pressReleasesDetail?seq=2268), [현재 사용 시간 안내](https://help.naver.com/service/24269/contents/12814?osType=COMMONOS) | 600분을 모든 계정의 무조건적인 상시 API 쿼터로 간주할 수 없다. 이번 조사에서는 사용자 계정의 실제 지급 시간·동의 설정을 열어 확인하지 않았다. |
| 네이버웍스 클로바노트 API | 노트 목록·검색·상세 조회, 삭제, 사용량 API가 공개되어 있다. 구성원 OAuth가 필요하고 서비스 계정 토큰은 지원하지 않는다. [API 개요](https://developers.worksmobile.com/kr/docs/ClovaNote) | 공식 연동은 가능하지만 개인용 무료 계정과는 별도다. 공개 목록에서 음성 업로드·새 전사 실행 API는 확인하지 못했다. |
| 네이버 클라우드 CLOVA Speech | 음성 업로드 전사 API가 별도 제공되며, 상품의 Free 플랜은 월 20분이다. [공식 요금 데이터](https://www.ncloud.com/api-cms/service-product/static/clovaSpeech), [업로드 API](https://api.ncloud-docs.com/docs/en/ai-application-service-clovaspeech-longsentence-local) | 600분 무료 API가 아니다. 연동 자체는 가능하나 무료로 회의를 계속 처리하는 기본 수단으로는 부족하다. |

비즈니스용 상세 조회 응답에는 `scripts`, `attendees`, `summaries`가 있어 이미 생성된 전사·요약을 가져올 수 있다. 신규 연동은 deprecated된 `summary` 대신 `summaries`를 사용한다. [상세 조회 계약](https://developers.worksmobile.com/kr/docs/ainote-user-note-get)

현재 비즈니스 요금표의 외부 API 지원은 Team 이상이다. Team은 기업당 월간 계약 108,000원, 연간 계약 기준 월 86,500원(세금 별도)으로 표시된다. 개인용 무료 시간과 이 API를 연결하는 근거는 찾지 못했다. [공식 요금표](https://naver.worksmobile.com/pricing/clovanote/)

개인용 공식 도움말·개발자 문서에서 공개 전사 API는 확인하지 못했으므로, **공식 파일 내보내기·가져오기 흐름**을 우선 제안한다. 로그인 쿠키나 비공개 요청 재현에 의존하는 자동화는 기본 제품 연동 방식에서 제외한다. 이는 연동 유지보수와 계정 인증 구조를 고려한 설계 판단이다.

## 개인용 무료 시간을 활용하는 연결 흐름

1. 우리 앱에서 녹음을 선택하고 `클로바노트용 오디오 내보내기`를 실행한다.
2. 사용자가 클로바노트 웹에서 파일을 올리고 전사한다.
3. 클로바노트의 음성 기록 다운로드에서 참석자·발화 시간 포함 옵션을 선택한다.
4. 우리 앱의 `전사문 가져오기`에서 해당 녹음에 연결하고 미리보기로 확인한다.
5. 가져온 전사문을 로컬 Qwen으로 정리하거나, 선택한 경우 기존 OpenRouter로 요약한다.

파일 업로드와 음성 기록 다운로드는 공식 지원 기능이다. 개인용은 파일당 300MB, 길이 180분 제한이 안내되어 있다. [업로드 안내](https://help.naver.com/service/24269/contents/12820?osType=PC), [다운로드 안내](https://help.naver.com/service/24269/contents/12831?osType=PC), [길이 안내](https://help.naver.com/service/24269/contents/12814?osType=COMMONOS)

현재 앱의 WAV는 48kHz·16bit·스테레오로 시간당 약 691MB다. 따라서 1시간 회의 원본은 300MB를 넘는다. 원본은 보존하고 M4A/MP3 압축 또는 분할 내보내기를 추가해야 한다. 계산상 16kHz·16bit·모노 WAV도 3시간이면 약 346MB이므로 샘플레이트만 줄이는 처리로 모든 파일을 해결할 수는 없다.

다운로드 도움말은 여러 형식과 참석자·시간 옵션을 설명하지만, 실제 TXT/SRT 파일 표본은 이번에 받지 않았다. 가져오기 파서는 실제 출력 파일을 확보해 인코딩·발화자·시간 표기를 확인한 뒤 확정한다. 텍스트 붙여넣기는 범용 보조 경로로 제공할 수 있다.

추가 300분의 데이터 수집 동의는 사용자가 직접 선택할 항목이다. 노트 내용을 외부로 보내지 않는 로컬 모드와 클로바노트에 업로드하는 모드는 화면에서 처리 위치를 구분한다. [공식 데이터 관리 설명](https://help.naver.com/service/24269/contents/12899?lang=ko&osType=COMMONOS)

## 기존 코드에서 바꿀 부분

현재 `Windows/NoteTaker.Core/MeetingNotesService.cs`는 `OpenRouterClient`에 전사와 요약을 모두 요청한다. 캐시는 오디오 해시와 전사 모델 ID를 기준으로 검증하며, 전사는 120초 구간 단위다. 이번에는 코드 동작을 변경하지 않았다.

권장 구현 순서:

1. `ITranscriber`와 `ISummarizer`로 처리 단계를 분리한다. 로컬 엔진에서는 OpenRouter 키를 요구하지 않도록 설정과 버튼 검증도 함께 변경한다.
2. Whisper.net 기반 무료 전사와 Ollama 요약을 연결한다. 전사만 저장하기·기존 전사로 다시 요약하기도 독립 동작으로 만든다.
3. Qwen3-ASR 어댑터를 추가하고 같은 한국어 회의 파일로 Whisper와 비교한다. 필요하면 기본 엔진을 평가 결과에 따라 바꾼다.
4. 클로바노트용 오디오 내보내기와 전사문 가져오기를 추가한다. 가져온 원문은 별도 보존하고 다른 모델 선택만으로 지워지지 않도록 한다.
5. 캐시 키에 엔진·모델 버전·언어·전처리 옵션을 포함한다. 전사 구간에 시작/끝 시간·선택적 화자·출처를 저장하고 기존 문자열 캐시를 마이그레이션한다.
6. 첫 모델 다운로드의 크기·진행률·중단/재개, GPU 실패 시 CPU 경로, 취소 후 재시도, 모델 파일 버전 및 해시 검증을 제공한다.

## 도입 전 실측할 항목

같은 입력을 사용해 Whisper large-v3-turbo, Qwen3-ASR 1.7B와 0.6B를 비교한다. 조용한 2인 대화, 온라인 회의, 한영 혼용·제품명·숫자 포함 회의, 잡음·겹침이 있는 회의를 각각 평가한다.

- 전사: 사람이 교정한 표본 대비 한국어 CER, 숫자·금액·이름 오류, 누락·반복·무음 구간의 잘못된 문장 생성.
- 처리: 녹음 길이 대비 실행 시간, 모델 첫 로딩 시간, 최대 RAM/VRAM, 취소·재개와 60~180분 파일 처리.
- 요약: 실제 결정과 제안의 구분, 담당자·기한 보존, 원문에 없는 사실 생성, 안건 누락.
- 배포: 새 Windows PC에서 GPU/CPU 실행, 모델 없는 상태와 오프라인 재실행, 원본 파일 보존.

공개 지원 언어와 벤치마크는 후보 선정의 근거다. 이 앱에서의 한국어 회의 품질·속도·무료 처리 완성도를 입증하는 실측 결과는 아직 없다.
