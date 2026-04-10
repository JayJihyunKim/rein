# DoD: claude-init Script Skeleton + Argument Parsing

- 날짜: 2026-04-03
- 유형: feat

## 완료 기준

- [ ] `scripts/claude-init.sh` 파일 생성
- [ ] 스크립트에 실행 권한 부여 (`chmod +x`)
- [ ] `--help` 출력 시 usage 텍스트 표시
- [ ] `--version` 출력 시 `claude-init 0.1.0` 표시
- [ ] `new` 인수 없이 호출 시 에러 메시지 + usage 출력, exit 1
- [ ] `bogus` 명령어 호출 시 에러 메시지 + usage 출력, exit 1
- [ ] `CLAUDE_TEMPLATE_REPO` 환경 변수로 template repo URL override 가능
