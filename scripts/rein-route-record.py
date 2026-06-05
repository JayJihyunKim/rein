#!/usr/bin/env python3
"""Router 산출물 쓰기 경로.

.rein/policy/router/{overrides,feedback-log}.yaml 에 entry 를 안전하게 append.
주석/공백을 보존하기 위해 ruamel.yaml 우선, 없으면 수동 텍스트 삽입으로 폴백.

Commands:
  override  — 사용자가 추천 조합을 수정했을 때 overrides.yaml 에 기록
  feedback  — 작업 완료 후 feedback-log.yaml 에 결과 기록

기록은 감사 로그(사람 검토용)다 — ID 정합성 검증은 호출자(LLM 라우팅 시점)
책임이며 본 스크립트는 schema/format(outcome enum + 파일 존재)만 검증한다.

--reason / --notes 제약:
  텍스트 폴백 (ruamel 미설치) 경로는 개행/CR/탭을 YAML double-quoted escape
  시퀀스 (`\\n` `\\r` `\\t`) 로 보존한다 — injection 방어 목적. 한 줄 요약 사용을
  권장하되, 여러 줄을 전달하면 리더가 escape 된 문자열로 복구해야 한다.
  ruamel 설치 시 네이티브 멀티라인 YAML 로 저장된다.
"""

from __future__ import annotations

import argparse
import os
import sys
from datetime import date
from pathlib import Path

# Default project root; overridden by --project-dir at runtime
_PROJECT_ROOT = Path(".")


def resolve_router_dir() -> Path:
    """Resolve router directory honoring env override.

    Resolution order (v1.0.1 — S21 + S25 hard cut):
      1. ``REIN_ROUTER_DIR`` env var — explicit override; mkdir -p; return it.
      2. ``.rein/policy/router/`` — canonical plugin-first location. Always
         used. Legacy ``.claude/router/`` fallback removed in v1.0.1 (no
         silent legacy acceptance).

    project.json mode defaults to ``plugin`` when absent or malformed (S21).
    The directory is created with mkdir -p before return.

    Returned ``Path`` is repo-relative (the caller's cwd anchors writes).
    """
    env_path = os.environ.get("REIN_ROUTER_DIR")
    if env_path:
        p = Path(env_path)
        p.mkdir(parents=True, exist_ok=True)
        return p
    target = Path(".rein/policy/router")
    target.mkdir(parents=True, exist_ok=True)
    return target


def _router_dir() -> Path:
    # Honor _PROJECT_ROOT (used by --project-dir tests). When the project root
    # is the cwd, resolve_router_dir() returns a relative Path; otherwise we
    # anchor to _PROJECT_ROOT explicitly to keep --project-dir test fixtures
    # working unchanged.
    if _PROJECT_ROOT == Path("."):
        return resolve_router_dir()
    cwd = Path.cwd()
    try:
        os.chdir(_PROJECT_ROOT)
        return (_PROJECT_ROOT / resolve_router_dir()).resolve()
    finally:
        os.chdir(cwd)


def _overrides_path() -> Path:
    return _router_dir() / "overrides.yaml"


def _feedback_path() -> Path:
    return _router_dir() / "feedback-log.yaml"


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
            elif v and isinstance(v[0], dict):
                # list of dicts — render each as a block mapping
                lines.append(f"{prefix}{k}:")
                for item in v:
                    first = True
                    for sk, sv in item.items():
                        item_prefix = f"{indent}    - " if first else f"{indent}      "
                        lines.append(f"{item_prefix}{sk}: {_yaml_scalar(sv)}")
                        first = False
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
    overrides = _overrides_path()
    if not overrides.exists():
        print(f"ERROR: {overrides} 가 없습니다.", file=sys.stderr)
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
    _append_entry(overrides, entry)
    print(f"recorded override → {overrides}")
    return 0


def cmd_feedback(args: argparse.Namespace) -> int:
    feedback = _feedback_path()
    if not feedback.exists():
        print(f"ERROR: {feedback} 가 없습니다.", file=sys.stderr)
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
    _append_entry(feedback, entry)
    print(f"recorded feedback → {feedback}")
    return 0


def main() -> int:
    global _PROJECT_ROOT

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project-dir",
        default=None,
        metavar="DIR",
        help="프로젝트 루트 디렉토리 (기본값: 현재 작업 디렉토리). 샌드박스 테스트 용도.",
    )
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

    args = parser.parse_args()

    if args.project_dir is not None:
        _PROJECT_ROOT = Path(args.project_dir).resolve()

    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
