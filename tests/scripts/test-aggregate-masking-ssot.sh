#!/bin/bash
# tests/scripts/test-aggregate-masking-ssot.sh
#
# plan Task 7.1 명시 전환 #2 (v2 spec §5.5 [B-5]): rein-aggregate-incidents.py
# 는 non-legacy(source 필드 존재) 예시 target 에
# rein.shadow.masking.redact() 를 방어적으로 추가 적용한다. legacy(source
# 필드 없음) 레코드의 "<legacy-target-redacted>" 통째 치환 로직(별개의
# 신뢰 규칙)은 그대로 유지된다.
#
# F2 (Phase 7 웨이브 4 코드 리뷰 3회차 High): non-legacy 예시는 secret
# 마스킹만 받고 경로 정규화는 받지 않아 사적 절대경로가 그대로 incident
# 파일로 샜다 — redact() 뒤에 rein.shadow.paths.normalize() 도 같은
# fail-closed 계약으로 적용한다(아래 F2 섹션 참조).
#
# 이 스위트는 실제로 스크립트를 서브프로세스로 실행하고 생성된 incident
# 파일 내용을 단언한다 (행위 기반 — source-only 단위 테스트 금지).
#
# 두 사본(plugins/rein-core/scripts/ 와 저장소 루트 scripts/) 은 바이트
# 동일이어야 하므로 이 스위트는 두 경로 모두에 대해 동일 케이스를 돌린다.
#
# R1 (Phase 7 웨이브 4 코드 리뷰 High) 1회차 수정 회귀 핀: sys.modules 에
# 동명 가짜 "rein.shadow.masking" 패키지가 (실제 masking.py 는 정상
# 위치에 있는 채로, __file__ 속성 없이) 선등록돼 있어도 예전 구현이
# _redact_example() 을 그 가짜 모듈에 위임하지 않았는지 검증하던 테스트.
# sitecustomize.py 를 PYTHONPATH 에 얹어 인터프리터 기동 직후(스크립트
# 실행 이전) sys.modules 를 오염시키는 방식으로 실제 서브프로세스에서
# 재현한다.
#
# R5 (2회차 코드 리뷰 High): 1회차 수정("dotted import 후 __file__ 재검증")
# 은 여전히 우회 가능했다 — 진짜 모듈을 먼저 import 시킨 뒤 redact 심볼만
# 교체하거나(__file__ 불변), 가짜 모듈이 __file__ 을 기대 경로로 자칭하면
# 재검증을 통과했다. 수정은 dotted import 를 버리고
# `importlib.util.spec_from_file_location()` 으로 파일에서 직접 로드하며
# sys.modules 에 등록하지 않는다 — 그 결과 위 T4 시나리오의 sys.modules
# 오염은 이제 완전히 무력하고, mask()는 실제 엔진으로 정상 동작한다(더
# 이상 fail-closed placeholder 로 대체되지 않는다 — 아래 T4 assertion
# 갱신 참조). R1-c: 루트 사본 후보 경로도 "파일이 있는 쪽을 탐색" 에서
# "배치를 구조적으로 판정" 으로 바꿔, 루트 사본의 scripts/ 옆에 놓인 동명
# 디코이 rein/shadow/masking.py 를 신뢰하지 않는다 (T5).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGGREGATE_PLUGIN="$PROJECT_DIR/plugins/rein-core/scripts/rein-aggregate-incidents.py"
AGGREGATE_ROOT="$PROJECT_DIR/scripts/rein-aggregate-incidents.py"

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

make_sandbox() {
  local sb
  sb=$(mktemp -d "/tmp/agg-mask-test-XXXXXX")
  mkdir -p "$sb/trail/incidents" "$sb/.rein"
  printf '{"mode":"plugin","scope":"project","version":"1.0.0"}\n' > "$sb/.rein/project.json"
  echo "$sb"
}

# ============================================================
# T1 — non-legacy(source 존재) 예시에 v2 전용 패턴이 redact() 로 마스킹됨
#      (회귀 핀: v1 은 aggregate 자체에 마스킹 규칙이 없었으므로, 이
#      스크립트가 v2 엔진에 위임하기 전엔 --password 공백분리형 원문이
#      그대로 incident 파일에 남아야 한다 — 아래에서 두 스크립트 경로
#      모두 검증)
# ============================================================

run_t1_for() {
  local script_path="$1"
  local label="$2"
  begin "T1 ($label): non-legacy 예시 — v2 전용 패턴(--password 공백분리) 마스킹"
  local sb
  sb=$(make_sandbox)
  local blocks="$sb/trail/incidents/blocks.jsonl"
  local secret="AGG-T1-SECRET-4471"
  printf '{"ts":"2026-08-07T00:00:00","hook":"pre-bash-safety-guard","reason":"agg-t1","target":"docker login --password %s registry.example.com","source":"live"}\n' "$secret" >> "$blocks"
  printf '{"ts":"2026-08-07T00:01:00","hook":"pre-bash-safety-guard","reason":"agg-t1","target":"docker login --password %s registry.example.com","source":"live"}\n' "$secret" >> "$blocks"

  python3 "$script_path" --project-dir "$sb" >/dev/null 2>&1 || fail "aggregate 실행 실패 (exit != 0)"

  local inc_content
  inc_content=$(cat "$sb"/trail/incidents/auto-pre-bash-safety-guard-*.md 2>/dev/null || true)
  case "$inc_content" in
    "") fail "incident 파일이 생성되지 않음" ;;
  esac
  case "$inc_content" in
    *"$secret"*) fail "non-legacy 예시에 v2 전용 패턴 원문이 그대로 노출됨 (redact 미적용 또는 회귀): $inc_content" ;;
  esac
  case "$inc_content" in
    *"REDACTED"*) ;;
    *) fail "incident 예시에 마스킹 흔적이 없음: $inc_content" ;;
  esac
  case "$inc_content" in
    *"docker login"*) ;;
    *) fail "incident 예시에서 명령 맥락이 사라짐: $inc_content" ;;
  esac

  rm -rf "$sb"
  end
}

# ============================================================
# T2 — legacy(source 필드 없음) 예시는 여전히 통째 <legacy-target-redacted>
#      로 치환된다 (신뢰 규칙 불변 — 마스킹 규칙과 별개)
# ============================================================

