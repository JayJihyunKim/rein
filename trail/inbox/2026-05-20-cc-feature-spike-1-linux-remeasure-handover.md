# SPIKE-1 Linux 재측정 handover (Phase 2b 진입 first step)

- 날짜: 2026-05-20 (handover 작성일 — 측정은 사용자 별 session 에서)
- 유형: research / handover (no bump)
- DoD: trail/dod/dod-2026-05-20-cc-feature-spike-1-linux-remeasure-prep.md
- plan ref: docs/plans/2026-05-19-cc-feature-adoption.md Phase 2 / Task 2.1 (second-pass 측정)
- covers: [SPIKE-1-verification-spike-measures-parallel-hook-exit2-deny-merge-semantics-and-posttooluse-tool-use-id-presence-and-records-go-no-go-criteria]

## 요약

macOS 단일 환경에서 측정한 SPIKE-1 결과 (HK-4 GO + PERF-2 GO + hot-reload 부재 양방향 증거) 를 Linux 환경에서 second-pass 재측정해 OS-portability 를 검증한다. **사용자가 Linux 환경 (Docker 또는 native Linux/VM) 에서 Claude Code 새 session 을 열어 본 절차를 따라 측정**. 결과 jsonl 발췌 + 판정을 본 repo 의 `docs/reports/2026-05-19-cc-feature-spike.md` 의 §10 (Linux second-pass) 으로 append 후 commit + push 로 본 cycle 종료.

성공 조건 (handover 의 acceptance): macOS 와 동일하게 HK-4 (별개 entry 모두 fire + deny propagation) + PERF-2 (pre/post `tool_use_id` 매칭) 가 재현되면 Phase 2b 구현 cycle 진입. **재현 실패** (예: deny propagation 안 됨 / tool_use_id 부재) 시 Phase 2b 의 go 판정은 PARTIAL-GO 로 hedging 하고 사용자 재결정.

## 변경 파일

신축 (본 cycle):
- `trail/dod/dod-2026-05-20-cc-feature-spike-1-linux-remeasure-prep.md` (DoD)
- `trail/inbox/2026-05-20-cc-feature-spike-1-linux-remeasure-handover.md` (본 문서)

수정 (사용자 Linux session 에서 — 측정 후):
- `plugins/rein-core/hooks/hooks.json` — 측정 중에만 spike entry 4개 임시 등록, 측정 후 git checkout 으로 revert
- `docs/reports/2026-05-19-cc-feature-spike.md` — §10 (Linux second-pass) append

## 환경 선택

| 환경 | 적합도 | 비고 |
|---|---|---|
| **native Linux 머신 / VM** | ⭐⭐⭐ | 가장 단순. Claude Code 의 PTY / hook 평가가 정상 환경. 사용자 결정 (2026-05-20) 의 default |
| **Docker container** | ⭐⭐ | Claude Code 가 interactive CLI 라 PTY 필요. `docker run -it --rm` 형태 + `claude-code` CLI 의 첫 인증 절차 (`claude login` 또는 token) 가 container 안에서 작동해야 함. 비추 — native Linux 가 가능하면 선택 |
| WSL2 | ⭐⭐⭐ | (사용자가 Docker/VM 선택했지만 참고용) Windows + WSL2 가 있다면 native Linux 동등 |

본 handover 는 native Linux / VM 기준으로 작성. Docker container 의 경우 §4.2 troubleshooting 의 PTY/auth 추가 단계 참고.

## 사전 요구사항

- Linux 머신 (Ubuntu 22.04+ 권장, 다른 distro 도 무방. `bash`, `python3`, `git` 보유)
- Node.js 20+ (Claude Code 의존성)
- 본 repo `JayJihyunKim/rein-dev` 또는 public mirror `JayJihyunKim/rein` clone 권한
- Anthropic Claude account + Claude Code 인증 (OAuth 또는 API token)
- 디스크 ~500MB (Claude Code + plugin + repo 합산)

## 절차

### 1. Linux 환경 setup

```bash
# native Linux / VM 에서 작업
sudo apt-get update
sudo apt-get install -y bash git python3 curl

# Node.js 20 (NodeSource — Claude Code 최소 요구사항)
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# 버전 확인
node --version    # v20.x 이상
python3 --version # 3.10+
bash --version    # GNU bash 5.x
```

