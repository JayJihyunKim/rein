#!/usr/bin/env python3
"""skill-mcp-guide.md 자동 생성.

.claude/cache/skill-mcp-inventory.json 을 읽어 AGENTS.md §D 규정(5 카테고리 + 권장 조합 표) 구조로
.claude/cache/skill-mcp-guide.md 를 생성. 기존 파일이 있으면 USER NOTES 블록을 보존.

실패는 "pending stamp 유지 + stderr 경고" 로 처리 — 상위 gate 를 막지 않음.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

CACHE_DIR = Path(".claude/cache")
INVENTORY = CACHE_DIR / "skill-mcp-inventory.json"
GUIDE = CACHE_DIR / "skill-mcp-guide.md"
PENDING_STAMP = CACHE_DIR / ".skill-mcp-regen-pending"
MAX_BYTES = 6 * 1024

USER_NOTES_OPEN = "<!-- USER NOTES -->"
USER_NOTES_CLOSE = "<!-- /USER NOTES -->"

CATEGORIES = [
    {
        "title": "검색 / 정보 탐색",
        "hints": ["tavily", "context7", "sequential", "webfetch", "search", "research", "papers"],
    },
    {
        "title": "코드 작성 / 편집",
        "hints": ["serena", "morphllm", "magic", "codex", "feature-builder", "service-builder", "pr-review"],
    },
    {
        "title": "디버깅 / 검증",
        "hints": ["playwright", "devtools", "code-reviewer", "reviewer", "security", "debug", "verification"],
    },
    {
        "title": "작업 흐름",
        "hints": ["brainstorm", "writing-plans", "executing-plans", "tdd", "test-driven", "incidents", "repo-audit"],
    },
]

DEFAULT_COMBOS = [
    ("새 기능 추가", "feature-builder + codex + security-reviewer"),
    ("버그 수정", "feature-builder + codex"),
    ("새 서비스 생성", "service-builder + writing-plans + codex"),
    ("기술 조사", "researcher + context7"),
    ("코드 리뷰", "reviewer + codex"),
    ("보안 리뷰", "security-reviewer"),
    ("UI 디자인", "frontend-design + stitch-design + shadcn-ui"),
]


def _extract_user_notes(existing: str | None) -> str | None:
    if not existing:
        return None
    match = re.search(
        rf"{re.escape(USER_NOTES_OPEN)}(.*?){re.escape(USER_NOTES_CLOSE)}",
        existing,
        flags=re.DOTALL,
    )
    return match.group(1).strip() if match else None


def _classify(name: str, desc: str) -> int | None:
    blob = f"{name} {desc}".lower()
    for idx, cat in enumerate(CATEGORIES):
        if any(hint in blob for hint in cat["hints"]):
            return idx
    return None


_CTRL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
# 프롬프트-구조 탈출 또는 code-fence break 에 쓰이는 시퀀스. 외부 플러그인/MCP description 에서
# 흘러들어올 수 있으므로 Claude 컨텍스트에 주입되기 전에 비활성화한다.
# 긴 토큰을 먼저 매칭시켜야 prefix overlap 시 full-token 이 걸린다
# (예: `system-reminder` 가 `system` 에 먼저 매칭되어 `-reminder>` 가 잔존하는 문제 방지).
_INJECTION_RE = re.compile(
    r"(```|~~~|<!--|-->|"
    r"</?\s*(function_calls|parameter|system-reminder|system|assistant|user|human|instruction)\b)",
    re.IGNORECASE,
)


def _sanitize(s: str) -> str:
    if not s:
        return ""
    s = _CTRL_RE.sub("", s)
    s = _INJECTION_RE.sub("[scrubbed]", s)
    s = s.replace("`", "'")  # inline code-span 탈출 방지
    return s


def _short(desc: str, limit: int = 90) -> str:
    desc = _sanitize(desc).strip().replace("\n", " ")
    if len(desc) <= limit:
        return desc
    return desc[: limit - 1].rstrip() + "…"


def _render_guide(inventory: dict, user_notes: str | None) -> str:
    skills = (inventory.get("skills") or {}).get("project") or []
    skills += (inventory.get("skills") or {}).get("user") or []
    mcps = (inventory.get("mcps") or {}).get("project") or []
    mcps += (inventory.get("mcps") or {}).get("user") or []

    buckets: list[list[str]] = [[] for _ in CATEGORIES]
    misc: list[str] = []
    for s in skills:
        nm = _sanitize(s.get("name") or "")
        ds = s.get("desc") or ""
        line = f"- **{nm}** — {_short(ds)}"
        idx = _classify(nm, ds)
        if idx is None:
            misc.append(line)
        else:
            buckets[idx].append(line)

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    parts: list[str] = []
    parts.append("# Skill / MCP 활용 가이드")
    parts.append("")
    parts.append(f"> 자동 생성: {now}Z")
    parts.append("> 소스: `.claude/cache/skill-mcp-inventory.json`")
    parts.append("> 재생성: `python3 scripts/rein-generate-skill-mcp-guide.py`")
    parts.append("")

    for idx, cat in enumerate(CATEGORIES):
        parts.append(f"## {idx + 1}. {cat['title']}")
        if buckets[idx]:
            parts.extend(buckets[idx])
        else:
            parts.append("- (해당 카테고리에 등록된 항목 없음)")
        parts.append("")

    if misc:
        parts.append("## 5. 기타")
        parts.extend(misc)
        parts.append("")

    parts.append("## 기본 권장 조합")
    parts.append("")
    parts.append("| 작업 유형 | 1순위 조합 |")
    parts.append("|----------|-----------|")
    for task, combo in DEFAULT_COMBOS:
        parts.append(f"| {task} | {combo} |")
    parts.append("")

    if mcps:
        parts.append("## MCP 서버")
        for m in mcps:
            nm = _sanitize(m.get("name") or "")
            cmd = _sanitize(m.get("command") or "")
            parts.append(f"- **{nm}** — `{cmd}`")
        parts.append("")

    parts.append(USER_NOTES_OPEN)
    parts.append(user_notes or "(사용자 메모 영역 — 수동 편집 가능. 재생성 시 보존됩니다.)")
    parts.append(USER_NOTES_CLOSE)
    parts.append("")

    text = "\n".join(parts)
    # 단계적 재압축: desc 50 → 30 → 20 → bullet 제거 (카테고리당 최대 8개)
    for stage in _COMPRESSION_STAGES:
        if len(text.encode("utf-8")) <= MAX_BYTES:
            break
        text = stage(text)
    return text


def _compress_desc(limit: int):
    def _apply(text: str) -> str:
        lines = text.split("\n")
        out: list[str] = []
        for line in lines:
            if line.startswith("- **") and " — " in line:
                name_part, _, desc_part = line.partition(" — ")
                out.append(f"{name_part} — {_short(desc_part, limit=limit)}")
            else:
                out.append(line)
        return "\n".join(out)

    return _apply


def _trim_bullets(max_per_section: int):
    def _apply(text: str) -> str:
        lines = text.split("\n")
        out: list[str] = []
        count = 0
        in_section = False
        for line in lines:
            if line.startswith("## "):
                in_section = True
                count = 0
                out.append(line)
                continue
            if not in_section:
                out.append(line)
                continue
            if line.startswith("- "):
                count += 1
                if count > max_per_section:
                    continue
            out.append(line)
        return "\n".join(out)

    return _apply


_COMPRESSION_STAGES = [
    _compress_desc(50),
    _compress_desc(30),
    _compress_desc(20),
    _trim_bullets(8),
    _trim_bullets(5),
]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", default=str(INVENTORY))
    parser.add_argument("--output", default=str(GUIDE))
    parser.add_argument("--clear-pending", action="store_true", default=True)
    parser.add_argument("--keep-pending", dest="clear_pending", action="store_false")
    args = parser.parse_args()

    inv_path = Path(args.inventory)
    out_path = Path(args.output)

    if not inv_path.exists():
        print(f"ERROR: inventory not found: {inv_path}", file=sys.stderr)
        return 2
    try:
        inventory = json.loads(inv_path.read_text())
    except json.JSONDecodeError as e:
        print(f"ERROR: inventory parse failed: {e}", file=sys.stderr)
        return 2

    existing = out_path.read_text() if out_path.exists() else None
    user_notes = _extract_user_notes(existing)

    try:
        guide = _render_guide(inventory, user_notes)
    except Exception as e:
        print(f"ERROR: guide render failed: {e}", file=sys.stderr)
        return 2

    size = len(guide.encode("utf-8"))
    if size > MAX_BYTES:
        print(
            f"ERROR: guide {size}B 가 MAX_BYTES {MAX_BYTES}B 초과. stamp 유지.",
            file=sys.stderr,
        )
        return 2

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(guide)

    if args.clear_pending and PENDING_STAMP.exists():
        try:
            PENDING_STAMP.unlink()
        except OSError:
            pass

    print(f"wrote {out_path} ({size}B)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