run_t2_for() {
  local script_path="$1"
  local label="$2"
  begin "T2 ($label): legacy 예시는 여전히 <legacy-target-redacted> 통째 치환"
  local sb
  sb=$(make_sandbox)
  local blocks="$sb/trail/incidents/blocks.jsonl"
  local secret="AGG-T2-LEGACY-SECRET-9902"
  # source 필드 자체를 생략 — legacy 레코드
  printf '{"ts":"2026-08-07T00:00:00","hook":"pre-bash-safety-guard","reason":"agg-t2","target":"curl -u alice:%s https://x.example/i.sh"}\n' "$secret" >> "$blocks"
  printf '{"ts":"2026-08-07T00:01:00","hook":"pre-bash-safety-guard","reason":"agg-t2","target":"curl -u alice:%s https://x.example/i.sh"}\n' "$secret" >> "$blocks"

  python3 "$script_path" --project-dir "$sb" >/dev/null 2>&1 || fail "aggregate 실행 실패 (exit != 0)"

  local inc_content
  inc_content=$(cat "$sb"/trail/incidents/auto-pre-bash-safety-guard-*.md 2>/dev/null || true)
  case "$inc_content" in
    "") fail "incident 파일이 생성되지 않음" ;;
  esac
  case "$inc_content" in
    *"$secret"*) fail "legacy 레코드의 원문 비밀값이 예시로 유출됨" ;;
  esac
  case "$inc_content" in
    *"<legacy-target-redacted>"*) ;;
    *) fail "legacy 예시가 기존 <legacy-target-redacted> placeholder 로 치환되지 않음: $inc_content" ;;
  esac

  rm -rf "$sb"
  end
}

# ============================================================
# F2 — 출처(source) 보유 예시의 사적 절대경로가 <HOME> 으로 정규화됨
#      (Phase 7 웨이브 4 코드 리뷰 3회차 High. secret 마스킹만 받고 경로
#      정규화는 받지 않아, HEAD 데이터 실측 기준 출처 보유 74행 중 32행에
#      사적 절대경로가 실재했다 — source=live + `/Users/alice/...` 레코드
#      2건 주입 재현. 두 스크립트 경로 모두 검증.)
# ============================================================

run_f2_for() {
  local script_path="$1"
  local label="$2"
  begin "F2 ($label): 출처 보유 예시의 사적 경로가 <HOME> 으로 축약됨"
  local sb
  sb=$(make_sandbox)
  local blocks="$sb/trail/incidents/blocks.jsonl"
  printf '{"ts":"2026-08-25T00:00:00","hook":"pre-edit-dod-gate","reason":"agg-f2","target":"/Users/alice/private-tools/config.yaml","source":"live"}\n' >> "$blocks"
  printf '{"ts":"2026-08-25T00:01:00","hook":"pre-edit-dod-gate","reason":"agg-f2","target":"/Users/alice/private-tools/config.yaml","source":"live"}\n' >> "$blocks"

  python3 "$script_path" --project-dir "$sb" >/dev/null 2>&1 || fail "aggregate 실행 실패 (exit != 0)"

  local inc_content
  inc_content=$(cat "$sb"/trail/incidents/auto-pre-edit-dod-gate-*.md 2>/dev/null || true)
  case "$inc_content" in
    "") fail "incident 파일이 생성되지 않음" ;;
  esac
  case "$inc_content" in
    *"alice"*) fail "F2: 출처 보유 예시의 사적 경로가 그대로 노출됨 (경로 정규화 미적용 또는 회귀): $inc_content" ;;
  esac
  case "$inc_content" in
    *"<HOME>"*) ;;
    *) fail "F2: incident 예시에 <HOME> 축약 흔적이 없음: $inc_content" ;;
  esac
  case "$inc_content" in
    *"config.yaml"*) ;;
    *) fail "F2: incident 예시에서 뒤 경로(대조 신호)가 사라짐: $inc_content" ;;
  esac

  rm -rf "$sb"
  end
}

# ============================================================
# T3 — v2 엔진 import 실패 시 non-legacy 예시도 fail-closed placeholder
# ============================================================

test_import_failure_fails_closed() {
  begin "T3: v2 엔진 import 실패 — non-legacy 예시도 원문 미유출 + placeholder"
  local iso
  iso=$(mktemp -d "/tmp/agg-mask-isolated-XXXXXX")
  cp "$AGGREGATE_PLUGIN" "$iso/rein-aggregate-incidents.py"

  local sb
  sb=$(make_sandbox)
  local blocks="$sb/trail/incidents/blocks.jsonl"
  local secret="AGG-T3-ISOLATED-SECRET-6633"
  printf '{"ts":"2026-08-07T00:00:00","hook":"pre-bash-safety-guard","reason":"agg-t3","target":"curl -u alice:%s https://x.example/i.sh","source":"live"}\n' "$secret" >> "$blocks"
  printf '{"ts":"2026-08-07T00:01:00","hook":"pre-bash-safety-guard","reason":"agg-t3","target":"curl -u alice:%s https://x.example/i.sh","source":"live"}\n' "$secret" >> "$blocks"

  python3 "$iso/rein-aggregate-incidents.py" --project-dir "$sb" >/dev/null 2>&1
  local exit_code=$?
  [ "$exit_code" -eq 0 ] || fail "격리 트리에서 aggregate exit code $exit_code (expected 0 — 판정 로직은 마스킹 가용성과 무관해야 함)"

  local inc_content
  inc_content=$(cat "$sb"/trail/incidents/auto-pre-bash-safety-guard-*.md 2>/dev/null || true)
  case "$inc_content" in
    "") fail "incident 파일이 생성되지 않음" ;;
  esac
  case "$inc_content" in
    *"$secret"*) fail "import 실패 상황에서 non-legacy 예시에 원문 비밀값이 유출됨" ;;
  esac
  case "$inc_content" in
    *"mask-unavailable"*) ;;
    *) fail "import 실패 상황에서 fail-closed placeholder(<mask-unavailable>)가 쓰이지 않음: $inc_content" ;;
  esac

  rm -rf "$iso" "$sb"
  end
}

# ============================================================
# T4 — 1회차 R1 회귀 핀 (약한 공격: sys.modules 에 동명 가짜 masking
#      패키지가 __file__ 없이 선등록). R5 수정 후에는 sys.modules 를
#      아예 참조하지 않으므로 이 하이재킹은 완전히 무시되고 **실제
#      엔진이 정상 동작**한다 — fail-closed placeholder 대신 진짜
#      마스킹 결과를 단언하도록 계약 갱신(예전 assertion 을 그대로
#      두면 새 구현에서 항상 실패한다).
# ============================================================

