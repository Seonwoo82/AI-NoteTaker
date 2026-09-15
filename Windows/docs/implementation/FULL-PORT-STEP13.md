# 배포 검증에서 발견한 회의 분석·폴더 조작 보완

2026-09-16. 전체 이식 감사와 0.4.0 ZIP 검증 중 발견한 문제를 수정했다. 전체 목표는 아직 완료 처리하지 않았다.

## 모델 출력과 저장 계약 일치

`verify-package.ps1 -AllFeatures`로 새로 푼 ZIP의 UI, Whisper, Qwen, 트레이, 파일 입력 녹음 흐름, 참여자·프로필을 확인했다. 이어진 회의 분석에서는 Qwen3.5 4B가 질문의 근거를 빈 배열로 만들고 미답변 질문에 답변 근거를 붙였다. 저장 검증이 이를 거부해 기존 자료는 보존됐으며, 포터블 검증은 실패로 기록했다. 결과: `Windows/artifacts/verify-package-4657f793/verification/meeting/error.txt`.

출력 JSON schema를 저장 계약에 맞췄다. 질문·업무·결정의 근거에는 최소 한 개의 실제 발화 ID가 필요하다. 답변이 있는 상태는 답변 본문과 근거가 필요하고, 미답변은 null 본문과 빈 답변 근거만 생성할 수 있다. 결정에는 적어도 한 단계가 필요하다. 자기소개·평서문·답변을 질문으로 만들지 않도록 지시도 보완했다. 형식 검증을 완화하거나 실패 항목을 조용히 삭제하지 않는다.

변경 후 실제 WPF/로컬 모델 `--smoke-meeting`이 성공했다. 약 23.95초, 업무 5/질문 2/결정 3, 업무 상태 편집·필터·정확한 근거 이동·프로젝트 자동 선택·다른 회의 이동·원본 보존을 확인했다. `Windows/artifacts/meeting-schema-step13/result.json`. 구조상 유효한 결과의 의미 분류가 항상 정확하다는 뜻은 아니다.

## 폴더 삽입 위치

upstream 폴더 드래그는 대상 헤더의 위·아래에 삽입선을 표시한다. Windows는 대상 앞에만 이동하던 경로였다. 헤더의 위/아래 절반을 구분하고 파란 삽입선을 표시해 앞·뒤 모두 이동하도록 수정했다. 드래그 종료·이탈·취소 때 표시와 대기 이동을 정리한다. 자기 자신은 대상으로 삼지 않는다.

실제 WPF의 앞/뒤 미리보기·적용·자기 대상 거부·취소를 검사했고, 순서와 재생 위치 보존을 확인했다. 밝은 삽입선 렌더를 직접 확인했다. `Windows/artifacts/folder-insertion-step13/`. 이 검증은 같은 실행 함수를 호출한 WPF 검증이며 실제 마우스의 OLE 드래그 경로 전체를 재현한 것은 아니다.

## Worker Windows 테스트 환경

Python 3 실행 파일을 `PYTHON=python`으로 지정한 Windows에서 일부 한국어 프로필 테스트가 HTTP 500으로 실패했다. SQLite 테스트의 Python 표준 입력이 UTF-8 JSON을 Windows 기본 문자셋으로 해석하는 문제였다. 각 Python subprocess에 `-X utf8`을 적용한 뒤 Worker **93개 모두 통과**했다. `Windows/artifacts/worker-final-test.log`. 서버 제품 동작은 변경하지 않았다.

## 추가로 확인한 이식 누락

upstream `LibraryStore.swift`와 `LibraryController.swift`에 **영구 삭제·30일 지난 삭제 항목 정리·기기 로컬 삭제 표식**, 그리고 **저장된 오디오 내보내기**가 있다. Windows에는 현재 삭제/복원과 Clova용 변환만 있어 이 기능은 추가 구현이 필요하다. 삭제 표식과 원격 복원/재다운로드의 상호작용까지 대조하며 구현해야 한다. 이 항목을 제외하고 전체 이식을 완료했다고 판단하지 않는다.

새 ZIP의 최종 재검증, 자연 업무 회의의 의미/화자 정확도, 실제 기기·배포 환경의 미검증 범위도 전체 계획에서 계속 추적한다.

## 수정 후 포터블 재검증

`bc6f0fa253ee8be6cf63a56e708d8c4a8493fb47`에서 만든 0.4.0 후보 ZIP을 새 폴더에 풀고 `verify-package.ps1 -AllFeatures`를 실행해 9개 경로가 모두 통과했다. UI, Whisper, Qwen, Windows 트레이, 파일 입력의 녹음 수명, 참여자, 프로필, 회의 분석, 회의록 보완/정리/목차를 확인했다. 결과: `Windows/artifacts/AI-NoteTaker-0.4.0-win-x64.verification.json`, 새 폴더: `Windows/artifacts/verify-package-479e78cd/`.

ZIP은 650,530,794바이트, SHA-256 `1E6260DC22D8F69756AB13EE65F127A21615BEA8921E02A39BF1411CF27E3380`다. 모델은 외부 모델 폴더를 사용하며 ZIP에 포함되지 않는다. 밝은 재생/폴더 삽입선과 작은 어두운 회의록 화면을 직접 확인했다. 이 후보는 위에 명시한 아직 남은 라이브러리 기능을 포함한 최종 전체 이식 배포는 아니다.

최신 Release 전체 테스트는 211 통과/하드웨어 5 건너뜀이다 (`Windows/artifacts/test-step13/step13.trx`). 별도로 생성한 낮은 음량의 테스트 신호만 재생하는 `PlayerOpensPausesAndResumesGeneratedAudio`를 실제 출력 장치에서 실행해 1개 통과했다 (`playback-device.trx`). 마이크·루프백 캡처를 실행하거나 사람의 청취 평가를 한 것은 아니다.
