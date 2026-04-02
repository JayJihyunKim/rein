# Hook 기반 규칙 강제화 구현

## DoD
- [ ] pre-bash-guard.sh: exit 1 → exit 2 통일, 커밋 포맷 검증, .env 차단
- [ ] post-edit-lint.sh: 시크릿 스캔, console.log 감지 추가
- [ ] pre-edit-dod-gate.sh: 신규 생성, DoD 파일 없으면 소스 편집 차단
- [ ] 차단 로그: blocks.log 자동 기록 + 누적 임계값 메시지
- [ ] settings.json: 새 hook 등록, 매처에 MultiEdit 추가
- [ ] CLAUDE.md: 강제 시퀀스 섹션 추가
- [ ] 테스트: 각 hook의 차단/통과 동작 확인