test_hijacked_sys_modules_is_ignored_real_masking_runs() {
  begin "T4 (R1, 1회차): sys.modules 에 동명 가짜 rein.shadow.masking 이 선등록돼도 direct-load 가 무시하고 실제 마스킹 수행"
  local poison
  poison=$(mktemp -d "/tmp/agg-mask-poison-XXXXXX")
  # T3 와 동일한 sitecustomize 기법(위 파일 헤더 주석 참조) — 스크립트
  # 자신의 코드가 실행되기 전에 sys.modules 를 오염시켜, sys.path 조작
  # 없이도 "동명 모듈이 이미 캐시돼 있는" 상황을 재현한다. R5 수정 후
  # _load_v2_redact() 는 애초에 dotted import 를 하지 않으므로 이 오염은
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

  local sb
  sb=$(make_sandbox)
  local blocks="$sb/trail/incidents/blocks.jsonl"
  local secret="AGG-T4-HIJACK-SECRET-2258"
  printf '{"ts":"2026-08-07T00:00:00","hook":"pre-bash-safety-guard","reason":"agg-t4","target":"curl -u alice:%s https://x.example/i.sh","source":"live"}\n' "$secret" >> "$blocks"
  printf '{"ts":"2026-08-07T00:01:00","hook":"pre-bash-safety-guard","reason":"agg-t4","target":"curl -u alice:%s https://x.example/i.sh","source":"live"}\n' "$secret" >> "$blocks"

  PYTHONPATH="$poison" python3 "$AGGREGATE_PLUGIN" --project-dir "$sb" >/dev/null 2>&1
  local exit_code=$?
  [ "$exit_code" -eq 0 ] || fail "sys.modules 하이재킹 상황에서 aggregate exit code $exit_code (expected 0)"

  local inc_content
  inc_content=$(cat "$sb"/trail/incidents/auto-pre-bash-safety-guard-*.md 2>/dev/null || true)
  case "$inc_content" in
    "") fail "incident 파일이 생성되지 않음" ;;
  esac
  case "$inc_content" in
    *"$secret"*) fail "sys.modules 하이재킹 상황에서 원문 비밀값이 예시로 유출됨: $inc_content" ;;
  esac
  case "$inc_content" in
    *"REDACTED"*) ;;
    *) fail "incident 예시가 실제로 마스킹되지 않음 — sys.modules 오염이 direct-load 를 우회한 것으로 의심: $inc_content" ;;
  esac

  rm -rf "$poison" "$sb"
  end
}

# ============================================================
# R5a/R5b — 2회차 코드 리뷰 재현: 1회차 수정("dotted import 후 __file__
#      재검증")이 실제로는 우회 가능함을 증명한 두 시나리오(파일 헤더
#      R5 주석 참조).
# ============================================================

test_r5a_symbol_swap_after_real_import_defeated() {
  begin "R5a: 진짜 모듈을 정상 import 후 redact 심볼만 항등함수로 교체해도 원문 미유출"
  local poison
  poison=$(mktemp -d "/tmp/agg-mask-swap-XXXXXX")
  # sitecustomize.py 가 인터프리터 기동 시점에 **진짜** rein.shadow.masking
  # 을 정상 경로로 import 한 뒤 그 모듈 객체의 redact 속성만 항등함수로
  # 덮어쓴다. __file__ 은 여전히 진짜 경로 그대로다.
  cat > "$poison/sitecustomize.py" <<PY
import sys
sys.path.insert(0, "$PROJECT_DIR/plugins/rein-core")
import rein.shadow.masking as _real_masking
_real_masking.redact = lambda text: text
PY

  local sb
  sb=$(make_sandbox)
  local blocks="$sb/trail/incidents/blocks.jsonl"
  local secret="AGG-R5A-SWAP-SECRET-3391"
  printf '{"ts":"2026-08-07T00:00:00","hook":"pre-bash-safety-guard","reason":"agg-r5a","target":"curl -u alice:%s https://x.example/i.sh","source":"live"}\n' "$secret" >> "$blocks"
  printf '{"ts":"2026-08-07T00:01:00","hook":"pre-bash-safety-guard","reason":"agg-r5a","target":"curl -u alice:%s https://x.example/i.sh","source":"live"}\n' "$secret" >> "$blocks"

  PYTHONPATH="$poison" python3 "$AGGREGATE_PLUGIN" --project-dir "$sb" >/dev/null 2>&1
  local exit_code=$?
  [ "$exit_code" -eq 0 ] || fail "심볼 스왑 상황에서 aggregate exit code $exit_code (expected 0)"

  local inc_content
  inc_content=$(cat "$sb"/trail/incidents/auto-pre-bash-safety-guard-*.md 2>/dev/null || true)
  case "$inc_content" in
    "") fail "incident 파일이 생성되지 않음" ;;
  esac
  case "$inc_content" in
    *"$secret"*) fail "심볼 스왑 상황에서 원문 비밀값이 예시로 유출됨: $inc_content" ;;
  esac
  case "$inc_content" in
    *"REDACTED"*) ;;
    *) fail "incident 예시가 실제로 마스킹되지 않음 — 심볼 스왑이 direct-load 를 우회한 것으로 의심: $inc_content" ;;
  esac

  rm -rf "$poison" "$sb"
  end
}

test_r5b_fake_module_self_reported_file_defeated() {
  begin "R5b: 가짜 모듈이 __file__ 을 기대 경로로 자칭하며 sys.modules 선등록해도 원문 미유출"
  local poison expected_masking
  poison=$(mktemp -d "/tmp/agg-mask-fakefile-XXXXXX")
  expected_masking="$PROJECT_DIR/plugins/rein-core/rein/shadow/masking.py"
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

  local sb
  sb=$(make_sandbox)
  local blocks="$sb/trail/incidents/blocks.jsonl"
  local secret="AGG-R5B-FAKEFILE-SECRET-7724"
  printf '{"ts":"2026-08-07T00:00:00","hook":"pre-bash-safety-guard","reason":"agg-r5b","target":"curl -u alice:%s https://x.example/i.sh","source":"live"}\n' "$secret" >> "$blocks"
  printf '{"ts":"2026-08-07T00:01:00","hook":"pre-bash-safety-guard","reason":"agg-r5b","target":"curl -u alice:%s https://x.example/i.sh","source":"live"}\n' "$secret" >> "$blocks"

  PYTHONPATH="$poison" python3 "$AGGREGATE_PLUGIN" --project-dir "$sb" >/dev/null 2>&1
  local exit_code=$?
  [ "$exit_code" -eq 0 ] || fail "자칭 __file__ 상황에서 aggregate exit code $exit_code (expected 0)"

  local inc_content
  inc_content=$(cat "$sb"/trail/incidents/auto-pre-bash-safety-guard-*.md 2>/dev/null || true)
  case "$inc_content" in
    "") fail "incident 파일이 생성되지 않음" ;;
  esac
  case "$inc_content" in
    *"$secret"*) fail "자칭 __file__ 상황에서 원문 비밀값이 예시로 유출됨: $inc_content" ;;
  esac
  case "$inc_content" in
    *"REDACTED"*) ;;
    *) fail "incident 예시가 실제로 마스킹되지 않음 — 자칭 __file__ 이 direct-load 를 우회한 것으로 의심: $inc_content" ;;
  esac

  rm -rf "$poison" "$sb"
  end
}

# ============================================================
# T5 (R1-c) — 루트 사본 주변(저장소 루트, scripts/ 의 형제)에 동명
#      rein/shadow/masking.py 디코이가 있어도 그걸 신뢰하지 않는다.
#      _package_parent_candidate() 는 더 이상 "파일이 존재하는 후보를
#      탐색" 하지 않고 이 스크립트 자신의 배치를 구조적으로 판정하므로,
#      디코이가 정확히 그 자리(<scripts 부모>/rein/shadow/masking.py)에
#      있어도 후보 경로(<scripts 부모>/plugins/rein-core/rein/…) 에는
#      해당하지 않아 무시되고 fail-closed 로 떨어진다.
# ============================================================

