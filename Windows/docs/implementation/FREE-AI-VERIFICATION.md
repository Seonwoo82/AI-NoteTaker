# Windows 0.3 무료 AI 검증 기록

검증일: 2026-09-14. 저장소 main `38f843b`에서 추가한 Windows 코드. 이 기록은 실제 계정·유료 API·실제 다중 화자 회의 검증과 구분한다.

## 구현 결과

- Whisper large-v3-turbo + Ollama/Qwen3.5 4B를 기본 무료 조합으로 추가했다. 전사/요약 공급자를 각각 선택하고 전사만·저장 전사로 요약을 실행한다. 기존 OpenRouter 설정은 그대로 불러온다.
- Qwen3-ASR 1.7B/0.6B Q8_0 + BF16 오디오 프로젝터를 선택 가능한 엔진으로 구현했다. llama.cpp b10809 Windows 프로세스를 앱이 열고 닫는다.
- 모델/실행 환경 다운로드는 크기·SHA-256 검증, 중단 파일 보존과 HTTP Range 재개를 지원한다. Ollama 모델은 레지스트리 digest로 관리한다.
- 클로바노트용 90분 WAV 분할 내보내기와 TXT/표준 SRT/붙여넣기 미리보기·연결을 구현했다. 원본·이전 캐시·기존 회의록을 보존한다.
- 전사문 내용 해시를 회의록에 연결해, 다른 전사문에 기반한 회의록에는 다시 정리 안내를 표시한다.

## 동일 입력 전사 비교

환경: Windows 11 x64, Intel i7-13700F, RAM 약 32GiB, NVIDIA RTX 4070 Ti 12GiB. 단독 ASR 작업을 순서대로 실행했다. 다른 데스크톱 앱은 열려 있었다.

표본 A: [sherpa-onnx의 공개 한국어 테스트 WAV](https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/blob/main/test_wavs/ko.wav), 4.607958초. 짧은 문장 '조금만 생각을 하면서 살면 훨씬 편할 거야'. 공개 표본의 라이선스·사용 범위를 별도 데이터셋 전체로 확대 해석하지 않는다.

표본 B: Windows SAPI Microsoft Heami Desktop으로 로컬에서 만든 **합성 회의**, 68.662688초. [평가 원문](../../evaluation/reference-ko.txt)에 담당자, 금요일/다음 주 월요일 기한, 인터뷰 5건, 300만 원 예산 보류, 이메일 자동 발송 제외, 다음 회의 일정을 포함했다. 한 음성으로 읽은 깨끗한 합성 표본으로, 실제 회의 소음·겹침·사투리·화자 분리 성능을 평가하지 않는다.

| 엔진 | 표본 B 전사 시간 | RTF | 숫자 표기를 통일한 CER | 관찰 RAM MB | GPU 전체 피크 MiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| Whisper large-v3-turbo / CUDA12 | 4.50초 | 0.066 | 2/316 = 0.63% | 673 | 5,407 |
| Qwen3-ASR 1.7B / GPU | 7.93초 | 0.116 | 1/316 = 0.32% | 2,760 | 7,295 |
| Qwen3-ASR 0.6B / GPU | 4.35초 | 0.063 | 2/316 = 0.63% | 1,511 | 5,883 |

각 행은 **한 번의 측정**이다. ASR 시간에는 오디오 해시 확인·모델 검증·로딩을 포함하고 모델 다운로드와 요약은 제외했다. RTF는 처리 시간/오디오 길이다. RAM은 평가 프로세스와 해당 모델 폴더의 llama-server 작업 집합을 약 250ms 간격으로 합산한 최대 관찰값이다. 순간 피크나 전체 메모리 할당량과 다르다. GPU 값은 nvidia-smi의 **장치 전체 사용량**으로 다른 앱의 사용량도 포함한다(사전 관찰 약 3,178MiB). 모델만의 VRAM이나 최소 요구량으로 사용하면 안 된다. Qwen의 메인 프로세스 RAM만 비교하는 오류를 피하기 위해 서버 프로세스도 합산했다.

