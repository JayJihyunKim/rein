# DoD — non-git 폴더 안내형 온보딩: git 필요성 안내 → 승인 시 준비 → 계속, 거부 시 중단 (훅 안내 통일)

- date: 2026-09-02 착수 → 2026-09-04 완료 (코드 커밋 dev aafbc9c). codex 7회차(5회 기본 + 사용자 승인 연장 2회) 후 Medium-only 잔존을 독립 자체 리뷰로 종결, 보안 리뷰 통과
- approved_by_user: true (2026-09-02 "둘 다 승인, 병렬 구현 시작 (권장)" 선택)
- plan ref: 없음 (brainstorm `docs/brainstorms/2026-09-02-non-git-onboarding.md` Option B — 사용자 결정 2026-09-02, spec/plan 생략)
- 근거 리포트: `docs/reports/[issues]_2026-09-01.md` §4-A, §4-C, §6

## 배경

git 저장소가 아닌 폴더에서 세션 시작 훅은 "`git init` 먼저" 라며 초기화를 거부하는데, 프롬프트 제출 안내는 비활성 사유를 모르고 "초기화 스크립트를 실행하라" 고 하고, 그 스크립트는 non-git 을 정식 지원해 정상 완료한다 — 세 지시가 모순이라 사용자가 온보딩 상태를 판단할 수 없다. v2 거버넌스(리뷰 증거·커밋 게이트·정책 버전 수명주기)는 git 상태에 결속돼 있어 non-git 프로젝트에서는 편집 게이트만 동작하는 반쪽 상태가 된다.

## 범위 (사용자 결정: git 필수 + 안내형 온보딩)

1. **안내문 단일 소스**: 새 lib `hooks/lib/git-required-guidance.sh` 가 사유(`non-git-dir` / `git-missing`)별 안내문 한 벌을 생성한다. 내용: (a) 사용자용 — 왜 git 이 필요한지 한 줄(리뷰·커밋 게이트와 증거가 git 상태에 결속), (b) 어시스턴트 지시 — "사용자에게 지금 이 폴더에서 `git init`(또는 git 설치)을 해도 되는지 먼저 물어보고, 승인하면 `git init` → `python3 <bootstrap_script> --project-dir <dir>` 를 실행하고 완료를 알린다. 거부하면 이 폴더에서는 rein 이 꺼진 채로 두고, 나중에 켜는 방법을 한 줄로 안내한다. 승인 없이 실행하지 않는다." 스크립트 경로는 절대경로로 전개.
2. **세션 시작 훅** `hooks/session-start-bootstrap.sh`: 분기 2(git 없음)·3(non-git)이 degraded 마커는 그대로 쓰되 출력을 위 lib 안내문으로 교체(설치 명령 목록은 git-missing 안내에 포함).
3. **프롬프트 제출 안내** `hooks/lib/bootstrap-check.sh`: 초기화 미완료 판정 시 degraded 마커의 사유가 `non-git-dir`/`git-missing` 이면 fresh/partial 템플릿 대신 같은 lib 안내문을 낸다(두 훅의 지시 일치가 기계적으로 보장).
4. **초기화 스크립트** `scripts/rein-bootstrap-project.py`: non-git 폴백을 기본 **거부**(비0 종료 코드 + "not a git repository — run git init first, or pass --allow-non-git")로 바꾸고 기존 폴백은 `--allow-non-git` 플래그 뒤로 옮긴다. 초기화 성공 시 `<root>/.claude/cache/.rein-session-degraded` 가 있으면 제거해 같은 세션에서 거버넌스가 바로 켜진다(재시작 불필요).
5-a. **명령 렌더링 안전성**: 안내문에 넣는 스크립트 경로·프로젝트 경로는 셸 단일 인자 인용(`printf %q`)으로 렌더링한다(큰따옴표 감싸기 금지). 기존 fresh/partial 템플릿의 실행 명령도 같은 규칙.
5-b. **두 훅의 프로젝트 경로 동일 출처**: 세션 시작 훅도 `bootstrap_check` 가 확정한 프로젝트 경로(이벤트 cwd 우선)를 그대로 써서 비활성 표식과 안내문 인자를 만든다.
5-c. **거부 후 반복 질문 방지**: 세션당 한 번만 전체 안내(승인 질문 포함)를 내고, 같은 세션의 이후 프롬프트에는 짧은 알림 한 줄만(다시 묻지 않음). 세션 키는 활성 작업 선택 표식과 같은 규약(`REIN_SESSION_ID` → PPID).
5-d. **bash 게이트 허용목록**: 초기화 명령 뒤에 `--allow-non-git` 한 토큰만 추가로 허용(다른 토큰·메타문자는 계속 차단).
5-f. **세션 시작 훅의 단일 확정 경로**: `bootstrap_check` 가 확정한 경로 하나로 git 판정·자동 초기화·표식 쓰기/지우기·안내·프라이머·표시 청소를 모두 수행($PWD 와 이벤트 cwd 가 다른 혼합 조합에서도 이벤트 폴더 기준).
5-g. **복구 명령과 bash 게이트의 정합**: 인용 헬퍼 하나(작은따옴표 우선, 작은따옴표 포함 시 `%q`)를 안내문·템플릿·게이트가 공유하고, 게이트는 확정 경로로 만든 기대 명령과의 정확 일치 경로를 정규식 앞에 둔다(정규식은 불변, 넓히지 않음). 작은따옴표가 든 경로는 게이트가 차단하는 것을 허용된 한계로 명시.
5-e. **README 두 벌**: non-git 지원 서술을 새 정책(git 필수, 승인 후 git init, `--allow-non-git` 은 명시적 opt-in)으로 정정, KR/EN 1:1.
5. **프라이머 상태 한 줄** `hooks/session-start-rules.sh`: 첫 세션 프라이머 끝에 초기화 상태 한 줄("초기화는 이미 끝났어요" / "초기화는 아직이에요 — 위 안내를 따라 주세요")을 붙인다. 마커 개명은 하지 않는다.

