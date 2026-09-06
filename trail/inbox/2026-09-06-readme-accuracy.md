# 2026-09-05 — README 두 벌 사실 정정 6건 + 마켓플레이스·플러그인 소개글 (문서, 버전 불변)

DoD `trail/dod/dod-2026-09-04-readme-accuracy.md`. dev 커밋 (진행 중), main (진행 중)(문서·매니페스트만 선별 반영, 태그 없음), 공개 미러 (진행 중).

## 정정 내용 (EN/KO 1:1)
1. "리뷰 전엔 commit·테스트 차단" → 리뷰 게이트는 커밋만 차단, 테스트 실행은 막지 않음(TDD).
2. `lean` 프로파일 훅 키 `post-write-*` 오기 → `post-edit-spec-review-gate` / `post-edit-dod-routing-check`.
3. 내장 페르소나 2종 → 3종(마르코 / 제니 / 최행배).
4. "Rein 은 `.gitignore` 를 자동 편집하지 않음" → 자기 런타임 상태 파일 무시 항목만 추가(기존 프로젝트는 세션 시작 때 보강), 그 외 불변. `trail/`·`.claude/cache/` 무시는 사용자 선택.
5. 저장소 트리: `.rein/policy/persona.yaml`, `.claude/security/profile.yaml`(기본 standard) 추가; `.claude/settings.json` 핀 줄 제거 → 활성 기록은 설치 scope 에 따라 Claude Code 가 자기 설정에 남김(기본 user scope → `~/.claude/settings.json`), Rein 은 쓰지 않음.
6. Contributing 의 `AGENTS.md` 링크(공개 저장소에서 strip 되어 404) → `docs/architecture.md` + `docs/policy-model.md`.
- 소개글: plugin.json `description` + marketplace.json 항목·마켓 설명을 README 첫 줄에서 파생한 한 문장으로("Guide autonomy, ship quality — … plan, leave evidence, and pass review before code lands").

## 검증
- 플러그인 검증·드리프트 검사 통과, 버전 2.0.3 불변, README 링크 경로 전부 공개 트리에 존재, EN 한글 잔존 0(표시 이름 제외), 섹션 14/14.
- codex 3회차(1회차 Medium 2: 설치 scope 별 설정 파일 위치·"테스트 절대 안 막힘" 과장 / 2회차 Medium 2: DoD 문구·소개글 동사 불일치) → 3회차 진행 중(분리 실행).
- 함정: codex 3회차가 하네스 10분 상한에 잘려 무결과(회차 미소모) → 래퍼를 `nohup` 으로 분리 실행 + 대기 루프로 해결. 리뷰 호출은 앞으로 분리 실행 기본.

## 후속
- GitHub Releases 백필 완료(v1.6.3, v2.0.0~v2.0.3; v2.0.3 Latest) — README 배지가 v2.0.3 표시. 태그 push 만으로는 Release 가 생기지 않으니 배포 절차에 `gh release create` 단계를 넣을 것(다음 배포 DoD 항목).
