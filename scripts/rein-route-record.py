#!/usr/bin/env python3
"""Router 산출물 쓰기 경로.

.claude/router/{overrides,feedback-log,registry}.yaml 에 entry 를 안전하게 append.
주석/공백을 보존하기 위해 ruamel.yaml 우선, 없으면 수동 텍스트 삽입으로 폴백.

Commands:
  override  — 사용자가 추천 조합을 수정했을 때 overrides.yaml 에 기록
  feedback  — 작업 완료 후 feedback-log.yaml 에 결과 기록
  learn     — 누적된 피드백을 분석해 registry.yaml 의 learned_preferences 갱신

--reason / --notes 제약:
  텍스트 폴백 (ruamel 미설치) 경로는 개행/CR/탭을 YAML double-quoted escape
  시퀀스 (`\\n` `\\r` `\\t`) 로 보존한다 — injection 방어 목적. 한 줄 요약 사용을
  권장하되, 여러 줄을 전달하면 리더가 escape 된 문자열로 복구해야 한다.
  ruamel 설치 시 네이티브 멀티라인 YAML 로 저장된다.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict
from datetime import date, datetime, timezone
from pathlib import Path

ROUTER_DIR = Path(".claude/router")
OVERRIDES = ROUTER_DIR / "overrides.yaml"
FEEDBACK = ROUTER_DIR / "feedback-log.yaml"
REGISTRY = ROUTER_DIR / "registry.yaml"

LEARN_MIN_REPEAT = 3
LEARN_SUCCESS_MIN = 5
LEARN_SUCCESS_RATE = 0.9
LEARN_FAIL_MIN = 3
LEARN_FAIL_RATE = 0.5


def _load_ruamel():
    try:
        from ruamel.yaml import YAML  # type: ignore

        y = YAML()
        y.preserve_quotes = True
        y.indent(mapping=2, sequence=4, offset=2)
        return y
    except ImportError:
        return None


def _today() -> str:
    return date.today().isoformat()


def _split_ids(raw: str) -> list[str]:
    if not raw:
        return []
    return [x.strip() for x in raw.split(",") if x.strip()]


def _dod_basename(dod_path: str) -> str:
    return Path(dod_path).name


def _append_entry_ruamel(path: Path, entry: dict) -> None:
    yaml = _load_ruamel()
    assert yaml is not None
    with path.open() as f:
        data = yaml.load(f)
    if data is None:
        data = {}
    entries = data.get("entries")
    if entries is None:
        data["entries"] = [entry]
    else:
        entries.append(entry)
    with path.open("w") as f:
        yaml.dump(data, f)


def _append_entry_textual(path: Path, entry: dict) -> None:
    """Fallback: ruamel 없을 때 텍스트 append.

    entries: [] 패턴을 감지해 `entries:` 로 바꾸고 YAML 리스트 아이템으로 dump.
    entries: 항목 아래에 `- key: value` 들여쓰기로 추가.
    """
    text = path.read_text()
    lines = text.splitlines()
    out: list[str] = []
    inserted = False
    entry_yaml = _entry_to_yaml(entry)

    for i, line in enumerate(lines):
        stripped = line.strip()
        if not inserted and stripped.startswith("entries:"):
            if stripped == "entries: []":
                out.append("entries:")
                out.extend(entry_yaml)
            else:
                # entries: 가 이미 리스트 형태 (아래 - ... 있음) → 맨 뒤에 append
                out.append(line)
                # 뒤따르는 블록의 끝을 찾아 삽입
                j = i + 1
                block_end = len(lines)
                while j < len(lines):
                    nxt = lines[j]
                    if nxt and not nxt.startswith(" ") and not nxt.startswith("\t") and nxt.strip():
                        block_end = j
                        break
                    j += 1
                for k in range(i + 1, block_end):
                    out.append(lines[k])
                out.extend(entry_yaml)
                for k in range(block_end, len(lines)):
                    out.append(lines[k])
                inserted = True
                break
            inserted = True
            continue
        out.append(line)

    if not inserted:
        out.append("entries:")
        out.extend(entry_yaml)

    path.write_text("\n".join(out) + ("\n" if text.endswith("\n") else ""))


def _entry_to_yaml(entry: dict, indent: str = "  ") -> list[str]:
    """단일 dict 를 `- key: value` 형식 YAML 라인 리스트로 변환 (스칼라/리스트만 지원)."""
    lines: list[str] = []
    keys = list(entry.keys())
    for idx, k in enumerate(keys):
        v = entry[k]
        prefix = f"{indent}- " if idx == 0 else f"{indent}  "
        if isinstance(v, list):
            if not v:
                lines.append(f"{prefix}{k}: []")
            else:
                lines.append(f"{prefix}{k}:")
                for item in v:
                    lines.append(f"{indent}    - {_yaml_scalar(item)}")
        elif isinstance(v, dict):
            lines.append(f"{prefix}{k}:")
            for sk, sv in v.items():
                if isinstance(sv, list):
                    if not sv:
                        lines.append(f"{indent}    {sk}: []")
                    else:
                        lines.append(f"{indent}    {sk}:")
                        for item in sv:
                            lines.append(f"{indent}      - {_yaml_scalar(item)}")
                else:
                    lines.append(f"{indent}    {sk}: {_yaml_scalar(sv)}")
        else:
            lines.append(f"{prefix}{k}: {_yaml_scalar(v)}")
    return lines


def _yaml_scalar(v) -> str:
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    s = str(v)
    if any(ch in s for ch in [":", "#", "\n", "\r", "\t", "'", '"', "{", "}", "[", "]", ","]) or s.strip() != s:
        escaped = (
            s.replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t")
        )
        return f'"{escaped}"'
    return s


def _append_entry(path: Path, entry: dict) -> None:
    if _load_ruamel() is not None:
        _append_entry_ruamel(path, entry)
    else:
        _append_entry_textual(path, entry)


def cmd_override(args: argparse.Namespace) -> int:
    if not OVERRIDES.exists():
        print(f"ERROR: {OVERRIDES} 가 없습니다.", file=sys.stderr)
        return 2
    entry = {
        "date": _today(),
        "dod": _dod_basename(args.dod),
        "modification": {
            "removed": _split_ids(args.removed or ""),
            "added": _split_ids(args.added or ""),
        },
        "reason": args.reason or "",
    }
    _append_entry(OVERRIDES, entry)
    print(f"recorded override → {OVERRIDES}")
    return 0


def cmd_feedback(args: argparse.Namespace) -> int:
    if not FEEDBACK.exists():
        print(f"ERROR: {FEEDBACK} 가 없습니다.", file=sys.stderr)
        return 2
    if args.outcome not in ("success", "partial", "failed"):
        print("ERROR: --outcome 은 success|partial|failed 중 하나", file=sys.stderr)
        return 2
    entry = {
        "date": _today(),
        "dod": _dod_basename(args.dod),
        "recommended": {
            "agent": args.agent or "",
            "skills": _split_ids(args.skills or ""),
            "mcps": _split_ids(args.mcps or ""),
        },
        "outcome": args.outcome,
        "notes": args.notes or "",
    }
    _append_entry(FEEDBACK, entry)
    print(f"recorded feedback → {FEEDBACK}")
    return 0


def cmd_learn(_: argparse.Namespace) -> int:
    """feedback + overrides 이력을 분석해 registry.yaml learned_preferences 갱신."""
    if not FEEDBACK.exists() or not OVERRIDES.exists() or not REGISTRY.exists():
        print("ERROR: router yaml 파일 누락", file=sys.stderr)
        return 2

    yaml = _load_ruamel()
    if yaml is None:
        print("WARNING: ruamel.yaml 없음 — learn 은 ruamel 필수. skipping.", file=sys.stderr)
        return 0

    with FEEDBACK.open() as f:
        fb = yaml.load(f) or {}
    with OVERRIDES.open() as f:
        ov = yaml.load(f) or {}
    with REGISTRY.open() as f:
        reg = yaml.load(f) or {}

    prefs: dict[str, dict] = {}

    add_counter: Counter[str] = Counter()
    rem_counter: Counter[str] = Counter()
    for entry in ov.get("entries") or []:
        mod = entry.get("modification") or {}
        for added in mod.get("added") or []:
            add_counter[added] += 1
        for removed in mod.get("removed") or []:
            rem_counter[removed] += 1

    for item_id, n in add_counter.items():
        if n >= LEARN_MIN_REPEAT:
            prefs.setdefault(item_id, {"id": item_id, "boost": 0.0, "context": [], "last_updated": _today()})
            prefs[item_id]["boost"] += 0.2
            prefs[item_id]["context"].append(f"override added {n}x")

    for item_id, n in rem_counter.items():
        if n >= LEARN_MIN_REPEAT:
            prefs.setdefault(item_id, {"id": item_id, "boost": 0.0, "context": [], "last_updated": _today()})
            prefs[item_id]["boost"] -= 0.2
            prefs[item_id]["context"].append(f"override removed {n}x")

    combo_stats: defaultdict[str, list[str]] = defaultdict(list)
    for entry in fb.get("entries") or []:
        rec = entry.get("recommended") or {}
        ids = [rec.get("agent") or ""] + (rec.get("skills") or []) + (rec.get("mcps") or [])
        for item_id in ids:
            if not item_id:
                continue
            combo_stats[item_id].append(entry.get("outcome") or "")

    for item_id, outcomes in combo_stats.items():
        n = len(outcomes)
        if n == 0:
            continue
        success = sum(1 for o in outcomes if o == "success")
        fail = sum(1 for o in outcomes if o == "failed")
        rate_success = success / n
        rate_fail = fail / n
        if n >= LEARN_SUCCESS_MIN and rate_success >= LEARN_SUCCESS_RATE:
            prefs.setdefault(item_id, {"id": item_id, "boost": 0.0, "context": [], "last_updated": _today()})
            prefs[item_id]["boost"] += 0.2
            prefs[item_id]["context"].append(f"success rate {rate_success:.0%} ({n} runs)")
        if n >= LEARN_FAIL_MIN and rate_fail >= LEARN_FAIL_RATE:
            prefs.setdefault(item_id, {"id": item_id, "boost": 0.0, "context": [], "last_updated": _today()})
            prefs[item_id]["boost"] -= 0.2
            prefs[item_id]["context"].append(f"fail rate {rate_fail:.0%} ({n} runs)")

    if not prefs:
        print("no learned preferences updated (insufficient data)")
        return 0

    reg["learned_preferences"] = [
        {
            "id": p["id"],
            "boost": round(p["boost"], 2),
            "context": "; ".join(p["context"]),
            "last_updated": p["last_updated"],
        }
        for p in prefs.values()
    ]
    with REGISTRY.open("w") as f:
        yaml.dump(reg, f)
    print(f"updated learned_preferences ({len(prefs)} items) → {REGISTRY}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_ov = sub.add_parser("override", help="사용자 수정 이력 append")
    p_ov.add_argument("--dod", required=True)
    p_ov.add_argument("--removed", default="")
    p_ov.add_argument("--added", default="")
    p_ov.add_argument("--reason", default="")
    p_ov.set_defaults(func=cmd_override)

    p_fb = sub.add_parser("feedback", help="작업 완료 피드백 append")
    p_fb.add_argument("--dod", required=True)
    p_fb.add_argument("--agent", default="")
    p_fb.add_argument("--skills", default="")
    p_fb.add_argument("--mcps", default="")
    p_fb.add_argument("--outcome", required=True)
    p_fb.add_argument("--notes", default="")
    p_fb.set_defaults(func=cmd_feedback)

    p_ln = sub.add_parser("learn", help="registry.learned_preferences 재계산")
    p_ln.set_defaults(func=cmd_learn)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
