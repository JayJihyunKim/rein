#!/usr/bin/env bash
# tests/scripts/test-affected-tests.sh
# spec docs/specs/2026-10-08-affected-tests-and-precheck.md §3.6.1 (1) — AT1~AT43
# Scope IDs: ATP-SEL-CLI ATP-SEL-ORDER ATP-SEL-SCRIPT ATP-SEL-DYNAMIC ATP-SEL-DISCOVERY ATP-SEL-TOOLS
#            ATP-SEL-IMPORT ATP-SEL-SHARED ATP-SEL-FULL ATP-SEL-BUDGET ATP-INSTALL ATP-INSTALL-GUARD ATP-STATE
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL="$(cd "$SCRIPT_DIR/../.." && pwd)"
SEL="$REAL/plugins/rein-core/scripts/rein-affected-tests.py"
PY="$(command -v python3)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rein-affected-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

# 하니스 부산물은 전부 무시 목록에 둔다 — 미추적으로 남으면 changed 에 들어가 결과를 바꾼다
IGNORE_LINES='.fakebin/
.argv.log
.stdin.log
.ran
.ran-base
.target.txt
.cwd.txt
.child.pid
.out.json
.err.txt
.snap
.outside.sh
.elsewhere/
.venv/
node_modules/
.testmondata
.rein/state/'

new_repo() {   # $1=케이스 이름 → 전역 R. 빈 저장소 + 무시 목록 커밋
  R="$WORK/$1"; mkdir -p "$R/.fakebin"
  ( cd "$R" && git init -q && git config user.email t@e.com && git config user.name t \
    && printf '%s\n' "$IGNORE_LINES" > .gitignore && git add .gitignore && git commit -q -m init )
  printf '#!/bin/sh\n[ "$1" = "-I" ] && exit 1\nexec "%s" "$@"\n' "$PY" > "$R/.fakebin/python3"
  chmod +x "$R/.fakebin/python3"
}
commit_all() { ( cd "$R" && git add -A && git commit -q -m "${1:-fixture}" ); }
mk_fake() {    # $1=이름 $2=종료 코드 [$3=sleep 초] — argv 를 .argv.log 에 한 줄로 기록하는 가짜 실행 파일
  printf '#!/bin/sh\necho "$*" >> "%s/.argv.log"\n%s\nexit %s\n' "$R" "${3:+sleep $3}" "$2" > "$R/.fakebin/$1"
  chmod +x "$R/.fakebin/$1"
}
sel() {        # 선택기 실행 → OUT(stdout) RC. 기본 --no-install. 설치 허용 케이스는 SEL_INSTALL=1
  local extra=--no-install
  [ "${SEL_INSTALL:-0}" = 1 ] && extra=
  OUT=$(cd "$R" && env -u VIRTUAL_ENV PATH="$R/.fakebin:$PATH" ${SEL_ENV:-} \
        "$PY" "$SEL" --root "$R" --format json $extra "$@" 2>"$R/.err.txt"); RC=$?
}
jq_py() { printf '%s' "$OUT" | "$PY" -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }
eq()  { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1 (got '$2' want '$3')"; fi; }
has_reason() {  # $1=설명 $2=사유 접두(부분 문자열)
  if [ "$(jq_py "any('$2' in r for r in d['reasons'])")" = True ]; then _pass "$1"; else _fail "$1 (reasons 에 '$2' 없음: $(jq_py "d['reasons']"))"; fi
}

# ---- 추가 헬퍼 -------------------------------------------------------------
absent()  { if [ ! -e "$2" ]; then _pass "$1"; else _fail "$1 ($2 가 존재함)"; fi; }
present() { if [ -e "$2" ]; then _pass "$1"; else _fail "$1 ($2 가 없음)"; fi; }
w()   { mkdir -p "$R/$(dirname "$1")"; printf '%s\n' "$2" > "$R/$1"; }     # 파일 쓰기(덮어쓰기)
app() { printf '%s\n' "$2" >> "$R/$1"; }                                    # 한 줄 덧붙이기
base_sha() { git -C "$R" rev-parse HEAD; }
now() { date +%s; }
no_ws() { tr -d ' '; }
expect_full() {   # $1=설명 $2=사유 부분 문자열 — rc 0 + full_run_required true + 사유
  eq "$1 rc" "$RC" 0
  eq "$1 full_run_required" "$(jq_py "d['full_run_required']")" True
  has_reason "$1 사유" "$2"
}
expect_method() { # $1=설명 $2=method
  eq "$1 rc" "$RC" 0
  eq "$1 method" "$(jq_py "d['method']")" "$2"
}
st() {            # 상태 파일 필드 식(d 로 참조) → 값
  "$PY" -c "import json; d=json.load(open('$R/.rein/state/test-tools.json')); print($1)" 2>/dev/null
}
json_body() {     # $1=테스트 경로 $2=command → 프로젝트 스크립트 본문(유효 JSON 을 낸다)
  printf "echo '{\"tests\":[\"%s\"],\"command\":\"%s\"}'" "$1" "$2"
}
mk_script() { w .rein/affected-tests.sh "$1"; }   # 커밋은 호출자가
snap_dir() { ( cd "$1" && { find . | sort; find . -type f -exec cat {} + 2>/dev/null; } ); }

# ---- 파이썬 기본 픽스처 (설계 §3.6.1 (1)) ----------------------------------
# pytest.ini 는 [pytest] 한 줄뿐이다 — python_files·testpaths 를 넣으면 D22 로 full 이 된다.
# 전체 테스트 파일 8개: test_core·test_helper·test_util·test_a~test_e
mk_py_fixture() {  # $1=케이스 이름
  new_repo "$1"
  w pytest.ini '[pytest]'
  w src/pkg/__init__.py ''
  w src/pkg/core.py 'def x(): return 1'
  w src/pkg/util.py 'def u(): return 2'
  w src/pkg/helper.py 'from pkg import core'
  w src/pkg/orphan_base.py 'def o(): return 3'
  w tests/test_core.py 'from pkg.core import x'
  w tests/test_helper.py 'import pkg.helper'
  w tests/test_util.py 'from pkg import util'
  local l
  for l in a b c d e; do w "tests/test_$l.py" "def test_$l(): pass"; done
  commit_all
}
edit_util() { app src/pkg/util.py '# edit'; }

# testmon 구성(AT26 첫 구성): poetry.lock 에 testmon + 가짜 poetry + .testmondata
mk_testmon_fixture() {  # $1=케이스 이름 [$2=no-data → .testmondata 만들지 않음]
  mk_py_fixture "$1"
  w poetry.lock $'[[package]]\nname = "pytest-testmon"'
  w pyproject.toml $'[project]\nname = "x"'
  mk_fake poetry 0
  commit_all "testmon"
  [ "${2:-}" = no-data ] || : > "$R/.testmondata"
}

# ---- JS 픽스처 ---------------------------------------------------------------
# 무관한 패딩 테스트 3개(p1~p3)를 둔다 — 동적 import 흔적 케이스가 절반 규칙(분모)에 걸리지 않게 하는 분모다.
JEST_PKG='{"devDependencies":{"jest":"^29"},"scripts":{"test":"jest"}}'
VITEST_PKG='{"devDependencies":{"vitest":"^1"},"scripts":{"test":"vitest"}}'
mk_js_base() {  # $1=이름 $2=package.json 내용 $3..=만들 node_modules/.bin 실행 파일 (호출되면 .ran 생성) — 커밋은 호출자가
  local name="$1" pk="$2" b p
  shift 2
  new_repo "$name"
  w package.json "$pk"
  w src/a.js 'module.exports = 1;'
  for p in 1 2 3; do w "src/__tests__/p$p.test.js" "test('p$p', () => {});"; done
  for b in "$@"; do
    mkdir -p "$R/node_modules/.bin"
    printf '#!/bin/sh\ntouch "%s/.ran"\n' "$R" > "$R/node_modules/.bin/$b"
    chmod +x "$R/node_modules/.bin/$b"
  done
}
js_atest() { w src/__tests__/a.test.js $'const a = require(\'./../a\');\ntest(\'a\', () => {});'; }
mk_jest_fixture()   { mk_js_base "$1" "$JEST_PKG" jest; js_atest; commit_all; }       # AT23 구성
mk_vitest_fixture() { mk_js_base "$1" "$VITEST_PKG" vitest; js_atest; commit_all; }   # AT24 첫 구성
DYN_JS=$'const n = "x";\nimport(`./${n}`);'      # 인터폴레이션 템플릿 → 동적 import 흔적

# ============================================================================
echo "== AT1: --help =="
OUT=$("$PY" "$SEL" --help 2>&1); RC=$?
eq "AT1 --help rc" "$RC" 0
for f in --base --format --no-install --untracked-scope --untracked-snapshot --external-inputs-changed --root; do
  case "$OUT" in *"$f"*) _pass "AT1 help 에 $f";; *) _fail "AT1 help 에 $f 없음";; esac
