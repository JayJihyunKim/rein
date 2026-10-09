# 2026-10-08 — v2.3.0 릴리스 (리뷰 델타 증거·수치 구성·보안 무결성 등급·설명/질문/운영 원칙·에이전트 기본 모델·light 면제 문구 정정)

- DoD: `trail/dod/dod-2026-10-08-review-delta-evidence-phase3-release-v2-3-0.md` (plan Phase 3). 사용자 지시 "릴리즈해".
- 코드 리뷰: codex 1회차 PASS(High·Medium 0, Low 참고 1 — `trail/weekly/2026-W40.md` 끝 빈 줄). 요청서는 이번에 문서화한 자가검증 두 축 계약 + 증거 블록 4개(형식 사전검사 통과). 판정 기록 digest sha256:0daa89d3…
- 보안 리뷰: 지휘 경로 — 부모가 subject 캡처(sha256:299187fd…, 경로 12) → `rein:security-reviewer` 워커 → 반환 블록 대조(subject·paths 일치) → 부모 발급(level standard). PASS, Low 참고 1(sub-item 8 이 요청서의 full_run_tree 값으로 git 을 실행하라고 지시 — 리뷰어 샌드박스가 풀리면 40-hex 만 받도록 후속).
- 커밋: feature `a625c98` → dev 병합 `e43a3e8`(push), main `e8a1f29`(격리 worktree 선별 반영, docs/·.claude/ 제외, 삭제분 git rm), 태그 `v2.3.0`. main 트리 bash -n 0 실패·drift OK·다섯 러너 실패 집합 dev 와 동일. 로컬 발행 자체 검사(`REIN_PUBLISH_SELF_HOSTED_ONLY=1 rein-publish.sh 2.3.0`) 통과 — tarball·version parity OK.
- Actions: **결제가 복구돼 있었다**. 공식 미러 워크플로가 main·tag 런 모두 success → 공개 main·태그 `88e21dc`(strip 확인: trail/.rein/AGENTS.md/관리용 워크플로 부재). 로컬 미러 스크립트의 force-push 는 원격 ref 가 예상과 달라 거부됨(덮어쓴 것 없음 — 사후 확인).
- 발행 워크플로 실패: preflight 의 훅 테스트 1건 `test-session-start-byte-budget.sh` (c) — session-start-load-trail 출력 9354B > 8000B. 원인은 main 에 실리는 `trail/index.md` 비대(7954B). base 에서도 로컬 8886B 로 실패하던 기존 결함이 이번 index 추가분으로 커짐. publish 잡은 skip(보관용 산출물만 미생성) — 사용자 배포 경로(공개 main 의 marketplace.json)는 미러로 이미 갱신. Windows 잡 실패는 기존 advisory(파이썬 런처 스텁 시뮬레이션). 조치: dev 의 index 를 줄여 다음 CI 부터 통과시킨다(아래 커밋). 태그는 옮기지 않는다.
- GitHub Release: `v2.3.0` Latest (공개 저장소).
- 후속: index 크기 상한을 훅 테스트와 별개로 stop 게이트에서도 경고할지, sub-item 8 의 commit id 형식 제한(보안 Low), 두 번째 사이클(`.rein/review-precheck.sh`·`rein job` 중복 거부/진행률), persona 요약 640B, 로컬 미러 스크립트는 Actions 정상 시 불필요.
- 오케스트레이션: 메인 세션 지휘. 보안 검토 워커 1개(opus, 부모 발급). 리뷰 요청·커밋·병합·main 반영·Release 는 금지목록 항목이라 부모 직접.
