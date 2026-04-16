# DoD: QA 세션 gate 면제

- 날짜: 2026-04-16
- 유형: feat
- 범위: `.claude/hooks/pre-edit-dod-gate.sh`, `.claude/hooks/stop-session-gate.sh`

## 목표

소스 파일 편집이 없는 Q&A 세션에서 stop-session-gate의 index.md/inbox 갱신 요구를 면제한다.

## 완료 기준

- [ ] pre-edit-dod-gate.sh: 소스 파일 편집 통과 시 마커 파일 생성
- [ ] stop-session-gate.sh: 마커 없으면 index.md + inbox 요구 면제
- [ ] session-start-load-sot.sh: 세션 시작 시 마커 초기화
- [ ] 기존 dev 세션 동작 유지 (regression 없음)

## 설계

- 마커: `SOT/dod/.session-has-src-edit`
- pre-edit-dod-gate.sh에서 소스 편집 허용(exit 0) 시 touch
- stop-session-gate.sh에서 마커 부재 시 qa 세션으로 판정 → inbox/index 요구 skip
- session-start-load-sot.sh에서 세션 시작 시 마커 삭제 (이전 세션 잔존 방지)

## 활용 skill/MCP

- 없음 (순수 shell 스크립트 수정)
