# 상세 발화 시간과 재분석의 참여자 연결

2026-09-16, `codex/windows-complete-port`. 최신 원격 main `2aaf0532e48016b32571c7929984a8f474e812ee`가 그대로임을 재확인했다. 전체 이식은 진행 중이다.

## 변경

Whisper의 단어/토큰 시간을 사용해 문장 안의 참여자 변화를 나눈다. UTF-8 바이트 조각이 여러 토큰에 나뉘면 Whisper.net이 각 토큰을 문자열로 변환할 때 한국어·중국어 일부를 대체 문자로 반환하는 것을 실제 음성에서 확인했다. 공개 `IStringPool` 인터페이스를 통해 원래 바이트를 복사해 보관하고, 전체 문장과 일치하는지 검사한 뒤 완전한 Unicode 문자 경계에서 조합한다. 문자열 객체의 메모리나 길이를 변경하지 않는다. 결합 문자와 이모지도 분리하지 않는다.

토큰 `Start/End`의 centisecond를 초로 변환한다. 시간이 없는 텍스트도 표시하되, 인접 발화와 연결한 부분은 참여자를 미지정으로 둔다. 문장 시간만 제공되면 기존 문장 단위 구분을 유지한다. 각 단어에 임의의 양수 길이를 만들어 넣지 않는다. 새 Whisper 전사는 상세 시간을 같은 캐시에 저장하고, 120초를 넘는 구간에서는 문장과 단어 시간을 함께 절대 시간으로 이동한다.

기존 전사에 시간이 부족하면 `participant-transcript-local.json`을 별도로 준비한다. 원래 전사 파일은 보존한다. Qwen 로컬 전사의 시간 보완에는 로컬 Whisper를 사용하며 처리 중 이를 안내한다. 사용자가 가져온 전사문은 선택한 원본과 시간을 그대로 사용한다. 상세 캐시는 오디오 해시·원본 전사 내용/설정·모델 기준으로 검증하고, 취소 후 완료한 구간부터 재개한다.

OpenRouter에는 `verbose_json`, `timestamp_granularities: ["segment", "word"]`를 요청한다. 시간 정보가 없는 모델이나 상세 요청에 400을 반환하는 모델은 Whisper Large V3로 한 번 대체한다. GPT/MAI 전사 모델의 상세 분석은 Apple 앱과 같이 Whisper 경로를 선택한다. 키/선택 설정은 변경하지 않으며, 이 경로의 실제 유료 호출은 이번 검증에서 하지 않았다. 단어/문장 응답의 시간·문자열 결합, 원문 공백·문장부호 보존, 대체 요청 계약을 HTTP fixture로 확인했다.

재분석 때 단순한 그룹 번호를 사람의 영구 ID로 사용하지 않는다. 기존 로컬 음성 특징과 쌍방 최선의 유사도가 충분히 높고 다른 후보와 차이가 있는 경우만 기존 ID를 유지한다. 그룹 분할·합침으로 모호하면 새 ID를 부여하고 기존 수정 이력은 미연결로 남긴다. 시간 업그레이드로 나뉜 발화는 원문과 범위가 정확히 일치하는 경우 사용자가 수정한 기존 발화 ID를 보존한다. 원문이 달라진 경우 추측해 수정을 옮기지 않는다.

## 증거

- 테스트 **118 통과, 5 하드웨어 건너뜀**. UTF-8 토큰 원본 보존, 이모지/결합 문자, 미지정 시간, 구간 offset, HTTP 요청/오류/대체, 캐시 취소·재개·원본 보존, 그룹 번호 교환과 모호한 분할, 수동 발화의 보수적 재연결을 포함한다.
- `Windows/artifacts/token-timing-ko-aligned/result.json`: 기존 한국어 합성 회의 샘플에서 17개 문장, 224개 Unicode 문자 경계에 맞춘 시간 조각. 모든 문장이 글자 손실 없이 재결합됨.
- `Windows/artifacts/token-timing-zh-aligned/result.json`: Sherpa 공개 중국어 4인 음성에서 13개 문장, 117개 시간 조각. 모든 문장이 글자 손실 없이 재결합됨.
- `Windows/artifacts/word-identity-smoke/result.txt`: 실제 WPF 동작으로 Whisper+Sherpa, 4개 참여자 그룹과 22개 발화를 확인. 기존 시간 없는 전사에서 독립 상세 캐시 생성, 인원 4명 지정 재분석 후 동일 화자 ID·수동 이름·본인 표시 유지, 원본 오디오/전사/회의록 보존, 3,000개 목록 가상화 통과. 밝은/작은 어두운 UI 렌더링 확인.
- `Windows/artifacts/word-portable-smoke/result.txt`: 새 self-contained 폴더의 EXE와 포함한 SpeechWorker 런타임에서도 위 WPF·실제 모델·원본 보존 흐름 통과.

실제 마이크를 열지 않았으며, 공개 파일과 한국어 합성 샘플의 데이터 보존/시간 조합 검증이다. 이를 한국어 실제 다자 회의 정확도나 장시간 처리 성능 증거로 확대하지 않는다. 구성상 상세 전사는 최대 6시간, 현재 화자 worker 오디오 로더는 최대 4시간이므로 최종 장시간 지원 범위는 아직 맞추고 검증해야 한다.

근거: 저장소의 `Shared/MeetingIntelligence/TranscriptAssembler.swift`·`ParticipantTranscriptionPolicy.swift`, [Whisper.net 1.9.1의 native 토큰 처리](https://github.com/sandrohanea/whisper.net/blob/1.9.1/Whisper.net/WhisperProcessor.cs), [OpenRouter 상세 전사 안내](https://openrouter.ai/docs/guides/overview/multimodal/stt). 실제 공개 STT 모델 목록에서 `openai/whisper-large-v3`가 존재함도 확인했다.

다음 구현은 근거 발화가 연결된 약속/요청, 질문/답변, 결정 흐름의 모델 호출과 WPF 화면, 프로젝트별 이전 회의 브리핑이다. 현재 구조화 데이터 계약과 검증기는 있으나 이 서비스/UI는 아직 없다.