test_r1c_decoy_masking_near_root_copy_ignored() {
  begin "T5 (R1-c): 루트 사본 옆의 디코이 rein/shadow/masking.py 는 신뢰하지 않고 fail-closed"
  local iso
  iso=$(mktemp -d "/tmp/agg-mask-decoy-XXXXXX")
  # 루트 사본 배치를 흉내: <iso>/scripts/rein-aggregate-incidents.py +
  # <iso>/rein/shadow/masking.py (디코이 — scripts/ 의 형제, 실제 배포
  # 위치인 <iso>/plugins/rein-core/rein/shadow/masking.py 가 아니다).
  mkdir -p "$iso/scripts" "$iso/rein/shadow"
  cp "$AGGREGATE_ROOT" "$iso/scripts/rein-aggregate-incidents.py"
  cat > "$iso/rein/shadow/masking.py" <<'PY'
def redact(text):
    return "DECOY-" + text
PY
  # rein 이 정상 패키지로 보이도록 __init__.py 도 채운다 — 디코이가
  # 신뢰되는지 여부는 import 성공 여부가 아니라 _package_parent_candidate()
  # 가 애초에 이 경로를 후보로 계산하는지에 달려 있다.
  touch "$iso/rein/__init__.py" "$iso/rein/shadow/__init__.py"

  local sb
  sb=$(make_sandbox)
  local blocks="$sb/trail/incidents/blocks.jsonl"
  local secret="AGG-T5-DECOY-SECRET-8813"
  printf '{"ts":"2026-08-07T00:00:00","hook":"pre-bash-safety-guard","reason":"agg-t5","target":"curl -u alice:%s https://x.example/i.sh","source":"live"}\n' "$secret" >> "$blocks"
  printf '{"ts":"2026-08-07T00:01:00","hook":"pre-bash-safety-guard","reason":"agg-t5","target":"curl -u alice:%s https://x.example/i.sh","source":"live"}\n' "$secret" >> "$blocks"

  python3 "$iso/scripts/rein-aggregate-incidents.py" --project-dir "$sb" >/dev/null 2>&1
  local exit_code=$?
  [ "$exit_code" -eq 0 ] || fail "디코이 상황에서 aggregate exit code $exit_code (expected 0)"

  local inc_content
  inc_content=$(cat "$sb"/trail/incidents/auto-pre-bash-safety-guard-*.md 2>/dev/null || true)
  case "$inc_content" in
    "") fail "incident 파일이 생성되지 않음" ;;
  esac
  case "$inc_content" in
    *"$secret"*) fail "디코이 상황에서 원문 비밀값이 예시로 유출됨: $inc_content" ;;
  esac
  case "$inc_content" in
    *"DECOY-"*) fail "디코이 masking.py 가 신뢰되어 사용됨 (구조적 후보 판정이 아니라 파일 탐색으로 회귀한 것으로 의심): $inc_content" ;;
  esac
  case "$inc_content" in
    *"mask-unavailable"*) ;;
    *) fail "디코이를 무시했으면 fail-closed placeholder 여야 하는데 다른 값이 쓰임: $inc_content" ;;
  esac

  rm -rf "$iso" "$sb"
  end
}

# ============================================================
# F6 — 손상 라인 격리 파일은 본문을 기록하지 않는다 (줄 번호 + 내용 해시만)
#
# 파싱에 실패한 행은 정의상 신뢰할 수 있게 해석할 수 없다. 정규식 기반
# 마스킹·경로 규칙은 표기를 보므로 JSON 이스케이프(`pass\u0077ord`,
# `\/Users\/…`) 하나로 비껴가고, 정화를 시도해 통과시키면 그 우회분이
# git 추적 디렉토리 아래 파일에 그대로 남는다(실측 재현). 그래서 본문을
# 아예 기록하지 않는다 — 원문은 blocks.jsonl 의 해당 줄에 그대로 있다.
# ============================================================

run_f6_for() {
  local script_path="$1"
  local label="$2"
  begin "F6 ($label): 손상 라인 격리에 본문 미기록 — 줄 번호 + 원문 해시만"
  local sb
  sb=$(make_sandbox)
  local blocks="$sb/trail/incidents/blocks.jsonl"
  local secret="AGG-F6-BADLINE-SECRET-5150"
  local userdir="/Users/f6alice/private/secret.txt"

  printf '{"ts":"2026-08-07T00:00:00","hook":"pre-bash-safety-guard","reason":"agg-f6","target":"git #aaaaaaaaaaaa","source":"live"}\n' >> "$blocks"
  printf '{"ts":"2026-08-07T00:01:00","hook":"pre-bash-safety-guard","reason":"agg-f6","target":"git #bbbbbbbbbbbb","source":"live"}\n' >> "$blocks"
  # (a) 평문 손상 행
  printf 'THIS IS NOT JSON %s --password %s\n' "$userdir" "$secret" >> "$blocks"
  # (b) JSON 이스케이프로 규칙을 비껴가는 손상 행 (회귀 핀)
  printf '{"pass\\u0077ord":"%s-ESC","target":"\\/Users\\/f6escaped\\/key.txt"\n' "$secret" >> "$blocks"

  python3 "$script_path" --project-dir "$sb" >/dev/null 2>&1

  local bad="$sb/trail/incidents/blocks.jsonl.bad"
  [ -f "$bad" ] || { fail "F6: 손상 라인 격리 파일이 생성되지 않음"; rm -rf "$sb"; end; return; }
  local content
  content=$(cat "$bad")

  # 어떤 형태로도 원문이 남으면 안 된다
  case "$content" in
    *"$secret"*) fail "F6: 격리 파일에 비밀값이 남음: $content" ;;
  esac
  case "$content" in
    *f6alice*) fail "F6: 격리 파일에 평문 손상 행의 사용자명이 남음: $content" ;;
  esac
  case "$content" in
    *f6escaped*) fail "F6: 이스케이프 형태 손상 행의 사용자명이 남음 (규칙 우회): $content" ;;
  esac
  case "$content" in
    *0077*) fail "F6: 이스케이프 형태 키 원문이 남음: $content" ;;
  esac

  # 남아야 하는 것: 줄 번호 + 원문 sha256 앞 12자, 그리고 그것뿐
  local raw_line expected_digest
  raw_line=$(printf 'THIS IS NOT JSON %s --password %s' "$userdir" "$secret")
  expected_digest=$(printf '%s' "$raw_line" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])')
  case "$content" in
    *"# line 3 #$expected_digest"*) ;;
    *) fail "F6: 격리 헤더의 해시가 원문 sha256 앞 12자($expected_digest)와 불일치: $content" ;;
  esac
  # 모든 줄이 헤더 형태여야 한다 (본문 줄 0)
  local nonheader
  nonheader=$(printf '%s\n' "$content" | grep -cvE '^# line [0-9]+ #[0-9a-f]{12}$' || true)
  [ "$nonheader" -eq 0 ] || fail "F6: 격리 파일에 헤더가 아닌 줄이 $nonheader 개 있음: $content"

  rm -rf "$sb"
  end
}

