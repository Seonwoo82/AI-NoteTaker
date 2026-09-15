# Windows AI 처리 방식과 상품화 구조

확인: 2026-09-16. 현재 코드와 공식 서비스 문서를 기준으로 작성했다. 회원·결제 서버 구현 완료를 뜻하지 않는다.

## 지금 앱의 구조

```text
사용자의 Windows PC
  녹음 파일 → 로컬 Whisper 또는 Qwen3-ASR → 전사문
  전사문 → 로컬 Ollama / Qwen3.5 → 회의록
  녹음 파일 → 로컬 Sherpa-ONNX / 3D-Speaker → 참여자 구간
```

새 설치의 기본값은 `whisper` 전사와 `ollama` 요약이다. 다운로드한 모델을 사용자 PC의 CPU/GPU에서 실행한다. 이 구성에는 OpenRouter 키, 외부 AI의 월 무료 분수, 호출당 API 요금이 없다. 실행 시간·메모리·저장 공간과 개별 기능의 파일 처리 제한은 별개다. 모델/런타임의 최초 준비에는 인터넷 다운로드가 필요하다.

OpenRouter를 선택한 기능만 사용자 입력 키로 OpenRouter에 직접 요청한다. 현재는 사용자가 자신의 키와 크레딧을 준비하는 BYOK 방식이다. 해당 키는 Windows DPAPI로 보호해 기기에 저장한다. 전사와 요약은 독립 선택이므로 로컬 전사 + 클라우드 요약도 가능하다. 이전 설치에서 저장한 클라우드 설정은 새 기본값으로 강제 변경하지 않는다.

개인용 클로바노트는 오디오 내보내기 → 사용자가 업로드/전사 → 전사 파일 가져오기로 연결한다. 개인용 네이버 계정에 앱이 자동 로그인하거나 무료 전사 API를 호출하는 구조가 아니다.

근거 코드: `NoteTaker.Core/Models.cs`, `AiProviders.cs`, `OpenRouterClient.cs`, `LibraryStore.cs`의 `SettingsStore`, `ClovaAudioExport.cs`, `TranscriptImport.cs`, `SpeakerModels.cs`.

## 외부 서비스 한도

| 서비스 | 공식 안내 | 제품에 미치는 영향 |
| --- | --- | --- |
| OpenRouter 무료 모델 | `:free` 모델은 분당 20회, 크레딧 구매액 $10 미만이면 하루 50회, $10 이상 구매하면 하루 1,000회. 모델 제공자의 용량 제한도 적용될 수 있음 | 모든 OpenRouter 모델에 무료 쿼터가 생기는 것이 아님. 긴 회의의 여러 구간/종합 요청은 각각 호출을 소비함 |
| 개인용 클로바노트 | 데이터 수집 동의 시 월 300분 추가 지급, 1회 녹음/업로드 길이 최대 180분 | 개인 계정의 무료 시간을 우리 제품 전체의 공용 API 쿼터로 사용할 수 있다고 가정하지 않음 |
| CLOVA Speech API | 네이버 클라우드의 별도 상품. Free 플랜 월 20분 | 개인용 클로바노트의 최대 600분 안내와 별개 |

출처: [OpenRouter 한도](https://openrouter.ai/docs/api_reference/limits), [OpenRouter 지원센터의 수치 안내](https://openrouter.zendesk.com/hc/en-us/articles/39501163636379-OpenRouter-Rate-Limits-What-You-Need-to-Know), [클로바노트 사용 시간](https://help.naver.com/service/24269/contents/12814?osType=COMMONOS), [CLOVA Speech 요금](https://www.ncloud.com/api-cms/service-product/static/clovaSpeech).

현재 코드의 OpenRouter 기본 모델에는 `:free` 접미사가 없다. 이 경로를 무료 사용이라고 안내하면 안 된다. 공식 FAQ도 무료 모델의 낮은 한도 때문에 production 용도로 적합하지 않은 경우가 많다고 설명한다. [공식 FAQ](https://openrouter.ai/docs/faq)

## 일반 고객에게 API 키를 요구하지 않는 상품 구성

권장안은 기본 로컬 처리와 선택적 유료 클라우드 처리를 함께 제공하는 방식이다. 로컬 사용자는 모델을 준비한 뒤 앱을 사용하고, 클라우드 사용자는 우리 서비스에 로그인한다.

```text
고객 앱 → 우리 서버(로그인·요금제·개인별 잔여량·작업 큐) → AI 제공자
                           ↓
                    처리 결과와 사용량 기록
```

이때 AI 제공자의 키는 우리 서버가 보관한다. 고객에게 키 발급을 요구하지 않으며, 배포 앱 안에 공용 비밀 키를 넣지 않는다. 사업자가 API 비용을 부담하고 상품의 포함 시간/횟수에 맞춰 과금한다. 오픈소스 모델을 자체 GPU 서버에서 운영할 수도 있지만 GPU·저장소·운영 비용은 발생한다.

현재 Windows 앱에는 고객 회원·결제·사용량 원장·다중 고객 데이터 분리 서버가 없다. 기존 Cloudflare 개인 동기화/공유 서버를 다중 고객 SaaS로 그대로 설명하지 않는다. 상품화 단계에서 이 서버 영역과 업로드/보관/삭제 흐름을 별도 구현해야 한다. BYOK는 원하는 고급 사용자를 위한 선택지로 남길 수 있다.
