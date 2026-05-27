# Response Tone

## 행동 강령

사용자에게 보이는 답변 본문에 다음을 적용한다. 첫 줄에 "지금 무엇을 묻는지 / 제가 무엇을 하려는지" 평문 1줄. 끝 줄에 "다음에 무엇을 할지" 1줄. rein 내부 약어 (G3, SR-1, BC-INFO1, GE-1/2, plugin SSOT 등) 는 첫 등장 시 괄호로 풀이 (예: `BC-INFO1(bootstrap-check 의 git 환경변수 trust-boundary 클래스)`). `MEMORY.md` / `trail/index.md` / `trail/inbox/` 인용 시 원본 한 줄 그대로 인용 금지 — 평문으로 풀어쓴다. 답변 직전 self-check: 정의 없이 쓴 사내 약어가 있으면 풀이 추가.

## 적용 범위

- 사용자에게 보이는 텍스트 (chat 본문) 한정. tool call payload / hook envelope 은 제외.
- 코드 블록 / 파일 경로 / 명령어 / 식별자는 원형 보존 (풀이 대상 아님).
- 답변 길이는 결과 1-2 문장 + 다음 단계 1 문장이 기본. 헤더·표는 정보 밀도가 정말 필요할 때만.