done

# ============================================================================
echo "== AT2: import 1단계 =="
mk_py_fixture AT2; edit_util; sel
expect_method "AT2" import-search
eq "AT2 tests" "$(jq_py "d['tests']")" "['tests/test_util.py']"
eq "AT2 full_run_required false" "$(jq_py "d['full_run_required']")" False
eq "AT2 command" "$(jq_py "d['command']")" "python3 -m pytest tests/test_util.py"

echo "== AT3: import 2단계 =="
mk_py_fixture AT3; app src/pkg/core.py '# edit'; sel
eq "AT3 tests" "$(jq_py "d['tests']")" "['tests/test_core.py', 'tests/test_helper.py']"

echo "== AT4: 상대 import =="
mk_py_fixture AT4; w src/pkg/helper.py 'from . import core'; commit_all "relative"
app src/pkg/core.py '# edit'; sel
eq "AT4 test_helper 포함" "$(jq_py "'tests/test_helper.py' in d['tests']")" True
eq "AT4 test_core 포함" "$(jq_py "'tests/test_core.py' in d['tests']")" True

echo "== AT5: 테스트 파일만 수정 =="
mk_py_fixture AT5; app tests/test_core.py '# edit'; sel
eq "AT5 tests" "$(jq_py "d['tests']")" "['tests/test_core.py']"

echo "== AT6: 공용 모듈 =="
mk_py_fixture AT6; w tests/test_a.py 'from pkg import util'; commit_all "shared"
edit_util; sel
expect_full "AT6" '공용 모듈 변경(import-search 는 완화 대상 아님)'

echo "== AT7: 절반 초과 =="
# base.py 를 중계 모듈 r1~r5 가 import 하고, 각 중계 모듈을 기존 test_a~test_e 가 하나씩 import (직접 import 테스트 0개).
# 전체 테스트 파일 8 유지: 대상 5 > 0.5 × 8
mk_py_fixture AT7
w src/pkg/base.py 'def b(): return 0'
i=0
for l in a b c d e; do i=$((i + 1)); w "src/pkg/r$i.py" 'from pkg import base'; w "tests/test_$l.py" "import pkg.r$i"; done
commit_all "relays"
app src/pkg/base.py '# edit'; sel
expect_full "AT7" '절반 초과'

echo "== AT8: 매핑 불가 =="
mk_py_fixture AT8; app src/pkg/orphan_base.py '# edit'; sel
expect_full "AT8" '테스트에 매핑되지 않는 소스'

# ============================================================================
echo "== AT9: 동적 import 흔적 집합 (D20) =="
# (a) import-search — test_dyn.py 는 importlib.import_module(name) 만 쓰고 pkg.util 을 정적으로 import 하지 않는다.
#     전체 테스트 9: 대상 2 ≤ 0.5 × 9
mk_py_fixture AT9a
w tests/test_dyn.py $'import importlib\ndef test_dyn(name="x"):\n    importlib.import_module(name)'
commit_all "dyn test"; edit_util; sel
expect_method "AT9(a)" import-search
eq "AT9(a) tests" "$(jq_py "d['tests']")" "['tests/test_dyn.py', 'tests/test_util.py']"

# (b) 소스 흔적 — loader.py 에 __import__(x), test_loader.py 가 import pkg.loader. 테스트 9: 대상 2 ≤ 4.5
mk_py_fixture AT9b
w src/pkg/loader.py $'def load(x):\n    return __import__(x)'
w tests/test_loader.py 'import pkg.loader'
commit_all "loader"; edit_util; sel
expect_method "AT9(b)" import-search
eq "AT9(b) test_loader 포함" "$(jq_py "'tests/test_loader.py' in d['tests']")" True
eq "AT9(b) test_util 포함" "$(jq_py "'tests/test_util.py' in d['tests']")" True

# (c) jest — AT23 구성 + b.test.js(``require(`./${n}`)``). 패딩 포함 테스트 5: 대상 2 ≤ 0.5 × 5
mk_jest_fixture AT9c
w src/__tests__/b.test.js 'const n = "x"; const m = require(`./${n}`);'
commit_all "b test"; app src/a.js '// edit'; sel
expect_method "AT9(c)" jest
eq "AT9(c) tests" "$(jq_py "d['tests']")" "['src/__tests__/b.test.js']"
eq "AT9(c) command" "$(jq_py "d['command']")" "node_modules/.bin/jest --findRelatedTests src/a.js && node_modules/.bin/jest --runTestsByPath src/__tests__/b.test.js"

# (d) vitest — AT24 첫 구성 + 같은 b.test.js
mk_vitest_fixture AT9d
w src/__tests__/b.test.js 'const n = "x"; const m = require(`./${n}`);'
commit_all "b test"; app src/a.js '// edit'; sel
expect_method "AT9(d)" vitest
eq "AT9(d) tests" "$(jq_py "d['tests']")" "['src/__tests__/b.test.js']"
eq "AT9(d) command" "$(jq_py "d['command']")" "node_modules/.bin/vitest related --run src/a.js && node_modules/.bin/vitest run src/__tests__/b.test.js"

# (e) 흔적 과다 — 파이썬: test_a~test_e 에 __import__(n). 대상 = test_util + 5 = 6 > 0.5 × 8
mk_py_fixture AT9e
for l in a b c d e; do w "tests/test_$l.py" $'def f(n):\n    __import__(n)'; done
commit_all "dyn tests"; edit_util; sel
expect_full "AT9(e) python" '동적 import 흔적으로 대상 과다'
# (e) 흔적 과다 — jest: 패딩 p1~p3 에 import(`./${n}`). 대상 = a.test + p1~p3 = 4 > 0.5 × 4
mk_jest_fixture AT9e2
for p in 1 2 3; do w "src/__tests__/p$p.test.js" "$DYN_JS"; done
commit_all "dyn pads"; app src/a.js '// edit'; sel
expect_full "AT9(e) jest" '동적 import 흔적으로 대상 과다'

# (f) testmon 제외 — AT26 첫 구성에서 test_util.py 에 importlib.import_module(n)
mk_testmon_fixture AT9f
w tests/test_util.py $'import importlib\nfrom pkg import util\ndef f(n):\n    importlib.import_module(n)'
commit_all "dyn in test_util"; edit_util; sel
expect_method "AT9(f)" testmon
eq "AT9(f) command" "$(jq_py "d['command']")" "poetry run pytest --testmon"
eq "AT9(f) tests" "$(jq_py "d['tests']")" "[]"

# (g) 흔적이 있어도 유효한 프로젝트 스크립트가 결과를 내면 project-script
mk_py_fixture AT9g
w tests/test_dyn.py $'import importlib\ndef test_dyn(name="x"):\n    importlib.import_module(name)'
mk_script "$(json_body tests/test_a.py 'echo ok')"
commit_all "dyn + script"; edit_util; sel
expect_method "AT9(g)" project-script
eq "AT9(g) tests 는 스크립트 값 그대로" "$(jq_py "d['tests']")" "['tests/test_a.py']"

# (h) 흔적 스캔 미완성 — REIN_AFFECTED_TESTS_MAX_SCAN=3 인 jest 구성 (JS 파일 5개 > 3)
mk_jest_fixture AT9h; app src/a.js '// edit'
SEL_ENV=REIN_AFFECTED_TESTS_MAX_SCAN=3 sel
expect_full "AT9(h)" '검색 대상 파일 과다'

# (i) 간접 importer — test_via → via.py → loader.py(__import__(x)). 테스트 9: 대상 2 ≤ 4.5
mk_py_fixture AT9i
w src/pkg/loader.py $'def load(x):\n    return __import__(x)'
w src/pkg/via.py 'import pkg.loader'
w tests/test_via.py 'import pkg.via'
commit_all "via"; edit_util; sel
expect_method "AT9(i)" import-search
eq "AT9(i) test_via 포함" "$(jq_py "'tests/test_via.py' in d['tests']")" True

# (j) 리터럴 판정 — 파이썬. pkg.util 을 직접 import 하는 테스트가 test_lit.py 하나뿐이도록
#     기준 커밋에서 test_util.py 의 `from pkg import util` 을 지운다(그대로면 직접 import 2개 → 공용 모듈 full).
mk_lit() {  # $1=이름 $2=import_module 호출 식
  mk_py_fixture "$1"
  w tests/test_util.py 'def test_util(): pass'
  w tests/test_lit.py $'import importlib\nname = "pkg.util"\n'"$2"
  commit_all "lit"
}
mk_lit AT9j1 'importlib.import_module("pkg.util")'
edit_util; sel
expect_method "AT9(j) 리터럴/util 수정" import-search
eq "AT9(j) test_lit 이 정적 대상" "$(jq_py "d['tests']")" "['tests/test_lit.py']"
mk_lit AT9j2 'importlib.import_module("pkg.util")'
app src/pkg/core.py '# edit'; sel
eq "AT9(j) 리터럴/core 수정 — test_lit 없음" "$(jq_py "'tests/test_lit.py' in d['tests']")" False
mk_lit AT9j3 'importlib.import_module(name)'
app src/pkg/core.py '# edit'; sel
eq "AT9(j) 비리터럴/core 수정 — test_lit 있음" "$(jq_py "'tests/test_lit.py' in d['tests']")" True

