# trail 부산물 위생 — meta-check jsonl retire + 런타임 커서 untrack (2026-07-13)

## 요약

사용자 요청("trail 에 불필요한 파일 안 남게") 에 따라 3갈래 정리. codex 리뷰 PASS + 보안 리뷰 PASS(취약점 0, "기본 쓰기 표면 순감소" 판정), 훅 테스트 17 픽스처 + 전 스위트 GREEN.

## 변경

1. **meta-check 텔레메트리 retire**: `post-edit-meta-check.sh` 의 무조건 trail/inbox jsonl append 제거. production 소비자 0건 실증(유일 참조 = 집계 산식 픽스처 테스트). 단 행위 테스트 9개의 mismatch 관측 채널이었으므로 `REIN_META_CHECK_TRACE_FILE` env opt-in append 로 대체 — 테스트 oracle 유지 + 실사용 세션 파일 생성 0. 신규 F17 픽스처가 "env 부재 시 advisory 는 발화하되 파일 미생성" 을 회귀 고정.
2. **런타임 커서 untrack**: `trail/incidents/{.last-processed-line,.last-aggregate-state.json,.session-start-line}` git rm --cached + .gitignore (디스크 유지 — 집계 파이프라인 기능 파일). 매 세션 dirty 노이즈 4건 제거. 기존 선례(.aggregate.lock, security-surface-exempt.log) 와 동일 패턴.
3. **삭제**: tracked jsonl 20개, `blocks.log.legacy`(+cleanup-archive-ignore 라인), `tests/scripts/test-meta-check-inbox-aggregate.sh`(retire 된 산식 검증).

## 수용된 트레이드오프

- fresh clone 은 커서 부재로 blocks.jsonl 이력을 1회 재집계할 수 있음 (crash 없음, 코드 fail-open 확인. 메인테이너 repo 한정 edge — codex/보안 리뷰 모두 수용).
- 구버전 플러그인 캐시가 세션 중 jsonl 을 계속 생성 → .gitignore `/trail/inbox/*-meta-check.jsonl` 로 방어. 다음 플러그인 재설치 후 자연 소멸.
- `mirror-to-public.yml` 의 blocks.log.legacy strip 라인은 안전 no-op 이라 유지 (CI 편집 범위 확대 회피).

## 릴리스 메모

훅이 사용자 repo 에 쓰는 파일이 달라지므로 user-facing **patch**. 다음 릴리스에 포함 — CHANGELOG 에 "기존 `trail/inbox/*-meta-check.jsonl` 은 직접 삭제해도 안전" 안내 필요. 사용자 repo 의 커서 파일 gitignore 는 bootstrap 범위 밖 (별도 검토 후보).

## 후속 (비차단)

- 사용자 프로젝트 bootstrap 이 생성하는 .gitignore 에도 커서 3종 반영할지 검토.
- trace append 는 부모 디렉토리 미생성 시 조용히 skip (`|| true`) — 테스트 전용 표면, 보안 리뷰 informational.
- `trail/dod/.session-has-src-edit` 도 같은 부류(휘발성 세션 마커가 git 추적됨) — 이번 DoD 범위 밖이라 미처리. 다음 사이클에서 untrack + ignore 검토. (같은 검토에서 `trail/dod/.active-dod` 추적 여부도 함께.)
- 프로세스 관찰: inbox 기록을 커밋 전에 쓰면 DoD 게이트가 작업을 완료로 판정해 소스 편집이 닫힌다 — 기록은 편집 전부 끝난 뒤 작성이 안전.
