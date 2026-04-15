#!/usr/bin/env python3
"""Skill/MCP 인벤토리 스캔. Called from session-start-load-sot.sh."""
import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home()
USER_SKILL_PATHS = [
    HOME / ".claude/plugins/cache",  # plugins/cache/<plugin>/<version>/skills/<name>/SKILL.md
    HOME / ".claude/skills",          # skills/<name>/SKILL.md
]
USER_MCP_CONFIG = HOME / ".claude.json"


def utcnow():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def parse_skill_md(path: Path) -> dict:
    """SKILL.md 의 frontmatter 에서 name, description 추출.

    frontmatter 첫 블록에서 단일 라인 name: / description: 만 추출.
    multiline 값(indented continuation lines)은 무시한다.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except Exception:
        return {}
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n", text, re.DOTALL)
    if not m:
        return {"name": path.parent.name}
    fm = {}
    for line in m.group(1).splitlines():
        # 들여쓰기로 시작하는 continuation line 은 무시
        if line.startswith(" ") or line.startswith("\t"):
            continue
        if ":" not in line:
            continue
        k, _, v = line.partition(":")
        k = k.strip()
        v = v.strip().strip('"').strip("'")
        # 빈 값이 아닌 경우만 저장
        if v:
            fm[k] = v
    return {
        "name": fm.get("name", path.parent.name),
        "desc": fm.get("description", "")[:200],
    }


def scan_skills(root: Path) -> list:
    """고정 패턴 + 깊이 제한으로 SKILL.md 탐색 (rglob 폭주 방지).

    지원 패턴:
    - <root>/<name>/SKILL.md              (skills/<name>/SKILL.md)
    - <root>/<a>/<b>/skills/<name>/SKILL.md  (plugins/cache/<plugin>/<ver>/skills/<name>/SKILL.md)
    """
    if not root.exists():
        return []
    results = []
    seen = set()
    patterns = [
        "*/SKILL.md",                        # skills/<name>/SKILL.md
        "*/*/skills/*/SKILL.md",             # plugins/cache/<plugin>/<version>/skills/<name>/SKILL.md
    ]
    for pat in patterns:
        for skill_md in root.glob(pat):
            if skill_md in seen:
                continue
            seen.add(skill_md)
            meta = parse_skill_md(skill_md)
            if meta and meta.get("name"):
                results.append(meta)
    # name 중복 제거 + 정렬 (canonical hash 안정성)
    by_name = {}
    for m in results:
        by_name[m["name"]] = m
    return sorted(by_name.values(), key=lambda x: x["name"])


def normalize_mcp_servers(data) -> dict:
    """다양한 형태의 mcpServers 입력을 dict[name -> dict] 로 정규화."""
    if not isinstance(data, dict):
        return {}
    servers = data.get("mcpServers")
    if not isinstance(servers, dict):
        return {}
    result = {}
    for name, cfg in servers.items():
        if not isinstance(name, str):
            continue
        if not isinstance(cfg, dict):
            continue
        result[name] = cfg
    return result


def scan_mcps_from_json(config_path: Path) -> list:
    """JSON 파일의 mcpServers 키에서 MCP 목록 추출 (타입 검사 포함)."""
    if not config_path.exists():
        return []
    try:
        data = json.loads(config_path.read_text())
    except Exception:
        return []
    servers = normalize_mcp_servers(data)
    mcps = []
    for name, cfg in servers.items():
        cmd = cfg.get("command", "") if isinstance(cfg.get("command"), str) else ""
        args = cfg.get("args") if isinstance(cfg.get("args"), list) else []
        if args:
            cmd = f"{cmd} {' '.join(str(a) for a in args)}"
        mcps.append({"name": name, "command": cmd[:200]})
    # 이름 중복 제거 (canonical hash 안정성)
    by_name = {}
    for m in mcps:
        by_name[m["name"]] = m
    return sorted(by_name.values(), key=lambda x: x["name"])


def canonicalize_inventory(inventory: dict) -> dict:
    """list 안의 dict 들을 name 기준 정렬 + 중복 제거 후 안정적인 형태 반환."""
    out = {"skills": {}, "mcps": {}}
    for scope in ("user", "project"):
        # skills: name 기준 정렬, name+desc 만 남김
        items = inventory.get("skills", {}).get(scope, [])
        items = [{"name": i.get("name", ""), "desc": i.get("desc", "")} for i in items if isinstance(i, dict)]
        items = sorted({i["name"]: i for i in items}.values(), key=lambda x: x["name"])
        out["skills"][scope] = items
        # mcps: name 기준 정렬
        items = inventory.get("mcps", {}).get(scope, [])
        items = [{"name": i.get("name", ""), "command": i.get("command", "")} for i in items if isinstance(i, dict)]
        items = sorted({i["name"]: i for i in items}.values(), key=lambda x: x["name"])
        out["mcps"][scope] = items
    return out


def compute_hash(inventory: dict) -> str:
    canonical = json.dumps(canonicalize_inventory(inventory), sort_keys=True, ensure_ascii=False)
    return hashlib.sha1(canonical.encode("utf-8")).hexdigest()[:16]


def collect_inventory(project_dir: Path) -> dict:
    inv = {
        "skills": {
            "user": [],
            "project": [],
        },
        "mcps": {
            "user": [],
            "project": [],
        },
    }
    # User skills — 여러 경로에서 수집, name 기준 중복 제거
    user_skill_map = {}
    for path in USER_SKILL_PATHS:
        for item in scan_skills(path):
            user_skill_map[item["name"]] = item
    inv["skills"]["user"] = sorted(user_skill_map.values(), key=lambda x: x["name"])

    # Project skills
    inv["skills"]["project"] = scan_skills(project_dir / ".claude/skills")

    # User MCPs
    inv["mcps"]["user"] = scan_mcps_from_json(USER_MCP_CONFIG)

    # Project MCPs (먼저 .claude/mcp.json, 없으면 .claude/settings.json 의 mcpServers)
    proj_mcp = project_dir / ".claude/mcp.json"
    if proj_mcp.exists():
        inv["mcps"]["project"] = scan_mcps_from_json(proj_mcp)
    else:
        inv["mcps"]["project"] = scan_mcps_from_json(project_dir / ".claude/settings.json")
    return inv


def main():
    parser = argparse.ArgumentParser(description="Skill/MCP 인벤토리 스캔")
    parser.add_argument("--project-dir", default=os.environ.get("REIN_PROJECT_DIR", "."))
    parser.add_argument("--scan", action="store_true",
                        help="인벤토리 스캔, 변경 감지, JSON 결과 출력")
    args = parser.parse_args()
    project = Path(args.project_dir).resolve()

    cache_dir = project / ".claude/cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    inventory_file = cache_dir / "skill-mcp-inventory.json"
    guide_file = cache_dir / "skill-mcp-guide.md"

    inv = collect_inventory(project)
    new_hash = compute_hash(inv)

    old_hash = ""
    if inventory_file.exists():
        try:
            old_data = json.loads(inventory_file.read_text())
            old_hash = old_data.get("hash", "")
        except Exception:
            pass

    needs_regen = (new_hash != old_hash) or (not guide_file.exists())

    # 결과 저장 (atomic write)
    inv_data = {
        "hash": new_hash,
        "scanned_at": utcnow(),
        **inv,
    }
    import tempfile
    fd, tmp = tempfile.mkstemp(dir=str(cache_dir), prefix=".tmp.")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(inv_data, f, indent=2, ensure_ascii=False)
        os.replace(tmp, str(inventory_file))
    except Exception:
        # 실패 시 임시 파일 정리
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise

    # 결과 stdout 으로 (훅이 파싱)
    print(json.dumps({
        "needs_regen": needs_regen,
        "old_hash": old_hash,
        "new_hash": new_hash,
        "skill_count": len(inv["skills"]["user"]) + len(inv["skills"]["project"]),
        "mcp_count": len(inv["mcps"]["user"]) + len(inv["mcps"]["project"]),
        "guide_exists": guide_file.exists(),
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