# (k) 리터럴 판정 — JS: 인터폴레이션 없는 템플릿은 흔적 아님, 있으면 흔적
mk_jest_fixture AT9k1
w src/__tests__/k.test.js 'import(`./a`);'
commit_all "k literal"; app src/a.js '// edit'; sel
expect_method "AT9(k) 인터폴레이션 없음" jest
eq "AT9(k) 추가 없음" "$(jq_py "d['tests']")" "[]"
mk_jest_fixture AT9k2
w src/__tests__/k.test.js "$DYN_JS"
commit_all "k dynamic"; app src/a.js '// edit'; sel
expect_method "AT9(k) 인터폴레이션 있음" jest
eq "AT9(k) 추가됨" "$(jq_py "d['tests']")" "['src/__tests__/k.test.js']"

# (l) jest 절반 근사 — 테스트 8개(a, a2, p1~p3, d1~d3): 그래프 대상 2(a·a2) + dyn_extra 3(d1~d3) = 5 > 0.5 × 8
mk_jest_fixture AT9l
w src/__tests__/a2.test.js "const a = require('./../a');"
for n in 1 2 3; do w "src/__tests__/d$n.test.js" "$DYN_JS"; done
commit_all "l"; app src/a.js '// edit'; sel
expect_full "AT9(l)" '동적 import 흔적으로 대상 과다'

# (m) 리터럴 판정 — JS 결합식: 따옴표로 시작해도 뒤에 `+` 등이 이어지면 비리터럴(흔적).
#     loader.js 를 import 하는 loader.test.js 가 흔적 대상에 든다. 테스트 5(a, p1~p3, loader): 대상 1 ≤ 2.5
mk_concat() {  # $1=이름 $2=loader.js 의 호출 식
  mk_jest_fixture "$1"
  w src/x.js 'module.exports = 2;'
  w src/loader.js $'const name = "x"; const b = "y";\nmodule.exports = '"$2"';'
  w src/__tests__/loader.test.js $'const l = require(\'./../loader\');\ntest(\'l\', () => {});'
  commit_all "concat"; app src/a.js '// edit'; sel
}
for expr in 'require("./plugins/" + name)' 'import("./" + name)' "require('a' + b)"; do
  mk_concat "AT9m-$(printf '%s' "$expr" | tr -c 'a-z' '_')" "$expr"
  expect_method "AT9(m) $expr" jest
  eq "AT9(m) $expr → loader.test 흔적 대상" "$(jq_py "d['tests']")" "['src/__tests__/loader.test.js']"
done
# 이스케이프된 따옴표: 문자열 안의 `\"`·`\'` 는 닫는 따옴표가 아니다 — 그 뒤 `,`·`)` 도 문자열 내용(흔적)
for expr in 'require("a\", b" + name)' "require('x\\')' + y)" 'import(`./${n}`)'; do
  mk_concat "AT9m-esc-$(printf '%s' "$expr" | tr -c 'a-z' '_')" "$expr"
  expect_method "AT9(m) 이스케이프 $expr" jest
  eq "AT9(m) 이스케이프 $expr → loader.test 흔적 대상" "$(jq_py "d['tests']")" "['src/__tests__/loader.test.js']"
done
mk_concat AT9m-esc-lit 'require("a\"b")'
expect_method "AT9(m) 이스케이프 리터럴 require(\"a\\\"b\")" jest
eq "AT9(m) 이스케이프 리터럴 → 흔적 없음" "$(jq_py "d['tests']")" "[]"
mk_concat AT9m-lit 'require( "./x" )'
expect_method "AT9(m) 리터럴 require(\"./x\")" jest
eq "AT9(m) 리터럴 require(\"./x\") → 흔적 없음" "$(jq_py "d['tests']")" "[]"
mk_concat AT9m-lit2 'require("./x", {})'
eq "AT9(m) 리터럴 + 둘째 인자 → 흔적 없음" "$(jq_py "d['tests']")" "[]"

# (n) JS 문자열 이스케이프 해석 — `\x61`·`a`·`\u{61}` 은 표준대로 `a` 로 복원돼 실제 import 간선이 된다.
#     .bin/jest 없는 import-search 구성(AT25 와 같은 축): src/b.js 가 a 를 require, b.test.js 가 b 를 import.
#     잘못 복원하면(`./x61`) a.js 를 가져가는 테스트가 없어 '매핑되지 않는 소스' 로 full 이 된다. 테스트 4: 대상 1 ≤ 2
for expr in 'require("./\x61")' 'require("./a")' 'require("./\u{61}")' "require('./\\u0061')"; do
  mk_js_base "AT9n-$(printf '%s' "$expr" | tr -c 'a-z0-9' '_')" "$JEST_PKG"
  w src/b.js "const a = $expr;"
  w src/__tests__/b.test.js "import b from '../b';"
  commit_all "escape"; app src/a.js '// edit'; sel
  expect_method "AT9(n) $expr" import-search
  eq "AT9(n) $expr → b.test 대상" "$(jq_py "d['tests']")" "['src/__tests__/b.test.js']"
done
# 줄 이음 — 백슬래시 + 줄 종결자(LF·CRLF·CR)는 종결자 전체가 제거되어 `./a` 리터럴이 된다(CRLF 를 두 문자 단위로
# 건너뛰면 LF 위에 멈춰 비리터럴로 오판). 이름은 라벨로 준다 — LF·CR 식은 tr 결과가 같아 저장소 이름이 겹친다.
AT9N_CONT_LABELS=(lf crlf cr)
AT9N_CONT_EXPRS=($'require("./\\\na")' $'require("./\\\r\na")' $'require("./\\\ra")')
for k in 0 1 2; do
  mk_js_base "AT9n-cont-${AT9N_CONT_LABELS[$k]}" "$JEST_PKG"
  w src/b.js "const a = ${AT9N_CONT_EXPRS[$k]};"
  w src/__tests__/b.test.js "import b from '../b';"
  w src/z.js "module.exports = 2;"
  w src/__tests__/z.test.js "import z from '../z';"
  commit_all "cont"; app src/a.js '// edit'; sel
  expect_method "AT9(n) 줄 이음 ${AT9N_CONT_LABELS[$k]}" import-search
  # 리터럴로 해석돼 정적 간선(b.js → a.js)이 생긴다 — a.js 수정으로 b.test 가 선택된다
  eq "AT9(n) 줄 이음 ${AT9N_CONT_LABELS[$k]} → b.test 대상(정적 간선)" "$(jq_py "d['tests']")" "['src/__tests__/b.test.js']"
  # 동적 흔적이 아니다 — 흔적이면 b.js 가 흔적 집합에 들어 b.test 가 무관한 z.js 수정에도 따라붙는다
  commit_all "cont-edit"; app src/z.js '// edit'; sel
  expect_method "AT9(n) 줄 이음 ${AT9N_CONT_LABELS[$k]} 무관 수정" import-search
  eq "AT9(n) 줄 이음 ${AT9N_CONT_LABELS[$k]} → 흔적 아님(z.test 만)" "$(jq_py "d['tests']")" "['src/__tests__/z.test.js']"
  eq "AT9(n) 줄 이음 ${AT9N_CONT_LABELS[$k]} 사유에 동적 흔적 없음" "$(jq_py "any('동적 import' in r for r in d['reasons'])")" False
done
# 해석 불가·모호 → 비리터럴(흔적): 레거시 8진 `\1`, 잘못된 16진 `\xZZ`·`\u12`, 범위 초과 `\u{110000}`,
# 짝 없는 서로게이트 `\uD800`, `\0` 뒤 숫자 `\01`, 끝 백슬래시(닫는 따옴표가 이스케이프돼 미종결).
# c.js 를 import 하는 c.test.js 가 흔적 대상으로 더해진다. 테스트 5: 대상 2 ≤ 2.5
AT9N_DYN_LABELS=(octal badx badu range surrogate nuldigit trailing)
AT9N_DYN_EXPRS=('require("./\1")' 'require("./\xZZ")' 'require("./\u12")' 'require("./\u{110000}")'
  'require("./\uD800")' 'require("./\01")' 'require("./\")')
for k in 0 1 2 3 4 5 6; do
  mk_js_base "AT9n-dyn-${AT9N_DYN_LABELS[$k]}" "$JEST_PKG"
  w src/b.js "const a = require('./a');"
  w src/c.js "const z = ${AT9N_DYN_EXPRS[$k]};"
  w src/__tests__/b.test.js "import b from '../b';"
  w src/__tests__/c.test.js "import c from '../c';"
  commit_all "dyn-escape"; app src/a.js '// edit'; sel
  expect_method "AT9(n) ${AT9N_DYN_EXPRS[$k]}" import-search
  eq "AT9(n) ${AT9N_DYN_EXPRS[$k]} → c.test 흔적 대상" "$(jq_py "d['tests']")" "['src/__tests__/b.test.js', 'src/__tests__/c.test.js']"
