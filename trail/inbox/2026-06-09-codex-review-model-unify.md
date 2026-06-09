# codex 리뷰 모델 gpt-5.5 통일 (v1.4.7)

작업일: 2026-06-09
DoD: trail/dod/dod-2026-06-09-codex-review-model-unify-gpt55.md

## 한 일
- `CODE_MODEL` gpt-5.3-codex-spark → gpt-5.5 (`plugins/rein-core/config/codex-models.sh`). 코드 리뷰 게이트 + 자동 문서(설계/플랜) 리뷰가 동일 모델 사용 (둘 다 `CODE_MODEL` 경유 → 래퍼가 `-m` 전달). 역할 분리 주석 갱신.
- `spec-writer.md` / `plan-writer.md` 옛 모델 라벨 `gpt-5.4` → `gpt-5.5` 정합. 어제(v1.4.6) 단일 출처 작업의 변경파일 목록에서 두 agent 파일이 빠져 라벨이 옛값으로 박제됐던 드리프트.
- `ANALYSIS_MODEL`/`CODE_MODEL` 둘 다 gpt-5.5 로 통일하되 변수 2개는 유지 (미래 코드 특화 모델 재분리 여지).
- 릴리스 v1.4.7 (patch): 버전 표면 2곳(plugin.json + rein.sh), CHANGELOG 엔트리, README ko/en 최신 릴리스 줄.

## 검증
- 값/구문/잔존 0건(`gpt-5.4`/`codex-spark` 0, 주석 historical 예시 1줄 제외). `test-codex-model-failsoft` 15/15, `run-all` 33/33.
- codex 코드리뷰 PASS — 통일한 gpt-5.5 로 첫 dogfood 실행(`model: gpt-5.5` 확인). 보안 PASS(standard). release chore(버전+docs) self-review.

## 사용자 결정
- 수동 `/codex-review` 강도(effort) 선택 질문은 현행 유지 (제거 안 함).
- 배포까지 진행 (dev 커밋 + main 머지 + 태그 + marketplace/mirror).

## 발견된 별개 이슈 (기존 백로그 재현, 미수정)
- active-DoD 선택기가 plan-less 신규 DoD(2026-06-09) 거부 → codex stamp 의 cycle/active_dod 가 옛 DoD(route-bind-1)로 오염. 게이트 통과엔 무해, 추적 라벨만 부정확. trail/index 다음작업 이슈 (1) 과 동일 증상.

## 다음
- v1.4.7 배포 검증 후. 기존 백로그 2건(active-DoD plan-less 거부 / governance-e2e stale) 유지.
