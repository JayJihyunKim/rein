# 주입 규칙 언어 중립화 + 사용자 언어 추종 정책

- 날짜: 2026-05-29
- 유형: fix (user-facing)
- 변경 파일:
  - plugins/rein-core/rules/short/answer-only-summary.md (KR→EN 번역)
  - plugins/rein-core/rules/short/response-tone-summary.md (KR→EN 번역 + 출력 언어 정책 추가)
  - plugins/rein-core/rules/response-tone.md (신규 `## Output Language` 섹션)
  - tests/hooks/test-user-prompt-submit-rules.sh (마커 KR→EN + 신규 단언)
  - tests/hooks/test-user-prompt-submit-bootstrap-advisory.sh (마커 KR→EN)
- 요약: 매 턴 주입되던 한국어 짧은 규칙 2개가 영어 사용자 출력을 한국어로 soft-anchor 하던 문제. codex Mode B 2라운드(Verdict C)로 "영어 한 줄 추가" 초안을 기각하고, 상시 한국어 닻 자체(per-turn short summary)를 영어로 번역 + 출력 언어 정책(상위 시스템/하네스 지시 우선 → 사용자 요청 → 최신 메시지 주 언어, repo/규칙/trail 언어로 추론 금지)을 톤 요약 맨 끝과 전체 톤 규칙에 추가. settings.json 의 명시적 언어 설정은 상위 우선순위라 그대로 보존(메인테이너 한국어 영향 없음). 전체본 한국어 유지(비용+메인테이너 선호). 크기 한도·행동 강령 첫 헤더 제약 보존. 전체 훅/스크립트 스위트 통과, codex Mode A PASS(차단0) + security standard 통과(차단0). dev 미커밋(사용자 push 승인 대기).