# F7 — 실제 설치 배치(임의 이름의 번들 디렉토리)에서도 엔진을 실제로 소비한다
#
# Phase 7 웨이브 4 코드 리뷰 5회차 High: 패키지 부모를 디렉토리 *이름*
# (`rein-core`/`plugins`)으로 판정하던 판은 실제 설치 경로
# `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/scripts/...`
# 에서 후보를 못 찾아, 설치 사용자 환경의 사건 예시·손상 행 격리가 전부
# placeholder 로 퇴행했다(유출은 fail-closed 로 막히지만 "엔진을 실제로
# 소비한다" 는 계약이 무너진다). 판정 기준을 번들 매니페스트 존재로 바꾼
# 뒤, 버전·마켓플레이스 이름과 무관하게 동작하는지 고정한다.
# ============================================================

test_f7_installed_layout_consumes_engine() {
  begin "F7: 임의 이름의 설치형 번들 배치에서도 마스킹·경로 정규화가 실제로 적용됨"
  local bundle_root bundle
  bundle_root=$(mktemp -d "/tmp/agg-mask-install-XXXXXX")
  # 실제 설치 경로 모양 — `scripts/` 의 부모·조부모가 옛 이름 판정이 요구하던
  # `rein-core`/`plugins` 구조가 아니다 (경로 상위에 `plugins` 라는 이름이
  # 있을 수는 있으나 그 자리가 아니다). 여기서는 그 구조 부재를 재현한다.
  bundle="$bundle_root/cache/somemarket/someplugin/9.9.9"
  mkdir -p "$bundle/scripts" "$bundle/.claude-plugin"
  cp -R "$PROJECT_DIR/plugins/rein-core/rein" "$bundle/rein"
  cp "$PROJECT_DIR/plugins/rein-core/.claude-plugin/plugin.json" "$bundle/.claude-plugin/"
  cp "$AGGREGATE_PLUGIN" "$bundle/scripts/rein-aggregate-incidents.py"

  local sb
  sb=$(make_sandbox)
  local blocks="$sb/trail/incidents/blocks.jsonl"
  local secret="AGG-F7-INSTALL-SECRET-3120"
  printf '{"ts":"2026-08-07T00:00:00","hook":"pre-edit-dod-gate","reason":"agg-f7","target":"/Users/f7carol/proj/a.py --token %s","source":"live"}\n' "$secret" >> "$blocks"
  printf '{"ts":"2026-08-07T00:01:00","hook":"pre-edit-dod-gate","reason":"agg-f7","target":"/Users/f7carol/proj/b.py --token %s","source":"live"}\n' "$secret" >> "$blocks"
  printf 'NOT JSON /Users/f7carol/private/x.txt --password %s\n' "$secret" >> "$blocks"

  python3 "$bundle/scripts/rein-aggregate-incidents.py" --project-dir "$sb" >/dev/null 2>&1

  local inc bad
  inc=$(cat "$sb"/trail/incidents/auto-pre-edit-dod-gate-*.md 2>/dev/null || true)
  bad=$(cat "$sb/trail/incidents/blocks.jsonl.bad" 2>/dev/null || true)

  case "$inc" in
    "") fail "F7: 사건 파일이 생성되지 않음" ;;
  esac
  # 핵심 회귀 핀: placeholder 퇴행이면 엔진을 소비하지 못한 것이다
  case "$inc$bad" in
    *"mask-unavailable"*|*"path-normalize-unavailable"*)
      fail "F7: 설치형 배치에서 엔진 미소비 — placeholder 로 퇴행함 (사건: $inc / 격리: $bad)" ;;
  esac
  case "$inc$bad" in
    *f7carol*) fail "F7: 산출물에 사적 홈 경로(사용자명)가 남음" ;;
  esac
  case "$inc$bad" in
    *"$secret"*) fail "F7: 산출물에 비밀값이 남음" ;;
  esac
  case "$inc" in
    *"<HOME>"*) ;;
    *) fail "F7: 사건 예시에 경로 축약 흔적이 없음: $inc" ;;
  esac
  case "$inc" in
    *REDACTED*) ;;
    *) fail "F7: 사건 예시에 마스킹 흔적이 없음: $inc" ;;
  esac
  # 손상 행 격리는 본문을 담지 않는다(F6) — 줄 번호 + 해시 헤더만 있어야 한다.
  case "$bad" in
    *"# line "*) ;;
    *) fail "F7: 손상 행 격리에 줄 번호 헤더가 없음: $bad" ;;
  esac

  rm -rf "$bundle_root" "$sb"
  end
}

# F8 — 해석 불가 행이 집계를 죽이지 않는다 (디코딩·스키마 실패 포함)
#
# 파일 전체를 텍스트로 열던 판은 잘못된 바이트 1개에 UnicodeDecodeError 로
# 죽었고(격리 파일도 워터마크도 없이 exit 1 → 이후 집계 영구 중단),
# 최상위가 객체가 아니거나 hook 이 문자열이 아닌 행에서는
# AttributeError/TypeError 로 죽었다. 세 가지 모두 같은 격리 경로로 간다.
# ============================================================

test_f8_undecodable_and_schema_broken_lines_quarantined() {
  begin "F8: 디코딩 실패·비객체·스키마 위반 행이 격리되고 집계는 계속된다"
  local sb
  sb=$(make_sandbox)
  local blocks="$sb/trail/incidents/blocks.jsonl"
  printf '{"ts":"2026-08-07T00:00:00","hook":"pre-bash-safety-guard","reason":"agg-f8","target":"git #aaaaaaaaaaaa","source":"live"}\n' >> "$blocks"
  printf '{"ts":"2026-08-07T00:01:00","hook":"pre-bash-safety-guard","reason":"agg-f8","target":"git #bbbbbbbbbbbb","source":"live"}\n' >> "$blocks"
  printf '\xff\xfe not utf8\n' >> "$blocks"            # (a) 디코딩 실패
  printf '[]\n' >> "$blocks"                            # (b) 최상위가 객체 아님
  printf '{"hook":["list"],"reason":"x","target":"y","source":"live"}\n' >> "$blocks"  # (c) 스키마 위반

  python3 "$AGGREGATE_PLUGIN" --project-dir "$sb" >/dev/null 2>&1
  local rc=$?
  [ "$rc" -eq 0 ] || fail "F8: 손상 행이 집계를 중단시킴 (exit $rc)"

  # 정상 행으로 사건 파일이 생겨야 한다 (집계가 계속됐다는 증거)
  local n
  n=$(ls "$sb"/trail/incidents/auto-pre-bash-safety-guard-*.md 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -ge 1 ] || fail "F8: 정상 행 집계가 되지 않음 — 사건 파일 없음"

  # 손상 3행이 모두 격리돼야 한다
  local bad="$sb/trail/incidents/blocks.jsonl.bad"
  [ -f "$bad" ] || { fail "F8: 격리 파일이 생성되지 않음"; rm -rf "$sb"; end; return; }
  local hdrs
  hdrs=$(grep -cE '^# line [0-9]+ #[0-9a-f]{12}$' "$bad")
  [ "$hdrs" -eq 3 ] || fail "F8: 격리 헤더가 3개가 아님 ($hdrs): $(cat "$bad")"

  # 워터마크가 전진해야 재실행 시 같은 행을 다시 읽지 않는다
  local wm
  wm=$(cat "$sb/trail/incidents/.last-processed-line" 2>/dev/null || echo "")
  [ "$wm" = "5" ] || fail "F8: 워터마크가 전진하지 않음 (got '$wm', expected 5)"

  rm -rf "$sb"
  end
}