### 2. Claude Code 설치

```bash
# Claude Code CLI 글로벌 설치
npm install -g @anthropic-ai/claude-code

# 인증 — interactive prompt (browser OAuth 또는 token paste)
claude login
```

> Docker container 에서 실행 시 `claude login` 의 browser OAuth 가 막힐 수 있음 — 그 경우 token 방식으로 인증 (Anthropic console 에서 발급).

### 3. 본 repo clone + rein plugin install

```bash
mkdir -p ~/work && cd ~/work

# SPIKE-1 commit (f8e2b79) 은 dev 에 있음 — fresh clone 의 default branch (main = v1.3.2 stable)
# 에는 spike probe 가 부재. 반드시 dev branch 로 진입.
git clone -b dev https://github.com/JayJihyunKim/rein-dev.git
cd rein-dev

# 안전망: clone 직후 현재 branch / log 확인
git branch --show-current   # "dev" 보여야 함
git log --oneline -5
# 첫 commit 에 "chore(spike): Task 2.1 — 병렬 hook exit/deny + tool_use_id 측정 (SPIKE-1)" 보여야 함

# main 으로 떨어졌다면 (예: -b 옵션 누락 / older git):
#   git checkout dev && git pull --ff-only origin dev
```

Claude Code 가 `.claude/settings.local.json` 의 `enabledPlugins` 에 rein 을 자동 등록하려면 plugin marketplace 추가가 필요. **새 Claude Code session 안에서** 다음 slash command 실행:

```
/plugin marketplace add JayJihyunKim/rein
/plugin install rein@rein
```

또는 메인테이너 dogfood 환경처럼 directory source 로 등록:

```
/plugin marketplace add /home/<user>/work/rein-dev
/plugin install rein@rein
```

> directory source 는 self-marketplace manifest (`/home/<user>/work/rein-dev/.claude-plugin/marketplace.json`) 를 참조. 본 manifest 의 `plugins[0].name = "rein"` (디렉터리만 `./plugins/rein-core`) 이므로 install 명령의 plugin name 은 `rein` 으로 통일. plugin source 가 `plugins/rein-core/**` 이므로 본 repo 의 spike probe 가 그대로 사용됨.

### 4. probe 존재 확인

```bash
ls -la tests/hooks/spike-*.sh
# -rwxr-xr-x ... tests/hooks/spike-parallel-exit-probe.sh
# -rwxr-xr-x ... tests/hooks/spike-tool-use-id-probe.sh

# exec bit 확인 (git tree)
git ls-files -s tests/hooks/spike-*.sh
# 100755 ... tests/hooks/spike-parallel-exit-probe.sh
# 100755 ... tests/hooks/spike-tool-use-id-probe.sh

# bash 구문 검증
bash -n tests/hooks/spike-parallel-exit-probe.sh
bash -n tests/hooks/spike-tool-use-id-probe.sh
# 둘 다 exit 0
```

### 5. hooks.json 임시 등록 (spike entry 4개)

`plugins/rein-core/hooks/hooks.json` 편집. **본 측정 cycle 의 새 session 진입 전에 등록** (Claude Code 가 session boot 시점의 hooks.json 만 캐싱 — 본 가설은 macOS cycle 에서 양방향으로 확인됨).

PreToolUse 블록의 `Edit|Write|MultiEdit` matcher 두 번째 entry 로 추가:

```json
{
  "matcher": "Edit|Write|MultiEdit",
  "hooks": [
    {
      "type": "command",
      "command": "PROBE_PHASE=pre ${CLAUDE_PROJECT_DIR}/tests/hooks/spike-tool-use-id-probe.sh"
    }
  ]
}
```

PostToolUse 블록의 `Edit|Write|MultiEdit` matcher 옆에 별개 entry 3개 추가:

