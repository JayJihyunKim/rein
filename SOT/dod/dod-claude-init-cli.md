# DoD: claude-init CLI 구현

## 작업 목표
`scripts/claude-init.sh` 단일 파일에 claude-init CLI 전체 구현 (Tasks 1-7)

## 완료 기준 (Definition of Done)

- [ ] shebang + set -euo pipefail + VERSION + TEMPLATE_REPO 설정
- [ ] TMPDIR_PATH + cleanup() + EXIT trap 구현
- [ ] clone_template() 함수 - git clone --depth 1 --quiet
- [ ] COPY_TARGETS 배열 + SOT_DIRS 배열 정의
- [ ] list_copy_files(template_dir) - 파일 목록 생성 (DS_Store 제외)
- [ ] copy_file(template_dir, dest_dir, rel_path) - 부모 디렉토리 생성 포함
- [ ] scaffold_sot(dest_dir, template_dir) - .gitkeep + SOT/index.md 복사
- [ ] ALL_OVERWRITE flag + prompt_conflict() - /dev/tty 사용 인터랙티브 처리
- [ ] substitute_vars(dest_dir, project_name) - macOS/Linux sed 호환
- [ ] usage() 함수
- [ ] cmd_new(project_name) - 신규 프로젝트 생성
- [ ] cmd_merge() - 기존 프로젝트에 병합
- [ ] main() 인수 파서
- [ ] chmod +x 실행 권한 설정
- [ ] --help, --version, new (인수없음), bogus 명령어 검증 통과
