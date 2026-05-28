# worker_a — scripts-bundle mirror sync (rein-policy-loader.py)

- 날짜: 2026-05-28
- 유형: fix
- 작업자: feature-builder-worker (worker_a)
- 부모: AG-2 dogfood 4-worker 병렬
- 변경 파일:
  - scripts/rein-policy-loader.py (mirror 와 byte-identical 로 sync)
- 요약: source/mirror sha256 drift 해소. plugin SSOT (mirror, 2026-05-27 v1.3.8) 를 canonical 로 채택, source (scripts/, 2026-05-19 v1.3.2 stale) 를 plugin 본문으로 갱신. `tests/scripts/test-plugin-scripts-bundle.sh` PASS (11 helpers mirrored sha256-identical).
- 근거:
  - source last-commit: 2026-05-19 (v1.3.2, 240 lines)
  - mirror last-commit: 2026-05-27 (v1.3.8, 288 lines)
  - plugin SSOT 는 사용자 ship 대상 — newer 이자 canonical
- 최종 sha256: `00f8fd7459c19d571e07923009d6c49c2161d3c4f970b2991f06719b92d10388` (양쪽 동일)