```json
{
  "matcher": "Edit|Write|MultiEdit",
  "hooks": [
    {
      "type": "command",
      "command": "PROBE_PHASE=post ${CLAUDE_PROJECT_DIR}/tests/hooks/spike-tool-use-id-probe.sh"
    }
  ]
},
{
  "matcher": "Edit|Write|MultiEdit",
  "hooks": [
    {
      "type": "command",
      "command": "PROBE_ROLE=allow ${CLAUDE_PROJECT_DIR}/tests/hooks/spike-parallel-exit-probe.sh"
    }
  ]
},
{
  "matcher": "Edit|Write|MultiEdit",
  "hooks": [
    {
      "type": "command",
      "command": "PROBE_ROLE=deny ${CLAUDE_PROJECT_DIR}/tests/hooks/spike-parallel-exit-probe.sh"
    }
  ]
}
```

> macOS cycle 의 정확한 diff 를 보고 싶다면: 본 handover commit 직전의 `git show f8e2b79 -- plugins/rein-core/hooks/hooks.json` (revert 만 보임) 대신, SPIKE-1 측정 직전의 working tree diff 가 macOS handover (`trail/inbox/2026-05-20-cc-feature-spike-1-handover.md` §변경 파일) 에 인용됨.

편집 후 검증:

```bash
git diff --stat plugins/rein-core/hooks/hooks.json
# 1 file changed, 36 insertions(+) 정도 — macOS cycle 의 diff 와 동일 line 수면 OK

python3 -c 'import json; json.load(open("plugins/rein-core/hooks/hooks.json"))' && echo "valid JSON"
```

### 6. 측정 — 새 Claude Code session 의 첫 Write

**중요**: hooks.json 편집은 **현재 작업 중인 session 의 외부 shell 에서** (또는 사용자 favorite editor 로) 수행. 같은 session 안에서 hooks.json 을 편집하면 hot-reload 부재 가설 (macOS cycle 의 핵심 finding) 때문에 probe 가 fire 안 됨. 다음 절차:

1. 현재 Claude Code session 을 종료 (Ctrl+C 또는 `/quit`)
2. hooks.json 의 spike entry 4개가 등록된 상태인지 다시 한번 확인 (`git diff --stat plugins/rein-core/hooks/hooks.json`)
3. **새 Claude Code session 시작**
4. 첫 prompt: 본 handover 의 §6.1 trigger 명령 따라 발사

#### 6.1 Trigger 발사 (3+1 trigger)

새 session 의 첫 prompt 로 다음 Write 를 발사:

```
tests/fixtures/spike/spike-trigger-linux.txt 라는 파일을 새로 만들어줘. 본문은 "SPIKE-1 Linux remeasure trigger #1 — 2026-05-21" 한 줄로.
```

Claude Code 가 Write 도구로 파일 생성 → probe 4개 (pre + post + allow + deny) 가 fire → fixture 4 jsonl 신축.

이어서 같은 파일에 trigger #2, #3 line 추가:

```
방금 만든 spike-trigger-linux.txt 끝에 "trigger #2 — consistency check" 줄을 추가해줘.
```

```
또 추가해줘 "trigger #3 — final consistency check"
```

각 trigger 마다 deny entry 의 system-reminder 가 turn 결과로 노출 — 정상.

#### 6.2 Fixture 누적 확인

```bash
ls -la tests/fixtures/spike/
# .gitignore  (1 line, *  + !.gitignore — 모든 fixture ignore)
# parallel-exit-allow.jsonl
# parallel-exit-deny.jsonl
# tool-use-id-pre.jsonl
# tool-use-id-post.jsonl
# spike-trigger-linux.txt

wc -l tests/fixtures/spike/*.jsonl
# 각 3 line (4 entry × 3 trigger) — 또는 trigger 추가 분만큼
```

### 7. Fixture 분석

`tool_use_id` 매칭 확인:

```bash
for f in tests/fixtures/spike/*.jsonl; do
  echo "=== $f ==="
  python3 -c "
import json, sys
for line in open('$f'):
    d = json.loads(line)
    s = json.loads(d['stdin_raw'])
    print(f\"  {s.get('hook_event_name')} {s.get('tool_use_id','MISSING')} {d['timestamp']}\")
"
done
```