# F9 — hook 이름이 사건 파일 경로를 벗어나지 못한다
#
# hook 값은 `auto-<hook>-<hash>.md` 로 조립된다. 검증이 없던 판에서는
# `hook="x/../../escaped"` 가 incidents 디렉토리 **밖**에 파일을 만들었다.
# ============================================================

test_f9_hook_name_cannot_escape_incidents_dir() {
  begin "F9: 경로 탈출 문자를 담은 hook 이름은 집계에서 제외되고 밖에 파일을 만들지 않는다"
  local sb
  sb=$(make_sandbox)
  mkdir -p "$sb/trail/incidents/auto-x"
  local blocks="$sb/trail/incidents/blocks.jsonl"
  printf '{"ts":"2026-08-07T00:00:00","hook":"x/../../escaped","reason":"trav","target":"git #cccccccccccc","source":"live"}\n' >> "$blocks"
  printf '{"ts":"2026-08-07T00:01:00","hook":"x/../../escaped","reason":"trav","target":"git #dddddddddddd","source":"live"}\n' >> "$blocks"

  python3 "$AGGREGATE_PLUGIN" --project-dir "$sb" >/dev/null 2>&1

  local outside
  outside=$(find "$sb/trail" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
  [ "$outside" -eq 0 ] || fail "F9: incidents 디렉토리 밖에 파일이 $outside 개 생성됨"

  # 절대경로 형태도 같이 막히는지
  local sb2
  sb2=$(make_sandbox)
  printf '{"ts":"2026-08-07T00:00:00","hook":"/tmp/abs-escape","reason":"trav2","target":"git #eeeeeeeeeeee","source":"live"}\n' >> "$sb2/trail/incidents/blocks.jsonl"
  printf '{"ts":"2026-08-07T00:01:00","hook":"/tmp/abs-escape","reason":"trav2","target":"git #ffffffffffff","source":"live"}\n' >> "$sb2/trail/incidents/blocks.jsonl"
  python3 "$AGGREGATE_PLUGIN" --project-dir "$sb2" >/dev/null 2>&1
  [ ! -f "/tmp/abs-escape-"*.md ] 2>/dev/null || fail "F9: 절대경로 hook 이 밖에 파일을 만듦"

  rm -rf "$sb" "$sb2"
  end
}

# F10 — 깊은 중첩 JSON·요약 경로도 해석 불가 행에 죽지 않는다
#
# 집계 루프는 고쳤어도 json.loads 는 깊은 중첩에서 RecursionError 를 내고,
# advisory-summary 요약 경로는 별도 함수라 같은 결함이 남아 있었다(손상
# 바이트 1개에 Stop 훅의 summary 가 통째로 소실). 공용 안전 파서로 세 소비자를
# 한 규칙에 묶은 뒤 두 경로를 함께 고정한다.
# ============================================================

test_f10_deep_nest_and_summary_survive_bad_input() {
  begin "F10: 깊은 중첩 JSON → 집계 생존, 손상 바이트 → 요약 생존"
  local sb
  sb=$(make_sandbox)
  local blocks="$sb/trail/incidents/blocks.jsonl"
  printf '{"ts":"2026-08-07T00:00:00","hook":"pre-bash-safety-guard","reason":"agg-f10","target":"git #aaaaaaaaaaaa","source":"live"}\n' >> "$blocks"
  printf '{"ts":"2026-08-07T00:01:00","hook":"pre-bash-safety-guard","reason":"agg-f10","target":"git #bbbbbbbbbbbb","source":"live"}\n' >> "$blocks"
  python3 -c 'print("["*2000 + "]"*2000)' >> "$blocks"   # 깊은 중첩 → RecursionError 유발
  printf '\xff\xfe bad\n' >> "$blocks"                  # 손상 바이트

  # 집계가 생존하고 정상 행으로 사건 파일을 만든다
  python3 "$AGGREGATE_PLUGIN" --project-dir "$sb" >/dev/null 2>&1
  local rc=$?
  [ "$rc" -eq 0 ] || fail "F10: 깊은 중첩 입력이 집계를 중단시킴 (exit $rc)"
  local n
  n=$(ls "$sb"/trail/incidents/auto-pre-bash-safety-guard-*.md 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -ge 1 ] || fail "F10: 집계 생존했으나 사건 파일 없음"

  # 요약 경로도 손상 입력에서 죽지 않고 정상 행을 집계한다
  local sb2
  sb2=$(make_sandbox)
  local b2="$sb2/trail/incidents/blocks.jsonl"
  printf '{"ts":"2026-08-07T00:00:00","hook":"pre-bash-safety-guard","reason":"f10sum","target":"x","source":"live"}\n' >> "$b2"
  printf '\xff\xfe bad\n' >> "$b2"
  printf '{"ts":"2026-08-07T00:02:00","hook":"pre-bash-safety-guard","reason":"f10sum","target":"y","source":"live"}\n' >> "$b2"
  local out
  out=$(REIN_BLOCKS_JSONL="$b2" python3 "$AGGREGATE_PLUGIN" --project-dir "$sb2" advisory-summary 2>/dev/null)
  local src=$?
  [ "$src" -eq 0 ] || fail "F10: advisory-summary 가 손상 바이트에 exit $src"
  case "$out" in
    *'"count": 2'*) ;;
    *) fail "F10: 요약이 정상 두 행을 집계하지 못함: $out" ;;
  esac

  rm -rf "$sb" "$sb2"
  end
}

# F11 — 필드 타입이 어긋난 정상 JSON 도 요약/카운터를 죽이지 않는다
#
# 공용 파서가 최상위 dict 는 보장해도 필드 타입까지는 아니다: reason 이
# list 면 counts 키(해시 불가)에서, ts 가 list 면 since-ts 비교에서 TypeError
# 로 죽어 뒤의 정상 행까지 사라졌다. 필드 isinstance 가드로 그 행만 skip.
# ============================================================