포함하지 않음: `.rein/.onboarded` 개명, non-git 자동 초기화, bootstrap-check.sh 의 3마커 판정 규칙 변경, 세션 종료 훅 잔여물(별도 DoD).

## 변경 파일

- `plugins/rein-core/hooks/lib/git-required-guidance.sh` (신규 — 사유별 안내문 생성 함수 1개, 의존성 없음)
- `plugins/rein-core/hooks/session-start-bootstrap.sh` (분기 2·3 출력 교체)
- `plugins/rein-core/hooks/lib/bootstrap-check.sh` (degraded 사유 분기 → lib 안내문)
- `plugins/rein-core/scripts/rein-bootstrap-project.py` (`--allow-non-git`, 기본 거부 종료 코드, 성공 시 degraded 마커 제거)
- `plugins/rein-core/hooks/session-start-rules.sh` (프라이머 상태 한 줄)
- `plugins/rein-core/hooks/pre-tool-use-bash-bootstrap-gate.sh` (허용목록에 `--allow-non-git` 옵션 토큰) + `tests/hooks/test-pre-tool-use-bash-bootstrap-gate.sh`
- `README.md`, `README.ko.md` (non-git 서술 정정, 파리티)
- `tests/hooks/test-onboarding-primer.sh` (프라이머 상태 줄 두 상태 + 미출력)
- `tests/hooks/test-session-start-bootstrap.sh` (A/I 케이스: 안내문에 승인 절차·`git init`·스크립트 절대경로 포함)
- `tests/hooks/test-user-prompt-submit-bootstrap-advisory.sh` (non-git degraded → 세션 시작 훅과 동일 안내문, 파리티 단언)
- `tests/scripts/test-rein-bootstrap-project-non-git.sh` (기본 거부 + `--allow-non-git` 폴백 유지 + git 프로젝트 무영향 + 성공 시 degraded 마커 제거)
- `tests/hooks/test-git-required-guidance.sh` (신규 — lib 단위: 두 사유 문구, 절대경로 전개, 금지 문구 없음)

## 검증 기준

- [x] (red→green) non-git 샌드박스에서 세션 시작 훅과 프롬프트 제출 안내가 **같은** 안내문(승인 절차 + `git init` + 스크립트 절대경로)을 낸다 — 수정 전엔 서로 다른 지시.
- [x] (red→green) 초기화 스크립트를 non-git 폴더에 플래그 없이 실행 → 비0 종료 + git init 안내(수정 전엔 rc 0 으로 초기화됨). `--allow-non-git` 이면 기존 동작. git 프로젝트는 무영향.
- [x] 초기화 성공 후 degraded 마커가 제거되어 다음 도구 호출부터 게이트가 정상 경로를 탄다(마커 부재 확인).
- [x] git 없음(`git-missing`) 사유도 같은 구조의 안내문(설치 명령 포함).
- [x] 프라이머 끝에 초기화 상태 한 줄. SessionStart 훅별 주입 예산(~10K자) 초과 없음.
- [x] 안내문의 실행 명령이 특수문자(따옴표·세미콜론·`$(`·공백·백틱) 경로에서도 정확히 한 인자로 해석됨(argv 검증 테스트) **그리고 bash 초기화 게이트를 그대로 통과함(게이트 왕복 테스트; 변조·추가 토큰은 차단)**. `$PWD` 가 git 저장소이고 이벤트 cwd 가 non-git 인 혼합 조합에서 $PWD 저장소를 자동 초기화하지 않고 이벤트 폴더에 안내. 두 훅이 `$PWD` 와 이벤트 cwd 가 다를 때도 같은 폴더에 표식·안내를 냄. 같은 세션의 두 번째 프롬프트부터는 짧은 알림만. bash 게이트가 `--allow-non-git` 만 추가 허용. README 두 벌 정정. 프라이머 상태 줄 테스트.
- [x] 안내문에 내부 식별자·게이트 우회 유도 문구 없음. 훅·스크립트·통합 배터리 초록.

## 라우팅 추천

agent: rein:feature-builder
skills:
  - rein:codex-review
  - superpowers:test-driven-development
mcps: []
security_tier: standard
complexity: medium
model_hint: sonnet
effort_hint: medium
rationale:
  - 새 사용자 흐름(안내형 온보딩) + 스크립트 기본 동작 변경(non-git 거부·플래그 신설) → feature-builder. 모순 수리는 이 흐름의 일부라 DoD 를 더 나누지 않음(파일 겹침)
  - 훅 안내문·스크립트 종료 계약·degraded 마커 제거 등 사용자 프로젝트에 닿는 동작이라 standard 등급, 파일 5+테스트 4 → medium
  - 병렬: 별도 DoD(세션 종료 훅 잔여물)와 파일이 겹치지 않아 워커 동시 진행 가능, 리뷰·커밋은 순차
approved_by_user: true