기대:
- `parallel-exit-allow.jsonl` / `parallel-exit-deny.jsonl` / `tool-use-id-post.jsonl` 모두 `PostToolUse` + 동일 `tool_use_id`
- `tool-use-id-pre.jsonl` 의 `tool_use_id` 가 같은 trigger 의 post entry 와 1:1 매칭
- 4 entry 가 trigger 마다 모두 fire (3 trigger → 12 line)

판정:
- **HK-4 재현 ✅**: 4 entry 모두 fire + deny entry 의 `exit 2` 가 system-reminder 로 surface
- **PERF-2 재현 ✅**: pre/post tool_use_id 모두 매칭

부산 관찰 (선택):
- hooks.json revert 후 같은 session 에서 다시 Write/Edit 발사 → probe 가 여전히 fire 되면 macOS 의 양방향 hot-reload 부재 가설이 Linux 에서도 재현됨

### 8. hooks.json revert

```bash
git checkout HEAD -- plugins/rein-core/hooks/hooks.json
git diff --stat plugins/rein-core/hooks/hooks.json
# empty
grep -c 'spike-' plugins/rein-core/hooks/hooks.json
# 0
```

### 9. Report append (§10 Linux second-pass)

`docs/reports/2026-05-19-cc-feature-spike.md` 마지막에 다음 섹션 append (덮어쓰지 말고 신규 §10 으로):

