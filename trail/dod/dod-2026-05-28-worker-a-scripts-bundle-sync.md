# DoD — worker_a scripts-bundle mirror sync (rein-policy-loader.py)

- 날짜: 2026-05-28
- 유형: fix
- 작업자: feature-builder-worker (worker_a)
- 부모 작업: AG-2 dogfood 4-worker 병렬

## 배경

`tests/scripts/test-plugin-scripts-bundle.sh` FAIL — `rein-policy-loader.py` 의 source/mirror sha256 drift (68 line diff).

- source: `scripts/rein-policy-loader.py` — last commit 2026-05-19 (`7795193` v1.3.2), 240 lines, sha256 `4a2f3b87...`
- mirror: `plugins/rein-core/scripts/rein-policy-loader.py` — last commit 2026-05-27 (`bd3364b` v1.3.8), 288 lines, sha256 `00f8fd74...`

mirror 가 newer (8일 더 최근). plugin SSOT 는 사용자 ship 대상이므로 canonical. source 를 mirror 로 sync 한다.

## 변경 파일

- scripts/rein-policy-loader.py

## 범위 연결

- covers: AG-2 dogfood worker_a

## 완료 기준

- [ ] source `scripts/rein-policy-loader.py` 가 mirror `plugins/rein-core/scripts/rein-policy-loader.py` 와 byte-identical
- [ ] 두 파일 sha256 동일 확인 (`shasum -a 256` 출력 비교)
- [ ] `bash tests/scripts/test-plugin-scripts-bundle.sh` PASS
- [ ] worker_scope 밖 파일 수정 없음
- [ ] worker worktree 안에서 commit 완료

## 라우팅 추천

```yaml
agent: feature-builder-worker
skills: []
mcps: []
rationale: mechanical sha256 sync — parent session 이 이미 dispatch. routing 결정 부모 책임
approved_by_user: true
```