test_f11_bad_field_types_skip_not_crash() {
  begin "F11: reason/ts 가 배열인 행은 skip 되고 정상 행은 요약된다"
  # (A) reason 이 list
  local sb
  sb=$(make_sandbox)
  local b="$sb/trail/incidents/blocks.jsonl"
  printf '{"ts":"2026-08-07T00:00:00","reason":["bad"],"source":"live"}\n' >> "$b"
  printf '{"ts":"2026-08-07T00:02:00","hook":"h","reason":"정상F11","target":"x","source":"live"}\n' >> "$b"
  local out rc
  out=$(REIN_BLOCKS_JSONL="$b" python3 "$AGGREGATE_PLUGIN" --project-dir "$sb" advisory-summary 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "F11(A): reason=list 에서 exit $rc"
  case "$out" in *"정상F11"*) ;; *) fail "F11(A): 정상 행이 요약되지 않음: $out" ;; esac

  # (B) ts 가 list + since-ts
  local sb2
  sb2=$(make_sandbox)
  local b2="$sb2/trail/incidents/blocks.jsonl"
  printf '{"ts":[],"reason":"bad"}\n' >> "$b2"
  printf '{"ts":"2026-08-07T00:02:00","hook":"h","reason":"정상F11b","target":"x","source":"live"}\n' >> "$b2"
  out=$(REIN_BLOCKS_JSONL="$b2" python3 "$AGGREGATE_PLUGIN" --project-dir "$sb2" advisory-summary --since-ts "2026-08-07T00:00:00" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "F11(B): ts=list + since-ts 에서 exit $rc"
  case "$out" in *"정상F11b"*) ;; *) fail "F11(B): 정상 행이 요약되지 않음: $out" ;; esac

  rm -rf "$sb" "$sb2"
  end
}

# F12 — UTF-8 직렬화 불가 문자열(surrogate)도 집계/요약을 죽이지 않는다
#
# 유효 JSON 도 짝 없는 surrogate(`"\ud800"`)를 담을 수 있고, isinstance(str)
# 만 보면 통과하지만 sha 해시·incident 쓰기의 .encode("utf-8") 에서
# UnicodeEncodeError 로 죽는다. reason/target/hook 을 utf8-safe 로 격상.
# ============================================================

test_f12_surrogate_string_quarantined_not_crash() {
  begin "F12: surrogate reason/target 행은 격리, 정상 행은 집계·요약"
  local sb
  sb=$(make_sandbox)
  python3 - "$sb/trail/incidents/blocks.jsonl" <<'PYW'
import json, sys
rows=[
  {"ts":"2026-08-07T00:00:00","hook":"h","reason":"\ud800","target":"x","source":"live"},
  {"ts":"2026-08-07T00:01:00","hook":"h","reason":"r","target":"\ud800","source":"live"},
  {"ts":"2026-08-07T00:02:00","hook":"pre-bash-safety-guard","reason":"정상F12","target":"y","source":"live"},
  {"ts":"2026-08-07T00:03:00","hook":"pre-bash-safety-guard","reason":"정상F12","target":"z","source":"live"},
]
open(sys.argv[1],"w").write("\n".join(json.dumps(r) for r in rows)+"\n")
PYW
  python3 "$AGGREGATE_PLUGIN" --project-dir "$sb" >/dev/null 2>&1
  local rc=$?
  [ "$rc" -eq 0 ] || fail "F12: surrogate 가 집계를 중단시킴 (exit $rc)"
  local n
  n=$(ls "$sb"/trail/incidents/auto-pre-bash-safety-guard-*.md 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -ge 1 ] || fail "F12: 정상 행 집계 실패 — 사건 파일 없음"
  # surrogate 두 행(1,2)이 각각의 정확한 해시 헤더로 격리됐는지 — 헤더 수만
  # 보면 line 1 이 두 번 기록되고 line 2 가 누락되는 회귀도 통과한다. 각 행의
  # 원문 바이트 sha256 앞 12자를 직접 계산해 `# line N #<hash>` 를 정확히 대조.
  local bad="$sb/trail/incidents/blocks.jsonl.bad"
  local d1 d2
  d1=$(sed -n '1p' "$sb/trail/incidents/blocks.jsonl" | tr -d '\n' | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])')
  d2=$(sed -n '2p' "$sb/trail/incidents/blocks.jsonl" | tr -d '\n' | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])')
  grep -qxF "# line 1 #$d1" "$bad" || fail "F12: line 1 격리 헤더 불일치 (기대 #$d1): $(cat "$bad")"
  grep -qxF "# line 2 #$d2" "$bad" || fail "F12: line 2 격리 헤더 불일치 (기대 #$d2): $(cat "$bad")"
  local hdrs
  hdrs=$(grep -cE '^# line [0-9]+ #[0-9a-f]{12}$' "$bad" 2>/dev/null || echo 0)
  [ "$hdrs" -eq 2 ] || fail "F12: 격리 헤더가 정확히 2줄이 아님 ($hdrs)"
  local wm
  wm=$(cat "$sb/trail/incidents/.last-processed-line" 2>/dev/null || echo "")
  [ "$wm" = "4" ] || fail "F12: 워터마크가 4로 전진하지 않음 (got '$wm')"
  local out
  out=$(REIN_BLOCKS_JSONL="$sb/trail/incidents/blocks.jsonl" python3 "$AGGREGATE_PLUGIN" --project-dir "$sb" advisory-summary 2>/dev/null)
  local sc=$?
  [ "$sc" -eq 0 ] || fail "F12: 요약이 surrogate 에 exit $sc"
  case "$out" in *"정상F12"*) ;; *) fail "F12: 요약에 정상 행 없음: $out" ;; esac
  rm -rf "$sb"
  end
}

# F13 — 비문자열 source 는 세 소비자가 동일하게 취급한다 (test 아님 → live)
#
# 요약에만 source 가드를 두면 aggregate/live_count(비문자열=live 카운트)와
# 의미가 갈린다. source 는 `== "test"` 비교뿐이라 별도 가드 없이 통일.
# ============================================================