CER 계산은 공백·문장부호 제거, 소문자화, 이 표본의 명시적인 숫자 대응(다섯 건/5건, 삼백만 원/300만 원, 구월/9월, 이십일/20일, 두 시/2시)을 적용한 뒤 Levenshtein 거리로 구했다. 숫자를 통일하지 않으면 Whisper 11/316, Qwen 1.7B 1/316, Qwen 0.6B 2/316이다. 모델명 '큐웬'은 각각 'QN', '쿠웬', 'QN'으로 인식했다. 숫자 대응은 범용 한국어 정규화가 아니다. [계산 코드](../../compare-results.ps1), [측정 요약 JSON](../../evaluation/results-2026-09-14.json).

짧은 표본 A의 CPU 경로도 직접 실행했다. Whisper는 명시적 CPU에서 13.24초(RTF 2.87, 실행 엔진 Cpu), Qwen 0.6B는 CPU에서 5.42초(RTF 1.18)였다. 별도 GPU Whisper 실행은 3.71초였다. 표본 길이·로딩 비용이 달라 표본 B와 직접 속도 순위를 비교하면 안 된다.

입력 SHA-256:

```text
ko.wav: 0DC797A5C81ED30FC339D91F3DA718AB02854E17FFA37CB93C4C039AC5C6BB9C
synthetic-meeting-ko.wav: A95D2D69995CC920E0492BBC2660CA376D550F5B538F12265E4484BE9A88D814
```

## 요약 결과와 한계

Ollama v0.34.0 / qwen3.5:4b, think=false, temperature=0.1, context=8192, output limit=4096. 표본 B 요약은 준비된 모델 기준 8.73초였다. 첫 모델 로딩이 포함된 짧은 표본의 별도 실행에서는 49.28초가 걸렸으므로, 첫 실행 시간이 고정적으로 짧다고 안내하지 않는다.

김민수/금요일, 박지영/다음 주 월요일/인터뷰 5건, 300만 원 예산 미승인, 이번 출시 자동 이메일 발송 제외와 다음 회의 일정을 보존했다. 그러나 전사된 'QN'을 그대로 사용했고, 일부 실행에서 원문에 없는 '검토 프로세스 미수립' 또는 제외 이유에 관한 열린 질문을 덧붙였다. **표본에서의 좋은 전사 결과가 사실 오류 없는 회의록을 뜻하지 않는다.** 원문에 없는 일을 할 일로 만들지 않도록 프롬프트를 보완했지만, 사람 검토는 필요하다. 자동 화자 분리는 지원하지 않는다.

## 실행 검증

| 확인 항목 | 결과와 근거 |
| --- | --- |
| 기존 기능 + 새 로컬 기능 자동 테스트 | 51개 통과, 실패 0. 실제 장치 테스트 5개는 일반 실행에서 건너뜀 |
| 캐시·취소·재시도 | 205.988초 합성 오디오의 첫 120초를 실제 전사한 뒤 두 번째 구간에서 취소. 첫 구간 1개가 저장된 미완성 캐시를 확인하고 재실행해 완료. `artifacts/evaluation/cancel-resume/` |
| 공급자 변경·이전 형식 | 기존 OpenRouter 설정 유지, 새 엔진 캐시 이력 저장, 가져온 원문의 엔진 변경 후 유지, 요약 성공 전 기존 회의록 유지 테스트 통과 |
| 모델 다운로드 | HTTP Range 이어받기·정상 SHA·잘못된 SHA의 ready 방지·손상 파일 보존 테스트. 실제 내려받은 ASR 모델/실행 환경의 pinned hash 확인 |
| 무음 | Whisper/Qwen 모두 디지털 무음에서 모델을 열지 않고 빈 전사 반환. 아주 작은 잡음·배경음에 대한 환각 전체를 방지하는 VAD 검증은 아님 |
| 클로바노트 내보내기 | 5,401초 PCM 파일을 실제 변환해 5,400초와 1초로 분할. 각 파일 300MB 미만, 총 길이 유지, 원본 SHA 일치. `artifacts/evaluation/boundary/` |
| 가져오기 | TXT·SRT 파싱/시간 검증·원문 보존·오디오 불일치 방지와 WPF 미리보기→확인 버튼→격리 라이브러리 저장 검증 |
| 실제 WPF | Apple 테마, 840×600/기본 크기, 밝은/어두운 화면, Qwen/클라우드 설정, 파형/검색/삭제/복원 및 가져오기 화면 렌더링 통과. `artifacts/ui-smoke/` |
| 실제 AI 버튼 | WPF 전사만→저장 전사로 요약 실행, 키 없는 로컬 결과·0 비용·전사 파일 불변 확인. `artifacts/ui-ai-smoke/` |
| 배포 실행 | self-contained ZIP의 Windows 실행 파일로 Whisper와 Qwen3-ASR 1.7B 전사→Ollama 요약 완료. 실행 서버 자동 시작·종료 확인. `artifacts/packaged-ai-final/`, `artifacts/packaged-qwen-final/` |
| 로컬 통신 경계 | 실행 중 앱과 자식 프로세스의 Established TCP를 관찰했고 관찰한 RemoteAddress는 모두 127.0.0.1. `artifacts/packaged-ai-final/connections.json` |

