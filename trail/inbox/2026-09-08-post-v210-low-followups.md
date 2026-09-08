# v2.1.0 이후 잔여 Low 후속 일괄 수리 — 완료 기록

- date: 2026-09-08
- dod: trail/dod/dod-2026-09-08-post-v210-low-followups.md
- commit: dev `f74eca2`

## 무엇이 바뀌었나 (사용자 관점)

- **서브에이전트 `git stash` 구조적 차단**: Bash 안전 가드에 [P12] 신설. 훅 입력에 서브에이전트 표식(`agent_id`)이 있을 때만 변경성 stash(인자 없음·push/pop/apply/drop/clear/save/branch/create/store/export/import·옵션 시작)를 JSON deny. `list`/`show` 와 메인 세션은 비차단. 전역 옵션(`git -C … stash`)은 P10 의 접두 문법을 공유. 워커가 확인 삼아 시도한 stash 를 새 가드가 실전에서 막는 것도 관찰(훅이 저장소 트리에서 실행됨을 재확인).
- **공유 절 시작 분류기 확장**(P10/P11/P12 공통, 쌍둥이 매처 두 파일 동일): `{`·`)`(case 패턴 끝)·백틱·명령을 이끄는 POSIX 예약어(`if then elif else while until do !`) 뒤를 절 시작으로 인식. 제어문 안 literal 호출·백틱 치환·중괄호 그룹이 이제 P11/P12 에 잡힘. 계약: 토큰 형태만 보고 문법 위치는 보지 않음 → 예약어 뒤 언급은 보수 방향 차단(따옴표 미인식과 같은 한계 클래스, 파서 전환은 범위 밖).
- **초기화 스크립트**: `.rein/project.json` 판정 `is_file()`(디렉터리면 명시 거부), 비 UTF-8 `.gitignore` 바이트 보존(`surrogateescape`) — 거부 대신 보존(Latin-1 프로젝트 잠금 방지).
- **`scripts/rein.sh`**: `: > "$log"` → `printf ''`(리눅스 POSIX 모드 셸 종료 클래스), 정적 검사 범위에 루트 `scripts/*.sh` 추가.
- **리뷰 래퍼**: advisory 분기·envelope 슬롯이 advisory 전용 변수를 읽도록 정합(출력 동일). 루트 미러 동일.
- **테스트 신뢰도**: SV29 역방향 격리; job 스위트 11종 정리 trap 재시도형(래퍼 지연 기록·비동기 GC 와의 "Directory not empty" 경쟁 — `test-job-gc`·`test-job-completion-wrapper` 에서 실측); run-all 6종 실패 스위트 이름 출력 + 이를 검증하는 `test-run-all-failure-listing.sh` 신설.

## 리뷰

- codex 4회차(예산 5): 1회차 Medium(전역 옵션 형태)+Low 3 → 수정; 2회차 High(무인자 stash 뒤 주석·리다이렉션·역슬래시 줄바꿈)+Low 2 → 종결자 집합 계약; 3회차 High(제어문·백틱 안 호출) → 예약어 절 시작 계약; 4회차 High(`case … )` 누락·예약어 뒤 언급 오차단·백틱 열고닫음 미구분)+Medium(`stash export/import`) → `)`·export/import 반영, 나머지는 파서급 형태.
- **종결**: 사용자 승인("지금 바로 승인 종결", 2026-09-08). 4회째 같은 축(정규식 분류기의 셸 문법 범위) 지적이라 계약을 문서화하고 부모 자체 검토로 기록 발급. 수용한 한계: 예약어·중괄호·닫는 백틱 뒤 언급의 보수 방향 오차단, 따옴표 미인식, alias/eval/변수 조립.
- 보안 검토: rein:security-reviewer(sonnet) 표준 등급 PASS, 지적 없음. 보안 축 대상 파일 없음(subject 비어 있음) → 기록 없이 게이트 만족(이전 사이클과 동일).
- 배터리: tests 여섯 묶음(hooks/scripts/skills/integration/rules/agents) 전부 통과, 가드 스위트 95건.

## 운영 교훈

- 새 거부 규칙에 요청서가 두 번 걸림(번호+"케이스", "테스트/검증"+"pass/성공" 공존) — 걸린 줄만 고쳐 재호출, 예산 미소모.
- 공유 분류기를 넓히면 리뷰가 파서급 엣지를 계속 냄 — 3회차 규칙대로 계약으로 닫고 사용자에게 물어 종결.
- 절 시작에 `{` 를 넣자 부모 자신의 히어독 안 테스트 문자열(중괄호 그룹으로 감싼 파괴적 git 명령 리터럴)이 P11 에 두 번 걸림 — 주 세션엔 히어독 소거가 없어 보수적으로 차단(정상). 명령 텍스트에 그런 리터럴을 통째로 쓰지 말고 나눠 쓸 것.
- 배터리 첫 실행에서 SKILL.md 크기 상한(6144B) 초과가 잡힘 — 스킬 문구 추가 시 상한 확인.

## 잔여

- 파서급 형태(예약어 위치 판정, 백틱 열고닫음, 따옴표 안 구분자)는 정규식 분류기 계약 밖 — 별도 설계 사이클 후보(셸 파서 도입 여부).
- 릴리스: hook 차단 범위 신설(서브에이전트 한정) + `scripts/rein.sh`·초기화 스크립트 수정 → 배포 시 사용자 결정(사용자 승인 예외 minor 또는 patch). 이 사이클은 dev 커밋까지.
