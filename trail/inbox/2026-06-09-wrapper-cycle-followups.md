# codex-review wrapper cycle 후속 (2026-06-09)

drift sync 로 시작한 codex-review wrapper 수정(baec1d1)이 6 round 에 걸쳐 결함 6건(B1~B6)을 잡았다. 그 과정에서 분리하기로 한 후속 + 발견한 별개 이슈를 기록한다.

## 1. broader staged-review 전면 재설계 (codex-ask D 권고에서 분리)

B4/B5/B6 는 "리뷰 대상 모드(review subject)" 를 명시해 changed_files / claim_sources / 라벨 / 지시문이 일관되게 모드를 따르도록 했다(bounded consistency fix). 그러나 codex-ask(2026-06-09)는 이것이 **부분 일관성**이고, wrapper 의 모든 envelope 슬롯(freshness hint, diff_base_iso, 기타 context)이 staged 리뷰 대상을 일관되게 따르는 전면 재설계는 별도 작업으로 남기라고 권고했다.

- 근본 원인: wrapper 가 "리뷰-후-커밋"(staged) 흐름과 "커밋-후-리뷰"(PR/commit_range) 흐름을 단일 코드로 처리하면서, 여러 context 슬롯이 제각각 committed/HEAD 를 가정했다.
- 현재(baec1d1): REVIEW_SUBJECT 변수로 changed_files/claim_sources/라벨/지시문 4개 슬롯만 정합.
- 후속 범위: 나머지 슬롯(evidence freshness, ISO hints, diff_base 의미) 전반을 REVIEW_SUBJECT 기반으로 통일하는 spec. brainstorm 부터 시작 권장(단발 패치 누적 회피).
- 우선순위: medium. 현재 4 슬롯 정합으로 실사용(staged 코드 리뷰)은 정확. 나머지는 advisory 성격.

## 2. tests/scripts baseline 실패 2건 (이번 cycle 무관)

wrapper 작업 중 발견. **우리 변경(rein-codex-review.sh)과 무관** — 변경 3파일을 stash 한 깨끗한 상태에서도 동일 실패(여러 worker + 부모가 실측 확인).

- `tests/scripts/test-perf3-bash-rules-cold-path-skip.sh`: `pre-tool-use-bash-rules.sh` 의 hot-path entry 검사 실패("hot-path entry 26개 실측 0", pytest/npm test 등 bare+args entry 부재).
- `tests/scripts/test-plugin-hooks-json-parity.sh`: plugin `hooks.json` 에 `settings.json`/allowlist 에 없는 EXTRA entry.

둘 다 hook 설정(hooks.json / bash-rules) 영역. codex-review wrapper 와 무관한 별개 결함. 언제 들어왔는지(어느 커밋) + 수정은 별도 cycle. 다음 세션에서 우선순위 판단.

## 3. 회고 메모

- self-review(고친 wrapper 가 자기 자신을 리뷰)가 6 round 에 걸쳐 wrapper 의 누적 결함을 정확히 잡아냄 — 좋은 dogfood. 단 "손댈 때마다 새 결함"은 wrapper 가 오래 누적된 context-assembly 부채를 가졌다는 신호. 전면 재설계(#1)로 매듭짓는 게 장기적으로 맞음.
- worker stash 왕복이 DoD 에 충돌 마커를 남긴 사고 1회 → 이후 worker 에게 "git stash 금지, working tree 직접 편집" 명시로 재발 차단. parallel-execute/feature-builder worker 에 stash 금지를 기본 계약으로 넣을지 검토.
