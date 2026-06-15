# 2026-06-15 — 자동모드 문서 정정 + 메타체크 방치-untracked false-positive 수정

## 발단

외부 사용자 제보: "자동모드 마커를 켰는데도 작업 도중 세션 종료 게이트(trail 인덱스 미갱신)가 두 번 떴다." `/codex-ask` 독립 검증으로 제보의 코드 진단 4건이 전부 사실임을 확인 (codex + 직접 대조 일치).

## 판정

- **버그 아님 / 문서 과장**: 자동모드 silent 분기는 `stop-session-gate.sh` 의 incident 관련 블록(반복 advisory / 미처리 incident / 3회 초과)에만 있고, inbox/index 작업증거 종료 차단(467-481행)에는 원래 없다. `lib/auto-mode.sh:4-8` 주석이 적용 범위를 "incident-related"로 명시적으로 좁혀 정의하므로, 코드는 일관되고 스킬 문서만 "모두 silent"라고 과장. → codex 권고대로 **문서만 정정** (사용자 결정).
- **부수 결함(메타체크)**: `post-edit-meta-check.sh` 가 untracked 전체를 D 집합에 합쳐, 방치된 untracked(*.parquet 등)가 매 편집마다 false-positive 불일치 경고를 유발. → 사용자 결정 "같이 수정".

## 한 일

- **AMD-1 (문서)**: `auto-mode-on/SKILL.md`(description+본문+주의) + `auto-mode-off/SKILL.md`(description) 에서 "모든 stop-session-gate block silent" → "incident 관련 block 만 silent, 작업증거 종료 차단은 자동모드여도 발동"으로 정정. 코드 무변경.
- **MCU-1 (코드, reproduction-first)**: untracked 를 D 에 합치기 전 mtime-window 필터 추가. 앵커 = `trail/incidents/.session-start-line` mtime(세션 시작). 앵커보다 오래된 untracked = 방치로 제외, 이후 = 이번 세션 작업으로 포함. 앵커 부재/판독불가/개별 파일 판독실패 → fail-open(전체 포함, 새 Write 탐지 보존). tracked diff 경로 무변경. 재현 fixture F14/F15/F16 추가.

## 검증

- `test-post-edit-meta-check.sh` 16 fixture GREEN, `-perf` p95 173ms(≤180) GREEN, `bash -n` OK.
- codex 코드 리뷰 PASS (코드 결함 0, codex 가 테스트 직접 재실행 확인). 보안 리뷰 PASS (적대적 파일명/mtime 실측, injection·traversal 0건, 내용 충실 표식).

## 상태

dev working tree 에 적용 완료, 미커밋. 두 리뷰 표식 존재. 릴리스(버전 bump + main 머지)는 별도 승인 대기 — Rule A 상 hook 동작변경=user-facing 버그수정 patch + SKILL.md 문서 정정 동봉.