test_f13_nonstring_source_consistent() {
  begin "F13: source=[] 를 집계와 요약이 동일하게(live) 취급"
  local sb
  sb=$(make_sandbox)
  local b="$sb/trail/incidents/blocks.jsonl"
  printf '{"ts":"2026-08-07T00:00:00","hook":"pre-bash-safety-guard","reason":"srcF13","target":"x","source":[]}\n' >> "$b"
  printf '{"ts":"2026-08-07T00:01:00","hook":"pre-bash-safety-guard","reason":"srcF13","target":"y","source":[]}\n' >> "$b"
  # 집계: live 로 취급하면 사건 파일이 생긴다
  python3 "$AGGREGATE_PLUGIN" --project-dir "$sb" >/dev/null 2>&1
  local n
  n=$(ls "$sb"/trail/incidents/auto-pre-bash-safety-guard-*.md 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -ge 1 ] || fail "F13: 집계가 비문자열 source 를 live 로 세지 않음"
  # 요약: 같은 두 행을 count 2 로 집계
  local out
  out=$(REIN_BLOCKS_JSONL="$b" python3 "$AGGREGATE_PLUGIN" --project-dir "$sb" advisory-summary 2>/dev/null)
  case "$out" in *'"count": 2'*) ;; *) fail "F13: 요약이 비문자열 source 를 집계와 다르게 취급: $out" ;; esac
  # live_count(세 번째 소비자)도 비문자열 source 를 live 로 센다 — 이 소비자만
  # skip 으로 회귀하면 반복 경고 카운트가 갈린다.
  local lb="$PROJECT_DIR/plugins/rein-core/hooks/lib/rein-log-block.py"
  local lc
  lc=$(python3 -c "
import importlib.util
sp=importlib.util.spec_from_file_location('lb','$lb')
m=importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
print(m.live_count('$b','pre-bash-safety-guard','srcF13'))
")
  [ "$lc" = "2" ] || fail "F13: live_count 가 비문자열 source 를 live 로 세지 않음 (got '$lc', expected 2)"
  rm -rf "$sb"
  end
}

# F14 — 손상 snapshot 경고도 사용자명/예외 원문을 노출하지 않는다
# F15 — hook 이름 검증은 끝 개행을 허용하지 않는다 (`$`+match 함정)
# ============================================================

test_f14_snapshot_warning_no_leak() {
  begin "F14: 손상·읽기불가·깊은중첩 snapshot 경고가 traceback/사용자명 미노출"
  # 각 손상 유형마다 **별도 sandbox** — 한 sandbox 에서 순차 실행하면 첫 실행이
  # 워터마크를 끝까지 밀어 다음 실행이 조기 반환(snapshot 미독)되는 false-green
  # 이 된다(직전 회차 실측). 임시물은 /tmp (홈 경로 정규화는 아래 직접 assert).
  local me
  me=$(whoami)

  _f14_one() {
    local kind="$1"; local snap_writer="$2"
    local sb
    sb=$(mktemp -d "/tmp/agg-f14-XXXXXX")
    mkdir -p "$sb/trail/incidents" "$sb/.rein"
    printf '{"mode":"plugin","scope":"project","version":"1.0.0"}\n' > "$sb/.rein/project.json"
    printf '{"ts":"2026-08-07T00:00:00","hook":"pre-bash-safety-guard","reason":"f14","target":"git #a","source":"live"}\n' >> "$sb/trail/incidents/blocks.jsonl"
    eval "$snap_writer \"$sb/trail/incidents/.last-aggregate-state.json\""
    local err
    err=$(python3 "$AGGREGATE_PLUGIN" --project-dir "$sb" 2>&1 >/dev/null)
    local rc=$?
    [ "$rc" -eq 0 ] || fail "F14($kind): aggregate exit $rc (손상 snapshot 이 집계를 중단)"
    case "$err" in *Traceback*|*RecursionError*) fail "F14($kind): traceback 유출: $err" ;; esac
    case "$err" in *"$me"*) fail "F14($kind): 사용자명 유출: $err" ;; esac
    # snapshot 경고가 실제로 방출됐는지 (조기 반환 false-green 방지)
    case "$err" in *snapshot*) ;; *) fail "F14($kind): snapshot 경고가 방출되지 않음(미독 의심): $err" ;; esac
    rm -rf "$sb"
  }
  _f14_one "non-dict"    "printf '[]' >"
  _f14_one "unreadable"  "_f14_write_unreadable"
  _f14_one "deep-nest"   "_f14_write_deepnest"

  # 홈 경로 정규화는 sandbox 위치와 무관하게 직접 assert — snapshot 경고가
  # _display_path 를 거치는지 (사용자명을 <HOME> 로 축약) 확인.
  local dp
  dp=$(python3 -c "
import importlib.util
s=importlib.util.spec_from_file_location('agg','$AGGREGATE_PLUGIN')
m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m._display_path('/Users/f14alice/proj/.last-aggregate-state.json'))
")
  case "$dp" in *f14alice*) fail "F14: _display_path 가 사용자명을 노출: $dp" ;; esac
  case "$dp" in *".last-aggregate-state.json"*) ;; *) fail "F14: _display_path 결과가 파일명을 잃음: $dp" ;; esac

  unset -f _f14_one 2>/dev/null || true
  end
}

# 손상 snapshot writer 헬퍼 (F14 에서 eval 로 호출)
_f14_write_unreadable() { printf '{"watermark":0}' > "$1"; chmod 000 "$1"; }
_f14_write_deepnest()   { python3 -c 'print("["*2000 + "]"*2000, end="")' > "$1"; }

test_f15_hook_name_rejects_trailing_newline() {
  begin "F15: hook 이름 검증이 끝 개행을 거부"
  local r
  r=$(python3 -c "
import importlib.util
s=importlib.util.spec_from_file_location('agg','$AGGREGATE_PLUGIN')
m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
ok = bool(m._SAFE_HOOK_NAME.fullmatch('safe-hook'))
nl = bool(m._SAFE_HOOK_NAME.fullmatch('safe-hook' + chr(10)))
print('ok' if (ok and not nl) else 'bad')
")
  [ "$r" = "ok" ] || fail "F15: hook 이름 검증이 끝 개행을 허용함"
  end
}

# ============================================================
# main
# ============================================================

run_t1_for "$AGGREGATE_PLUGIN" "plugin"
run_t1_for "$AGGREGATE_ROOT" "root-fallback"
run_t2_for "$AGGREGATE_PLUGIN" "plugin"
run_t2_for "$AGGREGATE_ROOT" "root-fallback"
run_f2_for "$AGGREGATE_PLUGIN" "plugin"
run_f2_for "$AGGREGATE_ROOT" "root-fallback"
test_import_failure_fails_closed
test_hijacked_sys_modules_is_ignored_real_masking_runs
test_r5a_symbol_swap_after_real_import_defeated
test_r5b_fake_module_self_reported_file_defeated
test_r1c_decoy_masking_near_root_copy_ignored
run_f6_for "$AGGREGATE_PLUGIN" "plugin"
run_f6_for "$AGGREGATE_ROOT" "root-fallback"
test_f7_installed_layout_consumes_engine
test_f8_undecodable_and_schema_broken_lines_quarantined
test_f9_hook_name_cannot_escape_incidents_dir
test_f10_deep_nest_and_summary_survive_bad_input
test_f11_bad_field_types_skip_not_crash
test_f12_surrogate_string_quarantined_not_crash
test_f13_nonstring_source_consistent
test_f14_snapshot_warning_no_leak
test_f15_hook_name_rejects_trailing_newline

echo ""
echo "================================"
echo "Tests run: $TEST_COUNT"
echo "Passed:    $((TEST_COUNT - FAIL_COUNT))"
echo "Failed:    $FAIL_COUNT"
echo "================================"
[ "$FAIL_COUNT" -eq 0 ]