done

# ============================================================================
echo "== AT10: 그래프 미완성·사용자 정의 판별 (D20·D22) =="
# (a) 문법 오류 비테스트 모듈
mk_py_fixture AT10a; w src/pkg/broken.py 'def (:'; commit_all "broken"; edit_util; sel
expect_full "AT10(a)" '파싱 실패로 흔적 집합 미완성: src/pkg/broken.py'
# (b) 문법 오류 테스트 파일
mk_py_fixture AT10b; w tests/test_broken.py 'def (:'; commit_all "broken test"; edit_util; sel
expect_full "AT10(b)" '파싱 실패로 흔적 집합 미완성: tests/test_broken.py'
# (c) jest + MAX_PARSE_BYTES(1,000,000) 초과 JS 파일
mk_jest_fixture AT10c
"$PY" -c 'import sys; open(sys.argv[1],"w").write("//" + "x"*1100000 + "\n")' "$R/src/big.js"
commit_all "big js"; app src/a.js '// edit'; sel
expect_full "AT10(c)" '파싱 실패로 흔적 집합 미완성:'
# (d) testmon 구성에 broken.py 가 있어도 method == testmon (흔적 스캔 비대상)
mk_testmon_fixture AT10d; w src/pkg/broken.py 'def (:'; commit_all "broken"; edit_util; sel
expect_method "AT10(d)" testmon
# (e) 사용자 정의 판별 — pytest
mk_py_fixture AT10e
w pyproject.toml $'[tool.pytest.ini_options]\npython_files = ["check_*.py"]'
commit_all "custom pytest"; edit_util; sel
expect_full "AT10(e)" '사용자 정의 테스트 판별 규칙: pyproject.toml'
# (f) jest testMatch
mk_js_base AT10f '{"devDependencies":{"jest":"^29"},"scripts":{"test":"jest"},"jest":{"testMatch":["**/*.check.js"]}}' jest
js_atest; commit_all; app src/a.js '// edit'; sel
expect_full "AT10(f)" '사용자 정의 테스트 판별 규칙:'
# (g) vitest include
mk_vitest_fixture AT10g
w vitest.config.ts "export default { test: { include: ['**/*.check.ts'] } }"
commit_all "vitest cfg"; app src/a.js '// edit'; sel
expect_full "AT10(g)" '사용자 정의 테스트 판별 규칙:'
# (h) 같은 pytest 설정이 있어도 testmon 구성이면 testmon, 유효한 프로젝트 스크립트가 있으면 project-script
mk_testmon_fixture AT10h1
w pyproject.toml $'[tool.pytest.ini_options]\npython_files = ["check_*.py"]'
commit_all "custom pytest"; edit_util; sel
expect_method "AT10(h) testmon" testmon
mk_py_fixture AT10h2
w pyproject.toml $'[tool.pytest.ini_options]\npython_files = ["check_*.py"]'
mk_script "$(json_body tests/test_a.py 'echo ok')"
commit_all "custom pytest + script"; edit_util; sel
expect_method "AT10(h) project-script" project-script

# ============================================================================
echo "== AT11: hard 복귀 조건 =="
mk_py_fixture AT11a; w pyproject.toml $'[project]\nname = "x"'; commit_all; app pyproject.toml '# edit'; sel
expect_full "AT11 pyproject.toml" '의존성·빌드 설정 변경:'
mk_py_fixture AT11b; w tests/conftest.py 'import pytest'; commit_all; app tests/conftest.py '# edit'; sel
expect_full "AT11 conftest.py" '테스트 공용 설정·픽스처 변경:'
mk_py_fixture AT11c; w tests/fixtures/data.json '{}'; commit_all; w tests/fixtures/data.json '{"a": 1}'; sel
expect_full "AT11 fixtures" '테스트 공용 설정·픽스처 변경:'
mk_py_fixture AT11d; w src/pkg/m6.py 'def m(): return 6'; commit_all
for f in core util helper orphan_base m6 __init__; do app "src/pkg/$f.py" '# edit'; done; sel
expect_full "AT11 소스 6개" '소스 파일 5개 초과:'
mk_py_fixture AT11e; rm "$R/src/pkg/orphan_base.py"; sel
expect_full "AT11 소스 삭제" '소스 파일 삭제·이름 변경:'
mk_py_fixture AT11f; edit_util; sel --external-inputs-changed
expect_full "AT11 외부 입력" '외부 입력 변경 선언'
mk_py_fixture AT11g; sel
expect_full "AT11 변경 없음" '변경 파일 없음'

# ============================================================================
echo "== AT12: 경계 (D14) =="
mk_py_fixture AT12a; seq 1 200 | sed 's/^/# /' >> "$R/src/pkg/util.py"; sel
eq "AT12 200줄 full 아님" "$(jq_py "d['full_run_required']")" False
eq "AT12 delta_lines == 200" "$(jq_py "d['delta_lines']")" 200
mk_py_fixture AT12b; seq 1 201 | sed 's/^/# /' >> "$R/src/pkg/util.py"; sel
expect_full "AT12 201줄" '변경 200줄 초과'
# 소스 5개 — 서로 다른 모듈이 테스트에 매핑되도록 s3~s5 를 test_multi 가 import (직접 import 1개씩 → 공용 모듈 아님)
# 전체 테스트 9: 대상 {test_core, test_helper, test_util, test_multi} = 4 ≤ 0.5 × 9
mk_five() {
  mk_py_fixture "$1"
  local n
  for n in 3 4 5; do w "src/pkg/s$n.py" "def s$n(): return $n"; done
  w tests/test_multi.py 'import pkg.s3, pkg.s4, pkg.s5'
  commit_all "five"
  for n in core util s3 s4 s5; do app "src/pkg/$n.py" '# edit'; done
}
mk_five AT12c; sel
eq "AT12 소스 5개 full 아님" "$(jq_py "d['full_run_required']")" False
eq "AT12 delta_source_files == 5" "$(jq_py "d['delta_source_files']")" 5
mk_five AT12d; app src/pkg/helper.py '# edit'; sel
expect_full "AT12 소스 6개" '소스 파일 5개 초과'
mk_py_fixture AT12e; w README.md 'readme'; commit_all "readme"; seq 1 300 | sed 's/^/line /' >> "$R/README.md"; sel
expect_full "AT12 README 300줄(문서도 줄 수에 든다)" '변경 200줄 초과'
mk_py_fixture AT12f; mkdir -p "$R/notes"; seq 1 250 | sed 's/^/n /' > "$R/notes/x.txt"; edit_util
sel
eq "AT12 범위 없음 — 미추적 포함 251" "$(jq_py "d['delta_lines']")" 251
sel --untracked-scope 'src/**'
eq "AT12 범위 지정 — 미추적 notes 제외 1" "$(jq_py "d['delta_lines']")" 1
eq "AT12 untracked_scope 그대로" "$(jq_py "d['untracked_scope']")" "['src/**']"

# ============================================================================
echo "== AT13: 미추적 스냅샷 (D18) =="
snap_line() { "$PY" -c 'import hashlib,sys; b=open(sys.argv[2],"rb").read(); print(sys.argv[1], hashlib.sha256(b).hexdigest(), b.count(b"\n"))' "$1" "$R/$1"; }
mk_py_fixture AT13a
seq 1 10 | sed 's/^/# /' > "$R/src/pkg/new_a.py"
seq 1 5 | sed 's/^/# /' > "$R/src/pkg/keep.py"
{ snap_line src/pkg/new_a.py; snap_line src/pkg/keep.py; } > "$R/.snap"
seq 1 7 | sed 's/^/# /' > "$R/src/pkg/keep.py"
rm "$R/src/pkg/new_a.py"
seq 1 3 | sed 's/^/# /' > "$R/src/pkg/new_b.py"
sel --untracked-snapshot "$R/.snap"
eq "AT13 rc" "$RC" 0
eq "AT13 changed" "$(jq_py "sorted([(c['path'], c['status']) for c in d['changed']])")" \
  "[('src/pkg/keep.py', '?? modified'), ('src/pkg/new_a.py', '?? deleted'), ('src/pkg/new_b.py', '?? added')]"
