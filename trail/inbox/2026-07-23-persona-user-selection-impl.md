# 페르소나 사용자 선택 + 커스텀 프리셋 — 구현 완료 (2026-07-23)

- DoD: `trail/dod/dod-2026-07-23-persona-user-selection-impl.md` / spec 18 Scope + plan 12 Task 선행 PASS
- 커밋: `909f8c5`(index 압축) → `c67cfa0`(loader) → `099aa27`(불변층+jennie+훅) → `f14c627`(lint)
  → `1e158ef`(스킬) → `130c423`(bootstrap) → `21b327b`(primer) → `f4d5dfc`(docs) → `99dae03`(러너)

## 무엇이 들어갔나

- **중립 기본**: persona.yaml 에 명시 `enabled: true` 만 활성 — 부재/파싱실패/false/문자열 전부 중립.
  기존 자동 boss-ace ON 폐지 (CHANGELOG/README 복원 원라이너 안내).
- **단일 신뢰 경계**: loader `--persona-file` 이 검증 완료 절대 경로 1줄 출력, 훅은 그것만 소비
  (자체 경로 조합 삭제). 커스텀 = `.rein/policy/persona/<name>.md` (realpath containment,
  UTF-8, ≤4천자). 내장 동명 커스텀은 내장 승리. 루트 미설정 시 경로 무발급(불변층 없는 주입 금지).
- **불변층**: `_invariant.md`(371자, `_` 이름이라 선택 불가) 를 훅이 항상 선두 주입 — 프리셋이
  규율 조항을 지울 수 없는 구조. boss-ace 범용 조항 이관.
- **jennie 내장**: 오빠 호칭+유연 대응, 은은한 호감·애교, 냉정 시 단칼 (1,348B).
- **생성 lint** L1~L5 + **persona 스킬**(선택/끄기/7문항 Q&A 생성 — lint 통과 시에만 저장).
- bootstrap 중립 template, 첫 세션 안내 2줄, 매턴 안내 프리셋 무관화+활성 프리셋 요약 1줄.
- 테스트: 신규·재작성 8스위트(25+12+16+9+18+26+4+2) + 러너 등재, 3 러너 전량 GREEN.

## 리뷰 경과

- codex 통합 리뷰 2회 모두 **워치독 정지 판정**(전체 러너를 조용히 실행 — elapsed 360s/450s,
  앵커·부분 출력 정상). 계약대로 재시도 없이 sonnet 대체 리뷰: R1 전체 PASS + codex 유언
  지적 2건 실재 판정 → 작성자 수정(머리말 닫힘 필수화 lint+loader 쌍, 내장 경로 .resolve())
  + 재발 방지 3케이스 → R2 델타 대체 리뷰 PASS(재현 검증). 보안 standard PASS(차단급 0,
  정보성 TOCTOU·전체읽기 2건 위협모델 내 수용).
- 워커 사건: 스킬 워커 1회 무진행 600s 종료 → 재투입 완주. macOS `/var`→`/private/var`
  realpath 정규화가 테스트 기대값 파급 → 기대값도 resolve 로 정합.

## 후속 (비차단)

- Low: 훅 레이어 자동 미폐쇄-머리말 회귀 케이스 부재(lint/loader 레이어 + 수동 재현으로 봉합됨).
- **관찰 누적 3회**: codex 가 저장소 전체 테스트 러너를 조용히 돌리다 워치독 정지 판정 —
  수용된 정책이나 리뷰 완주율을 깎음. "리뷰 요청서에 러너 재실행 지시 제외" 또는 "장시간
  명령 spawn 중 창 연장" 후속 검토 가치 상승.
- 릴리스 시 minor (user-facing 신규 — versioning Rule A). 버전 표면 2곳 동기 필요.