```markdown
## 10. Linux second-pass (사용자 Linux session, 2026-05-21 또는 측정일)

### 10.1 환경

- OS: Ubuntu 22.04 (또는 사용자 환경 명시)
- Claude Code: <version — `claude --version` 결과>
- Node.js: <version>
- 측정 절차: trail/inbox/2026-05-20-cc-feature-spike-1-linux-remeasure-handover.md

### 10.2 결과

```
wc -l tests/fixtures/spike/*.jsonl
<paste>

# tool_use_id 매칭 표
| trigger | PreToolUse tool_use_id | PostToolUse tool_use_id | match |
|---|---|---|---|
| #1 | toolu_XXX | toolu_XXX | ✅ |
| #2 | toolu_YYY | toolu_YYY | ✅ |
| #3 | toolu_ZZZ | toolu_ZZZ | ✅ |
```

### 10.3 판정

- HK-4 Linux: <GO / PARTIAL-GO / NO-GO> — <evidence>
- PERF-2 Linux: <GO / PARTIAL-GO / NO-GO> — <evidence>
- Cross-OS portability: macOS cycle 의 §3 결과와 동등 / 부분 동등 / 상이 — <evidence>

### 10.4 부산 (선택)

- Linux 에서 hot-reload 부재 가설 재현 여부
```

### 10. Commit + dev push

```bash
git add docs/reports/2026-05-19-cc-feature-spike.md
git status --short
# M docs/reports/2026-05-19-cc-feature-spike.md (만)

# hooks.json 이 modified 로 잡히면 revert 누락 — git checkout 다시
git diff --stat plugins/rein-core/hooks/hooks.json && echo "hooks revert ok"

git commit -m "$(cat <<'EOF'
chore(spike): SPIKE-1 Linux second-pass 측정 — §10 추가

Linux <distro/version> 환경에서 SPIKE-1 재측정. HK-4 + PERF-2 cross-OS portability 검증 결과를 docs/reports/2026-05-19-cc-feature-spike.md §10 에 추가.

판정: HK-4 <verdict> / PERF-2 <verdict>.

production 코드 미변경 — hooks.json revert 확인됨. no bump.
EOF
)"

git push origin dev
```

### 11. 사용자에게 본 session (macOS) 보고

사용자는 Linux session 에서 측정/commit 후 macOS session 으로 돌아와 (또는 같은 Claude Code 의 다른 session 에서) 다음 정보 제공:

- Linux 측정 commit sha (`git log -1 --oneline`)
- 핵심 판정 (HK-4 / PERF-2 GO 여부)
- 예외 / 회귀 발견 시 상세

이후 macOS session 이 다음 cycle (Phase 2b 구현 — HK-4 + PERF-2 + HK-5 한 cycle) 진입.

## 성공 조건

본 handover 의 acceptance:

- [ ] Linux 환경에서 §1~§10 절차 정상 완료
- [ ] `docs/reports/2026-05-19-cc-feature-spike.md` §10 append + commit + dev push
- [ ] `plugins/rein-core/hooks/hooks.json` revert 검증 (git diff empty)
- [ ] HK-4 / PERF-2 판정이 macOS 결과 (GO + GO) 와 일치 또는 합리적 사유로 다름 (PARTIAL-GO / NO-GO 시 별 cycle 재진입)
- [ ] tests/fixtures/spike/ 의 raw dump 는 gitignore 처리 — repo 추적 영향 없음

## Troubleshooting

### 4.1 Claude Code install 실패

- Node.js 버전 미달: `node --version` 이 v20+ 이어야 함. v18 이하면 NodeSource 20 으로 재설치
- npm permission 오류: **`sudo npm install -g` 는 사용하지 말 것** (Claude Code 공식 setup 가이드 — permission/security risk). 대신:
  - nvm 으로 user-level Node.js 설치 후 `npm install -g @anthropic-ai/claude-code` (nvm 환경은 sudo 불필요), 또는
  - npm prefix 를 user 디렉터리로 변경: `npm config set prefix ~/.npm-global` + `export PATH=~/.npm-global/bin:$PATH` 후 재시도, 또는
  - distro 의 native node 패키지가 너무 오래됐다면 NodeSource 20 LTS 로 재설치 (앞 §1 단계의 setup_20.x)
- Claude Code 인증 실패: `claude logout` 후 재로그인. browser OAuth 가 막히면 token 방식

### 4.2 Docker container 의 PTY / auth

- `docker run -it --rm` 의 `-it` flag 필수 (interactive + PTY)
- container 안에서 `claude login` 의 browser callback 가 막힘 → host 의 browser 에서 인증 후 token paste 또는 ANTHROPIC_API_KEY env 사용
- volume mount: 본 repo 를 host 에서 mount 하면 container 안에서 clone 불필요 (`docker run -v $(pwd):/work -w /work ...`)

### 4.3 hooks.json 편집 후 probe fire 안 됨

- 가장 흔한 원인: hooks.json 편집을 **현재 작동 중인 Claude Code session 안에서** 수행. Claude Code 는 session boot 시점의 hooks.json snapshot 만 in-memory 유지 (macOS cycle 의 양방향 증거)
- 해결: 현재 session 종료 → hooks.json 편집 확인 → **새 session 시작**

### 4.4 plugin install 실패

- `/plugin marketplace add JayJihyunKim/rein` 의 GitHub fetch 실패: SSH key / GitHub token 확인. fall-back 으로 directory source (`/plugin marketplace add /path/to/rein-dev`)
- plugin install 후 `/plugin list` 에 `rein` 이 안 보이면 marketplace cache 문제 — `/plugin marketplace remove rein` 후 다시 add (plugin name 은 `rein`, 디렉터리는 `plugins/rein-core` — 서로 다름)

### 4.5 fixture 가 누적 안 됨 (Write 했는데 jsonl 신축 안 됨)

- §4.3 의 hooks.json hot-reload 부재 — 새 session 으로 재시작
- probe 의 `exec` bit 누락: `git ls-files -s tests/hooks/spike-*.sh` 가 `100755` 이어야 함. `100644` 이면 `chmod +x` + `git update-index --chmod=+x`
- `tests/fixtures/spike/` directory 부재: probe 의 `mkdir -p` 가 실패하면 fixture write 도 실패. parent permission 확인

## 연관

- 본 DoD: trail/dod/dod-2026-05-20-cc-feature-spike-1-linux-remeasure-prep.md
- macOS cycle handover: trail/inbox/2026-05-20-cc-feature-spike-1-handover.md (이전 cycle 측정 인계)
- macOS cycle inbox: trail/inbox/2026-05-20-cc-feature-spike-1-measurement.md (이전 cycle 결과 + 판정)
- macOS report: docs/reports/2026-05-19-cc-feature-spike.md (§3~§7 macOS 측정, §10 Linux append 대상)
- plan: docs/plans/2026-05-19-cc-feature-adoption.md Phase 2 / Task 2.1
- spec: docs/specs/2026-05-19-cc-feature-adoption.md Scope SPIKE-1
- memory `project_cc_feature_adoption.md` — Phase 진행 trace