eq "AT13 delta_lines == 7 + 10 + 3" "$(jq_py "d['delta_lines']")" 20
# 추적 전환 규칙 — 스냅샷 경로를 git add 하면 ?? deleted 로 세지 않는다
mk_py_fixture AT13b
seq 1 10 | sed 's/^/# /' > "$R/src/pkg/new_a.py"
snap_line src/pkg/new_a.py > "$R/.snap"
( cd "$R" && git add src/pkg/new_a.py )
sel --untracked-snapshot "$R/.snap"
eq "AT13 추적 전환 — ?? deleted 없음" "$(jq_py "any(c['status'] == '?? deleted' for c in d['changed'])")" False
eq "AT13 추적 전환 — 추적 파일 항목으로 센다" "$(jq_py "[c['status'] for c in d['changed'] if c['path'] == 'src/pkg/new_a.py']")" "['A']"
# none 스냅샷 == 옵션 생략
mk_py_fixture AT13c
seq 1 4 | sed 's/^/# /' > "$R/src/pkg/extra.py"
sel; NOOPT=$(jq_py "(d['changed'], d['delta_lines'])")
printf 'none\n' > "$R/.snap"; sel --untracked-snapshot "$R/.snap"
eq "AT13 none 스냅샷 == 옵션 생략" "$(jq_py "(d['changed'], d['delta_lines'])")" "$NOOPT"
# 형식이 틀린 스냅샷 → exit 2
mk_py_fixture AT13d; edit_util
printf 'garbage\n' > "$R/.snap"; sel --untracked-snapshot "$R/.snap"
eq "AT13 형식 오류 스냅샷 → exit 2" "$RC" 2

# ============================================================================
echo "== AT14: 잘못된 기준 =="
mk_py_fixture AT14; edit_util; sel --base no-such-ref
expect_full "AT14" '기준 ref 해석 불가'

# ============================================================================
echo "== AT15: 스택 =="
mk_py_fixture AT15a; w run.sh 'echo hi'; commit_all; app run.sh '# edit'; sel
expect_full "AT15 지원 스택 밖" '지원 스택 밖'
mk_py_fixture AT15b; w src/a.js 'module.exports = 1;'; commit_all; edit_util; app src/a.js '// edit'; sel
expect_full "AT15 다중 스택" '다중 스택 변경'
new_repo AT15c; w src/x.py 'def x(): pass'; w tests/test_x.py 'import x'; commit_all; app src/x.py '# edit'; sel
expect_full "AT15 pytest 미감지" '지원 스택 밖: pytest 미감지'

# ============================================================================
echo "== AT16: 프로젝트 스크립트 우선 =="
mk_py_fixture AT16
mk_script "$(printf '%s\n%s' 'cat > "$REIN_AFFECTED_ROOT/.stdin.log"' "$(json_body tests/test_a.py 'echo ok')")"
commit_all "script"; edit_util; sel
expect_method "AT16" project-script
eq "AT16 tests" "$(jq_py "d['tests']")" "['tests/test_a.py']"
eq "AT16 command" "$(jq_py "d['command']")" "echo ok"
if grep -q 'src/pkg/util.py' "$R/.stdin.log" 2>/dev/null; then _pass "AT16 stdin 에 바뀐 경로"; else _fail "AT16 stdin 로그에 바뀐 경로 없음"; fi

# ============================================================================
echo "== AT17: 스크립트 기준 판 (D12) =="
for mode in unstaged staged; do
  mk_py_fixture "AT17a-$mode"
  mk_script "$(json_body tests/test_a.py 'echo a')"; commit_all "script A"
  mk_script "$(json_body tests/test_b.py 'echo b')"
  [ "$mode" = staged ] && ( cd "$R" && git add .rein/affected-tests.sh )
  edit_util; sel
  eq "AT17(a) $mode tests 는 기준 판 결과" "$(jq_py "d['tests']")" "['tests/test_a.py']"
  has_reason "AT17(a) $mode 기준 판으로 실행" '기준 판으로 실행'
done
# (b) HEAD 에는 있고 --base 에는 없는 스크립트
mk_py_fixture AT17b; BASE0=$(base_sha)
mk_script "$(printf '%s\n%s' 'touch "$REIN_AFFECTED_ROOT/.ran"' "$(json_body tests/test_a.py 'echo a')")"
commit_all "add script"; edit_util; sel --base "$BASE0"
absent "AT17(b) 스크립트 미실행" "$R/.ran"
has_reason "AT17(b) 기준에 없음" '기준(--base)에 없음'
eq "AT17(b) 다음 단계 import-search" "$(jq_py "d['method']")" import-search
# (c) 기준에는 있고 작업 트리에서 삭제 → 기준 판 실행
mk_py_fixture AT17c; mk_script "$(json_body tests/test_a.py 'echo a')"; commit_all "script"
rm "$R/.rein/affected-tests.sh"; edit_util; sel
expect_method "AT17(c)" project-script
eq "AT17(c) tests" "$(jq_py "d['tests']")" "['tests/test_a.py']"
# (d) 미추적 새 스크립트
mk_py_fixture AT17d
mk_script "$(printf '%s\n%s' 'touch "$REIN_AFFECTED_ROOT/.ran"' "$(json_body tests/test_a.py 'echo a')")"
edit_util; sel
absent "AT17(d) 미추적 스크립트 미실행" "$R/.ran"