전사·요약 경로는 설치된 파일과 loopback만 사용하며 모델 준비를 자동 호출하지 않는다. 네트워크 어댑터를 실제로 끊지는 않았다. 테스트용 프로세스 프록시 변경은 자동 승인 검토에서 차단되어 네트워크 차단 환경의 재현은 하지 않았다. TCP 관찰은 샘플링이며 전체 패킷 캡처가 아니다. '완전 차단 상태에서 검증 완료'라고 주장하지 않는다.

처음 단일 EXE 묶음은 Whisper의 native library 탐색에 실패했다. 최종 배포는 필요한 DLL/runtimes를 옆에 둔 폴더 방식으로 고쳤다. ZIP의 모든 파일을 함께 풀어야 한다. 실패한 초기 산출물은 개발 artifacts에 보존했고, 최종 사용자 경로는 `0.3.0/portable-win-x64`이다.

## 다시 실행하기

저장소 루트에서 실행한다. 사용자 녹음은 사용하지 않고 결과를 별도 라이브러리에 저장한다. 로컬 모델을 먼저 준비해야 한다.

```powershell
.\Windows\evaluation\create-korean-fixture.ps1
$models = "$env:LOCALAPPDATA/AI-NoteTaker"
& ./.tools/dotnet/dotnet.exe run --project Windows/NoteTaker.Evaluation -c Release -- Windows/artifacts/evaluation/samples/synthetic-meeting-ko.wav Windows/artifacts/evaluation/new-whisper $models whisper no-summary
# qwen, qwen small, cpu 옵션으로 다른 경로를 비교한다.
& ./.tools/dotnet/dotnet.exe run --project Windows/NoteTaker.Evaluation -c Release -- boundary Windows/artifacts/evaluation/samples/synthetic-meeting-ko.wav Windows/artifacts/evaluation/new-boundary
# 생성된 three-meetings.wav에 cancel-resume 옵션을 사용하면 두 번째 구간 취소 후 재개를 확인한다.
```

Windows 음성 버전에 따라 재생성한 합성 WAV가 달라질 수 있다. 같은 입력으로 엔진들을 비교하고 입력 해시를 함께 기록한다. `artifacts` 원본 로그·오디오·결과는 Git에서 제외된다. 저장소에는 평가 원문, 실행·계산 코드와 요약 지표를 남긴다.

개인 클로바노트 계정의 남은 무료 시간, 실제 업로드/내보내기 형식, 실제 회의 다중 화자 품질, OpenRouter 유료 호출, Qwen3.5 9B, ARM, 장시간 실제 녹음은 이번 완료 범위의 실행 증거가 없다. 기능 구현과 해당 외부/실환경 검증을 구분한다.