# (e) 스크립트가 권한을 빼도 임시 기준 트리는 남지 않는다 — cwd(기준 트리)·그 부모(최상위 임시 디렉터리)
for target in . ..; do
  mk_py_fixture "AT17e-${#target}"
  mk_script "$(printf '%s\n%s' "chmod 000 $target" "$(json_body tests/test_a.py 'echo a')")"
  commit_all "script chmod"; edit_util
  SELTMP="$WORK/tmp-AT17e-${#target}"; mkdir -p "$SELTMP"
  SEL_ENV="TMPDIR=$SELTMP" sel
  expect_method "AT17(e) chmod 000 $target" project-script
  left=$(find "$SELTMP" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
  eq "AT17(e) chmod 000 $target 뒤 임시 트리 없음" "$left" 0
  if grep -q '임시 디렉터리를 지우지 못함' "$R/.err.txt"; then _fail "AT17(e) $target 삭제 경고 출력"; else _pass "AT17(e) $target 삭제 경고 없음"; fi
done

# ============================================================================
echo "== AT18: 스크립트 실패 하강 =="
fail_case() {  # $1=이름 $2=스크립트 본문 $3=사유 부분 문자열
  mk_py_fixture "$1"; mk_script "$2"; commit_all "script"; edit_util; sel
  expect_method "$1" import-search
  has_reason "$1 사유" "$3"
}
fail_case AT18a 'echo oops >&2; exit 1' '프로젝트 스크립트 실패(rc=1)'
fail_case AT18b 'echo not-json' '프로젝트 스크립트 출력 형식 오류'
fail_case AT18c "echo '{\"tests\":[\"tests/nope.py\"],\"command\":\"x\"}'" '프로젝트 스크립트 출력 형식 오류'
fail_case AT18d "head -c 1048577 /dev/zero | tr '\\0' 'a'" '프로젝트 스크립트 출력 형식 오류'
fail_case AT18e "head -c 5242880 /dev/zero | tr '\\0' 'a'; exit 0" '프로젝트 스크립트 출력 형식 오류'
mk_py_fixture AT18f; mk_script 'sleep 5'; commit_all "script"; edit_util
T0=$(now); SEL_ENV=REIN_AFFECTED_TESTS_SCRIPT_TIMEOUT=1 sel; T1=$(now)
has_reason "AT18 시간 초과" '시간 초과'
if [ $((T1 - T0)) -lt 4 ]; then _pass "AT18 시간 초과 경과 4초 미만"; else _fail "AT18 경과 $((T1 - T0))초"; fi

# ============================================================================
echo "== AT19: 자손까지 종료 =="
mk_py_fixture AT19; mk_script 'sleep 30 & echo $! > "$REIN_AFFECTED_ROOT/.child.pid"; sleep 30'
commit_all "script"; edit_util
SEL_ENV=REIN_AFFECTED_TESTS_SCRIPT_TIMEOUT=1 sel
CHILD=$(cat "$R/.child.pid" 2>/dev/null || echo 0)
gone=0
for _ in 1 2 3; do
  if ! kill -0 "$CHILD" 2>/dev/null; then gone=1; break; fi
  sleep 1
done
[ "$CHILD" -gt 0 ] 2>/dev/null && kill "$CHILD" 2>/dev/null
if [ "$gone" = 1 ] && [ "$CHILD" != 0 ]; then _pass "AT19 자손 프로세스까지 종료"; else _fail "AT19 자손(pid=$CHILD) 이 남아 있음"; fi

# ============================================================================
echo "== AT20: 스크립트 exit 3 =="
mk_py_fixture AT20; mk_script 'exit 3'; commit_all "script"; edit_util; sel
expect_full "AT20" '프로젝트 스크립트가 전체 실행을 요구'

# ============================================================================
echo "== AT21: 기준 판이 심볼릭 링크 =="
mk_py_fixture AT21
printf 'touch "%s/.ran"\n' "$R" > "$R/.outside.sh"
mkdir -p "$R/.rein"; ln -s "$R/.outside.sh" "$R/.rein/affected-tests.sh"
commit_all "symlink script"; edit_util; sel
absent "AT21 링크 대상 미실행" "$R/.ran"
has_reason "AT21 일반 파일이 아님" '기준 판이 일반 파일이 아님'
eq "AT21 다음 단계로 하강" "$(jq_py "d['method']")" import-search

# ============================================================================
echo "== AT21b: 기준 트리 격리 실행 (신뢰 경계) =="
# (a) 기준 entrypoint 가 source 하는 helper 를 작업 트리에서만 바꿔도 기준 helper 가 실행된다
mk_py_fixture AT21b-a
w .rein/affected-helper.sh 'touch "$REIN_AFFECTED_TARGET/.ran-base"'
mk_script "$(printf '%s\n%s' '. ./.rein/affected-helper.sh' "$(json_body tests/test_a.py 'echo ok')")"
commit_all "script + helper"
w .rein/affected-helper.sh 'touch "$REIN_AFFECTED_TARGET/.ran"'
edit_util; sel
expect_method "AT21b(a)" project-script
absent "AT21b(a) 바뀐 helper 미실행" "$R/.ran"
present "AT21b(a) 기준 helper 실행" "$R/.ran-base"
# (b) BASH_ENV·ENV 로 지정한 파일은 실행되지 않는다
mk_py_fixture AT21b-b
printf 'touch "%s/.ran"\n' "$R" > "$R/.outside.sh"
mk_script "$(json_body tests/test_a.py 'echo ok')"; commit_all "script"; edit_util
SEL_ENV="BASH_ENV=$R/.outside.sh ENV=$R/.outside.sh" sel
expect_method "AT21b(b)" project-script
absent "AT21b(b) BASH_ENV 파일 미실행" "$R/.ran"
# (c) $REIN_AFFECTED_TARGET 로 현재 저장소(작업 트리 판)를 읽는다. cwd 는 저장소 밖 임시 트리이고 실행 후 삭제된다
mk_py_fixture AT21b-c
mk_script "$(printf '%s\n' 'pwd > "$REIN_AFFECTED_TARGET/.cwd.txt"' \
  't=$(cat "$REIN_AFFECTED_TARGET/.target.txt")' \
  'echo "{\"tests\":[\"$t\"],\"command\":\"echo t\"}"')"
commit_all "script"; printf 'tests/test_b.py' > "$R/.target.txt"; edit_util; sel
expect_method "AT21b(c)" project-script
eq "AT21b(c) 작업 트리 데이터 반영" "$(jq_py "d['tests']")" "['tests/test_b.py']"
CWD=$(cat "$R/.cwd.txt" 2>/dev/null)
case "$CWD" in
  ""|"$R"|"$R"/*) _fail "AT21b(c) cwd 가 저장소 밖이 아님 ('$CWD')" ;;
  *) _pass "AT21b(c) cwd 는 저장소 밖" ;;
esac
if [ -n "$CWD" ]; then absent "AT21b(c) 임시 트리 삭제" "$CWD"; else _fail "AT21b(c) cwd 기록 없음"; fi
# (d) 기준 트리에 트리 밖을 가리키는 심볼릭 링크가 있으면 스크립트를 실행하지 않고 하강
mk_py_fixture AT21b-d
mk_script "$(printf '%s\n%s' 'touch "$REIN_AFFECTED_TARGET/.ran"' "$(json_body tests/test_a.py 'echo ok')")"
ln -s ../../etc "$R/escape"
commit_all "escape link"; edit_util; sel
absent "AT21b(d) 스크립트 미실행" "$R/.ran"
has_reason "AT21b(d) 거부 사유" '트리 밖을 가리키는 항목'
eq "AT21b(d) 다음 단계로 하강" "$(jq_py "d['method']")" import-search

# ============================================================================
echo "== AT22: 순서 (D11) =="
# (a) 유효 스크립트가 있어도 pyproject.toml 수정이 있으면 full, 스크립트 미실행
mk_py_fixture AT22a; w pyproject.toml $'[project]\nname = "x"'
mk_script "$(printf '%s\n%s' 'cat > "$REIN_AFFECTED_ROOT/.stdin.log"' "$(json_body tests/test_a.py 'echo ok')")"
commit_all; app pyproject.toml '# edit'; sel
expect_full "AT22(a)" '의존성·빌드 설정 변경:'
absent "AT22(a) 스크립트 미실행(stdin 로그 부재)" "$R/.stdin.log"
# (b) poetry.lock(testmon 없음) + 가짜 poetry + pyproject.toml 수정, 설치 허용
mk_py_fixture AT22b; w pyproject.toml $'[project]\nname = "x"'; w poetry.lock '# lock'; mk_fake poetry 0
commit_all; app pyproject.toml '# edit'; SEL_INSTALL=1 sel
expect_full "AT22(b)" '의존성·빌드 설정 변경:'
absent "AT22(b) 가짜 poetry 미호출" "$R/.argv.log"
eq "AT22(b) install == null" "$(jq_py "d['install'] is None")" True
# (c) 유효 스크립트 + poetry.lock + 가짜 poetry, 설치 허용
mk_py_fixture AT22c; w poetry.lock '# lock'; mk_fake poetry 0
mk_script "$(json_body tests/test_a.py 'echo ok')"; commit_all; edit_util; SEL_INSTALL=1 sel
expect_method "AT22(c)" project-script
absent "AT22(c) 가짜 poetry 미호출" "$R/.argv.log"
eq "AT22(c) install == null" "$(jq_py "d['install'] is None")" True
# (d) 다중 스택 + poetry.lock + 가짜 poetry, 설치 허용
mk_py_fixture AT22d; w poetry.lock '# lock'; w src/a.js 'module.exports = 1;'; mk_fake poetry 0
commit_all; edit_util; app src/a.js '// edit'; SEL_INSTALL=1 sel
expect_full "AT22(d)" '다중 스택 변경'
absent "AT22(d) 가짜 poetry 미호출" "$R/.argv.log"

# ============================================================================
echo "== AT23: jest =="
mk_jest_fixture AT23; app src/a.js '// edit'; sel
expect_method "AT23" jest
eq "AT23 command" "$(jq_py "d['command']")" "node_modules/.bin/jest --findRelatedTests src/a.js"
eq "AT23 tests" "$(jq_py "d['tests']")" "[]"
absent "AT23 선택기는 jest 를 실행하지 않는다" "$R/.ran"

echo "== AT24: vitest =="
mk_vitest_fixture AT24a; app src/a.js '// edit'; sel
expect_method "AT24 vitest" vitest
eq "AT24 command" "$(jq_py "d['command']")" "node_modules/.bin/vitest related --run src/a.js"
mk_js_base AT24b '{"devDependencies":{"jest":"^29","vitest":"^1"},"scripts":{"test":"jest"}}' jest vitest
js_atest; commit_all; app src/a.js '// edit'; sel
expect_method "AT24 둘 다 + scripts.test jest → jest" jest
mk_js_base AT24c '{"devDependencies":{"jest":"^29","vitest":"^1"}}' jest vitest
js_atest; commit_all; app src/a.js '// edit'; sel
expect_method "AT24 둘 다 + scripts 없음 → vitest" vitest

echo "== AT25: .bin/jest 없음 → import-search =="
mk_js_base AT25 "$JEST_PKG"
w src/b.js "const a = require('./a');"
w src/__tests__/b.test.js "import b from '../b';"
commit_all; app src/a.js '// edit'; sel
expect_method "AT25" import-search
eq "AT25 tests" "$(jq_py "d['tests']")" "['src/__tests__/b.test.js']"
eq "AT25 command" "$(jq_py "d['command']")" "npm test -- src/__tests__/b.test.js"

# ============================================================================
echo "== AT26: testmon (D17) =="
FULLCMDS=""
mk_testmon_fixture AT26a; edit_util; SEL_INSTALL=1 sel
expect_method "AT26 기록 있음" testmon
eq "AT26 command" "$(jq_py "d['command']")" "poetry run pytest --testmon"
eq "AT26 install == null" "$(jq_py "d['install'] is None")" True
mk_testmon_fixture AT26b no-data; edit_util; sel
expect_full "AT26 기록 없음" 'testmon 기록 없음'
eq "AT26 기록 없음 command" "$(jq_py "d['command']")" "poetry run pytest --testmon-noselect"
FULLCMDS="$FULLCMDS|$(jq_py "d['command']")"
mk_testmon_fixture AT26c; app pyproject.toml '# edit'; sel
expect_full "AT26 hard 조건" '의존성·빌드 설정 변경:'
eq "AT26 hard 조건 command" "$(jq_py "d['command']")" "poetry run pytest --testmon-noselect"
FULLCMDS="$FULLCMDS|$(jq_py "d['command']")"
case "$FULLCMDS" in
  *" --testmon|"*|*" --testmon") _fail "AT26 full 명령이 ' --testmon' 으로 끝남: $FULLCMDS";;
  *) _pass "AT26 어느 full 출력도 ' --testmon' 으로 끝나지 않음";;
esac

# ============================================================================
echo "== AT27: poetry 설치 =="
mk_py_fixture AT27; w poetry.lock '# lock'; mk_fake poetry 0; commit_all; edit_util
SEL_INSTALL=1 sel
eq "AT27 install.status" "$(jq_py "d['install']['status']")" installed
eq "AT27 argv" "$(cat "$R/.argv.log" 2>/dev/null)" 'add --group dev pytest-testmon>=2,<3'
eq "AT27 argv 한 줄" "$(wc -l < "$R/.argv.log" | no_ws)" 1
eq "AT27 full" "$(jq_py "d['full_run_required']")" True
has_reason "AT27 설치 사유" '테스트 도구 설치'
eq "AT27 command" "$(jq_py "d['command']")" "poetry run pytest --testmon-noselect"
eq "AT27 상태 파일" "$(st "d['schema'] == 1 and d['tool'] == 'pytest-testmon' and d['status'] == 'installed' and d['manager'] == 'poetry'")" True
eq "AT27 상태 at 이 Z 로 끝남" "$(st "d['at'].endswith('Z')")" True

echo "== AT28: 재시도 안 함 =="
SEL_INSTALL=1 sel
eq "AT28 argv 여전히 한 줄" "$(wc -l < "$R/.argv.log" | no_ws)" 1
eq "AT28 install.status" "$(jq_py "d['install']['status']")" already-recorded

echo "== AT29: uv =="
mk_py_fixture AT29; w uv.lock '# lock'; mk_fake uv 0; commit_all; edit_util
SEL_INSTALL=1 sel
eq "AT29 argv" "$(cat "$R/.argv.log" 2>/dev/null)" 'add --dev pytest-testmon>=2,<3'
eq "AT29 install.manager" "$(jq_py "d['install']['manager']")" uv
eq "AT29 상태 manager" "$(st "d['manager']")" uv

echo "== AT30: pip =="
mk_pip_venv() {  # 가짜 venv: -I probe 는 exit 1, 그 밖 호출은 argv 기록 후 exit 0
  mkdir -p "$R/.venv/bin"; printf 'home = /usr/bin\n' > "$R/.venv/pyvenv.cfg"
  printf '#!/bin/sh\n[ "$1" = "-I" ] && exit 1\necho "$*" >> "%s/.argv.log"\nexit 0\n' "$R" > "$R/.venv/bin/python"
  chmod +x "$R/.venv/bin/python"
}
mk_py_fixture AT30; w requirements-dev.txt 'pytest'; commit_all; mk_pip_venv; edit_util
SEL_ENV="VIRTUAL_ENV=$R/.venv" SEL_INSTALL=1 sel
eq "AT30 argv" "$(cat "$R/.argv.log" 2>/dev/null)" '-m pip install pytest-testmon>=2,<3'
eq "AT30 install.manager" "$(jq_py "d['install']['manager']")" pip
eq "AT30 requirements-dev 마지막 줄" "$(tail -n 1 "$R/requirements-dev.txt")" 'pytest-testmon>=2,<3'
eq "AT30 그 줄 1개" "$(grep -c '^pytest-testmon>=2,<3$' "$R/requirements-dev.txt")" 1

echo "== AT31: requirements-dev 갱신 규칙 =="
mk_py_fixture AT31a; w requirements-dev.txt 'pytest-testmon==2.1.0'; commit_all; mk_pip_venv; edit_util
SEL_ENV="VIRTUAL_ENV=$R/.venv" SEL_INSTALL=1 sel
eq "AT31 이미 있으면 줄 추가 안 함" "$(cat "$R/requirements-dev.txt")" 'pytest-testmon==2.1.0'
mk_py_fixture AT31b; mkdir -p "$R/.elsewhere"; printf 'pytest\n' > "$R/.elsewhere/req.txt"
ln -s "$R/.elsewhere/req.txt" "$R/requirements-dev.txt"; commit_all; mk_pip_venv; edit_util
SEL_ENV="VIRTUAL_ENV=$R/.venv" SEL_INSTALL=1 sel
eq "AT31 심볼릭 링크 대상 내용 불변" "$(cat "$R/.elsewhere/req.txt")" 'pytest'
eq "AT31 message 에 심볼릭 링크" "$(jq_py "'심볼릭 링크' in d['install']['message']")" True

# ============================================================================
echo "== AT32: 설치 실패 폴백 =="
mk_py_fixture AT32a; w poetry.lock '# lock'; mk_fake poetry 1; commit_all; edit_util
SEL_INSTALL=1 sel
eq "AT32 install.status" "$(jq_py "d['install']['status']")" failed
eq "AT32 상태 failed" "$(st "d['status']")" failed
eq "AT32 reason rc=1" "$(st "'rc=1' in d['reason']")" True
expect_method "AT32 폴백" import-search
eq "AT32 tests (AT2 와 같은 대상)" "$(jq_py "d['tests']")" "['tests/test_util.py']"
mk_py_fixture AT32b; w poetry.lock '# lock'; mk_fake poetry 0 5; commit_all; edit_util
SEL_ENV=REIN_AFFECTED_TESTS_INSTALL_TIMEOUT=1 SEL_INSTALL=1 sel
eq "AT32 시간 초과 failed" "$(jq_py "d['install']['status']")" failed
eq "AT32 reason 에 timeout" "$(st "'timeout' in d['reason']")" True

echo "== AT33: venv 없음 =="
mk_py_fixture AT33; mk_fake poetry 0; edit_util
SEL_INSTALL=1 sel
absent "AT33 설치 명령 미실행" "$R/.argv.log"
eq "AT33 install.status" "$(jq_py "d['install']['status']")" skipped
eq "AT33 상태 skipped/no-project-env" "$(st "d['status'] == 'skipped' and d['reason'] == 'no-project-env'")" True

echo "== AT34: 정책 false =="
mk_py_fixture AT34a; w poetry.lock '# lock'; w .rein/policy/test-selection.yaml 'auto_install_test_tools: false'
mk_fake poetry 0; commit_all; edit_util
SEL_INSTALL=1 sel
absent "AT34 가짜 poetry 미호출" "$R/.argv.log"
eq "AT34 install.status" "$(jq_py "d['install']['status']")" disabled
absent "AT34 상태 파일 부재" "$R/.rein/state/test-tools.json"
sel   # --no-install
absent "AT34 --no-install 미호출" "$R/.argv.log"
eq "AT34 --no-install install.status" "$(jq_py "d['install']['status']")" disabled
absent "AT34 --no-install 상태 파일 부재" "$R/.rein/state/test-tools.json"
mk_py_fixture AT34b; w poetry.lock '# lock'; mk_fake poetry 0; commit_all; edit_util
sel
absent "AT34 정책 없이 --no-install 만 — 미호출" "$R/.argv.log"
eq "AT34 정책 없이 --no-install install.status" "$(jq_py "d['install']['status']")" disabled

# ============================================================================
echo "== AT35: 상태 경로 심볼릭 링크 4종 =="
at35_check() {  # $1=설명 — 선택기 실행 후 refused 단언 + .elsewhere 불변
  local before after
  before=$(snap_dir "$R/.elsewhere")
  SEL_INSTALL=1 sel
  eq "$1 changed 는 바꾼 소스 하나뿐" "$(jq_py "[c['path'] for c in d['changed']]")" "['src/pkg/util.py']"
  eq "$1 install.status" "$(jq_py "d['install']['status']")" refused
  absent "$1 가짜 poetry 미호출" "$R/.argv.log"
  after=$(snap_dir "$R/.elsewhere")
  eq "$1 .elsewhere 불변" "$after" "$before"
}
at35_base() {  # $1=이름 — poetry.lock(testmon 없음) + 가짜 poetry. 링크는 호출자가
  mk_py_fixture "$1"; w poetry.lock '# lock'; mk_fake poetry 0; mkdir -p "$R/.elsewhere"
}
# 1) .rein 링크 — 기준 커밋에 포함
at35_base AT35a; mkdir -p "$R/.elsewhere/d1"; ln -s "$R/.elsewhere/d1" "$R/.rein"; commit_all; edit_util
at35_check "AT35 .rein 링크"
# 2) .rein/state 링크 — 기준 커밋에 포함
at35_base AT35b; mkdir -p "$R/.elsewhere/d2" "$R/.rein"; ln -s "$R/.elsewhere/d2" "$R/.rein/state"; commit_all; edit_util
at35_check "AT35 .rein/state 링크"
# 3) 기록 파일 링크 — 무시 목록 안이라 커밋하지 않는다
at35_base AT35c; commit_all; mkdir -p "$R/.rein/state"; printf 'ORIG\n' > "$R/.elsewhere/tt.json"
ln -s "$R/.elsewhere/tt.json" "$R/.rein/state/test-tools.json"; edit_util
at35_check "AT35 test-tools.json 링크"
# 4) 잠금 파일 링크
at35_base AT35d; commit_all; mkdir -p "$R/.rein/state"; printf 'ORIG\n' > "$R/.elsewhere/lock.file"
ln -s "$R/.elsewhere/lock.file" "$R/.rein/state/test-tools.lock"; edit_util
at35_check "AT35 test-tools.lock 링크"

echo "== AT36: 손상된 기록 =="
mk_py_fixture AT36; w poetry.lock '# lock'; mk_fake poetry 0; commit_all; edit_util
mkdir -p "$R/.rein/state"; printf 'not json' > "$R/.rein/state/test-tools.json"
SEL_INSTALL=1 sel
eq "AT36 install.status" "$(jq_py "d['install']['status']")" already-recorded
absent "AT36 미호출" "$R/.argv.log"

echo "== AT37: 잠금 경합 =="
mk_py_fixture AT37; w poetry.lock '# lock'; mk_fake poetry 0; commit_all; edit_util
mkdir -p "$R/.rein/state"
"$PY" -c 'import fcntl,os,sys,time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").write(str(os.getpid()))
time.sleep(3)' "$R/.rein/state/test-tools.lock" "$R/.child.pid" &
for _ in $(seq 1 30); do [ -s "$R/.child.pid" ] && break; sleep 0.1; done
SEL_INSTALL=1 sel
eq "AT37 install.status" "$(jq_py "d['install']['status']")" busy
absent "AT37 미호출" "$R/.argv.log"
absent "AT37 상태 파일 부재" "$R/.rein/state/test-tools.json"
wait

# ============================================================================
echo "== AT38: 스캔 상한 =="
mk_py_fixture AT38a; edit_util; SEL_ENV=REIN_AFFECTED_TESTS_MAX_SCAN=3 sel
expect_full "AT38 python" '검색 대상 파일 과다'
mk_jest_fixture AT38b; app src/a.js '// edit'; SEL_ENV=REIN_AFFECTED_TESTS_MAX_SCAN=3 sel
expect_full "AT38 jest" '검색 대상 파일 과다'

# ============================================================================
echo "== AT39: 시간 상한 (D13) =="
mk_py_fixture AT39a; edit_util; SEL_ENV=REIN_AFFECTED_DEADLINE_SEC=0 sel
expect_full "AT39 기한 0" '시간 상한'
mk_py_fixture AT39b; mk_script 'sleep 5'; commit_all "script"; edit_util
T0=$(now); SEL_ENV=REIN_AFFECTED_DEADLINE_SEC=2 sel; T1=$(now)
expect_full "AT39 기한 2초 + sleep 5" '시간 상한'
if [ $((T1 - T0)) -ge 2 ] && [ $((T1 - T0)) -le 5 ]; then _pass "AT39 2~5초 안에 반환 ($((T1 - T0))초)"; else _fail "AT39 경과 $((T1 - T0))초"; fi
# 미추적 3000개 — 기한 초과가 반드시 미추적 루프 안에서 일어나야 한다.
# 같은 256 MiB 희소 파일 하나를 3000개 경로로 하드링크한다: 디스크는 거의 쓰지 않고,
# 논리적으로는 3000 × 256 MiB 를 읽어야 하므로 이 머신에서도 1초를 훌쩍 넘긴다(기한 검사가 없으면 수 분).
mk_py_fixture AT39c
"$PY" -c 'import os,sys
d, n, sz = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
os.makedirs(d, exist_ok=True)
b = os.path.join(d, "f0.txt")
with open(b, "wb") as f:
    f.truncate(sz)
for i in range(1, n):
    os.link(b, os.path.join(d, "f%d.txt" % i))' "$R/bulk" 3000 268435456
T0=$(now); SEL_ENV=REIN_AFFECTED_DEADLINE_SEC=1 sel; T1=$(now)
expect_full "AT39 미추적 3000개" '시간 상한'
if [ $((T1 - T0)) -le 5 ]; then _pass "AT39 미추적 3000개 5초 안에 반환 ($((T1 - T0))초)"; else _fail "AT39 미추적 경과 $((T1 - T0))초"; fi

# ============================================================================
echo "== AT40: text 형식 =="
mk_py_fixture AT40; edit_util; sel --format text
eq "AT40 rc" "$RC" 0
case "$(printf '%s\n' "$OUT" | sed -n 1p)" in "선택 방법: "*) _pass "AT40 1행 접두";; *) _fail "AT40 1행: $(printf '%s\n' "$OUT" | sed -n 1p)";; esac
case "$(printf '%s\n' "$OUT" | sed -n 2p)" in "전체 실행 필요: "*) _pass "AT40 2행 접두";; *) _fail "AT40 2행: $(printf '%s\n' "$OUT" | sed -n 2p)";; esac
case "$(printf '%s\n' "$OUT" | sed -n 3p)" in "대상 테스트"*) _pass "AT40 3행 접두";; *) _fail "AT40 3행: $(printf '%s\n' "$OUT" | sed -n 3p)";; esac
for pre in '실행 명령: ' '기준: ' '줄 수: '; do
  if printf '%s\n' "$OUT" | grep -q "^$pre"; then _pass "AT40 '$pre' 줄"; else _fail "AT40 '$pre' 줄 없음"; fi
done
eq "AT40 마지막 줄" "$(printf '%s\n' "$OUT" | tail -n 1)" '델타 증거 칸: selection: import-search'

echo "== AT41: JSON 키 집합 =="
mk_py_fixture AT41; edit_util; sel
eq "AT41 키 집합" "$(jq_py "sorted(d.keys())")" \
  "['base', 'changed', 'command', 'delta_lines', 'delta_source_files', 'full_run_required', 'install', 'method', 'reasons', 'schema', 'tests', 'untracked_scope']"

echo "== AT42: 상수·구조 고정 =="
for lit in 'MAX_SOURCE_FILES = 5' 'MAX_DELTA_LINES = 200' 'IMPORT_SEARCH_MAX_RATIO = 0.5' 'SHARED_MODULE_MIN_TESTS = 2' \
           'SELECTOR_BUDGET = 600' 'SCRIPT_STDOUT_MAX = 1_048_576' 'INSTALL_SPEC = "pytest-testmon>=2,<3"' '--testmon-noselect'; do
  if grep -qF -- "$lit" "$SEL" 2>/dev/null; then _pass "AT42 '$lit'"; else _fail "AT42 선택기에 '$lit' 없음"; fi
done
eq "AT42 shell=True 0건" "$(grep -c 'shell=True' "$SEL" 2>/dev/null)" 0
if [ "$(grep -c 'start_new_session=True' "$SEL" 2>/dev/null)" -ge 1 ]; then _pass "AT42 start_new_session=True 1건 이상"; else _fail "AT42 start_new_session=True 없음"; fi
if [ "$(grep -o '\.expired()' "$SEL" 2>/dev/null | wc -l | no_ws)" -ge 3 ]; then _pass "AT42 .expired() 3건 이상"; else _fail "AT42 .expired() 3건 미만"; fi
eq "AT42 TESTMON_BASE_SLACK 0건" "$(grep -c 'TESTMON_BASE_SLACK' "$SEL" 2>/dev/null)" 0
eq "AT42 st_mtime 0건" "$(grep -c 'st_mtime' "$SEL" 2>/dev/null)" 0

# ============================================================================
echo "== AT43: 줄 수 스트리밍 (D21) =="
# 약 12 MiB: 104자 + 개행 = 105바이트 × 120000줄 + 개행 없는 마지막 줄 → wc -l 과 같은 120000
mk_py_fixture AT43a
"$PY" -c 'import sys
line = "x" * 104 + "\n"
with open(sys.argv[1], "w") as f:
    f.write(line * 120000)
    f.write("tail without newline")' "$R/big.txt"
sel
eq "AT43 delta_lines == 120000 (절단 없음·마지막 줄 미계수)" "$(jq_py "d['delta_lines']")" "$(wc -l < "$R/big.txt" | no_ws)"
eq "AT43 delta_lines == 120000 (리터럴)" "$(jq_py "d['delta_lines']")" 120000
# 같은 원리로 파일 크기를 키운다: 1 GiB 희소 파일 하나를 50개 경로로 하드링크(논리 50 GiB) — 1초 기한 안에 읽을 수 없다
mk_py_fixture AT43b
"$PY" -c 'import os,sys
d, n, sz = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
os.makedirs(d, exist_ok=True)
b = os.path.join(d, "g0.txt")
with open(b, "wb") as f:
    f.truncate(sz)
for i in range(1, n):
    os.link(b, os.path.join(d, "g%d.txt" % i))' "$R/bulk" 50 1073741824
T0=$(now); SEL_ENV=REIN_AFFECTED_DEADLINE_SEC=1 sel; T1=$(now)
expect_full "AT43 큰 파일 50개" '시간 상한'
if [ $((T1 - T0)) -le 5 ]; then _pass "AT43 5초 안에 반환 ($((T1 - T0))초)"; else _fail "AT43 경과 $((T1 - T0))초"; fi

echo ""
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
