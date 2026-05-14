# Legacy DoD Archive

> 날짜 규칙 도입 이전의 DoD 파일을 자동 수집한 아카이브.

---
## dod-athlete-detail-ux-audit.md (mtime: 2026-04-10)
# DoD: 선수 상세페이지 UX/UI 문제점 분석 문서화

## 완료 기준
- [ ] Stitch 디자인 분석 결과 정리
- [ ] Magic MCP 참고 패턴 비교 분석 정리
- [ ] 우선순위별 문제점 분류
- [ ] docs/superpowers/specs/2026-04-06/ 폴더에 저장

## 유형
docs (분석 문서 작업)

---
## dod-athlete-detail-ux-audit.md (mtime: 2026-04-10)
# DoD: 선수 상세페이지 UX/UI 문제점 분석 문서화

## 완료 기준
- [ ] Stitch 디자인 분석 결과 정리
- [ ] Magic MCP 참고 패턴 비교 분석 정리
- [ ] 우선순위별 문제점 분류
- [ ] docs/superpowers/specs/2026-04-06/ 폴더에 저장

## 유형
docs (분석 문서 작업)

---
## dod-claude-init-script-skeleton.md (mtime: 2026-04-10)
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

---
## dod-claude-init-script-skeleton.md (mtime: 2026-04-10)
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

---
## dod-connect-athletes-to-coach.md (mtime: 2026-04-10)
# DoD: coach-test@test.com에 선수 연결

## 완료 기준
- [ ] 로컬 Supabase DB에서 선수 목록 확인
- [ ] coach-test@test.com (UserID 2300)에 모든 선수 연결
- [ ] b2b_coach_athlete_connections 테이블에 approved/active 상태로 삽입
- [ ] 연결 결과 확인 쿼리 실행

---
## dod-connect-athletes-to-coach.md (mtime: 2026-04-10)
# DoD: coach-test@test.com에 선수 연결

## 완료 기준
- [ ] 로컬 Supabase DB에서 선수 목록 확인
- [ ] coach-test@test.com (UserID 2300)에 모든 선수 연결
- [ ] b2b_coach_athlete_connections 테이블에 approved/active 상태로 삽입
- [ ] 연결 결과 확인 쿼리 실행

---
## dod-project-naming.md (mtime: 2026-04-10)
# DoD: 프로젝트 네이밍 — Rein

## 완료 기준
- [ ] 디자인 스펙 문서 작성 (`docs/superpowers/specs/`)
- [ ] 사용자 스펙 리뷰 완료
- [ ] 구현 플랜 작성 (writing-plans 스킬 호출)

## 변경 대상
- `docs/superpowers/specs/2026-04-09-project-naming-design.md` (신규)

## 범위 제한
- 네이밍 디자인 문서만 작성
- 실제 리네이밍(코드 변경)은 별도 작업으로 분리

---
## dod-project-naming.md (mtime: 2026-04-10)
# DoD: 프로젝트 네이밍 — Rein

## 완료 기준
- [ ] 디자인 스펙 문서 작성 (`docs/superpowers/specs/`)
- [ ] 사용자 스펙 리뷰 완료
- [ ] 구현 플랜 작성 (writing-plans 스킬 호출)

## 변경 대상
- `docs/superpowers/specs/2026-04-09-project-naming-design.md` (신규)

## 범위 제한
- 네이밍 디자인 문서만 작성
- 실제 리네이밍(코드 변경)은 별도 작업으로 분리

---
## dod-seed-athlete-test-data.md (mtime: 2026-04-10)
# DoD: Taeyang Kim 테스트 데이터 삽입

## 완료 기준
- [ ] ExerciseRecord: 최근 2주간 운동 기록 10건+
- [ ] b2b_program_assignments: 활성 프로그램 1건
- [ ] b2b_coach_feedback: 코치 피드백 3~5건
- [ ] UI에서 선수 상세 페이지가 데이터로 채워져 보이는 것

---
## dod-seed-athlete-test-data.md (mtime: 2026-04-10)
# DoD: Taeyang Kim 테스트 데이터 삽입

## 완료 기준
- [ ] ExerciseRecord: 최근 2주간 운동 기록 10건+
- [ ] b2b_program_assignments: 활성 프로그램 1건
- [ ] b2b_coach_feedback: 코치 피드백 3~5건
- [ ] UI에서 선수 상세 페이지가 데이터로 채워져 보이는 것

---
## dod-test-harness.md (mtime: 2026-04-13)
# DoD: Task 1 — 테스트 하네스 작성

## 목표
DoD 회전 훅을 테스트하기 위한 샌드박스 하네스 스크립트 생성.

## 요구사항
1. 파일 위치: `tests/hooks/lib/test-harness.sh`
2. 내용: 정확한 사양에 따른 샌드박스 함수들
3. 실행 권한: chmod +x 설정
4. 문법 검사: bash -n 통과
5. 연기 테스트: sandbox_setup/teardown 동작 확인
6. 커밋: git commit with correct message format

## 변경 파일
- tests/hooks/lib/test-harness.sh (생성)

## 성공 기준
- ✓ 파일 생성 완료
- ✓ 실행 권한 설정 완료
- ✓ 문법 검사 통과
- ✓ 연기 테스트 통과
- ✓ Self-review 완료
- ✓ git commit 성공

---
## dod-test-harness.md (mtime: 2026-04-13)
# DoD: Task 1 — 테스트 하네스 작성

## 목표
DoD 회전 훅을 테스트하기 위한 샌드박스 하네스 스크립트 생성.

## 요구사항
1. 파일 위치: `tests/hooks/lib/test-harness.sh`
2. 내용: 정확한 사양에 따른 샌드박스 함수들
3. 실행 권한: chmod +x 설정
4. 문법 검사: bash -n 통과
5. 연기 테스트: sandbox_setup/teardown 동작 확인
6. 커밋: git commit with correct message format

## 변경 파일
- tests/hooks/lib/test-harness.sh (생성)

## 성공 기준
- ✓ 파일 생성 완료
- ✓ 실행 권한 설정 완료
- ✓ 문법 검사 통과
- ✓ 연기 테스트 통과
- ✓ Self-review 완료
- ✓ git commit 성공

---
## dod-tracme-athlete-detail-spec.md (mtime: 2026-04-10)
# DoD: tracme 선수 상세페이지 기능정의서

## 완료 기준
- [ ] 현재 기능 42개 전수 문서화 (디자인 비의존적)
- [ ] Supabase 테이블/RPC 매핑 완료
- [ ] Stitch 프롬프트 포함
- [ ] 사용자 승인

## 유형
docs (문서 작업 — tracme-solution 레포에 작성)

---
## dod-tracme-athlete-detail-spec.md (mtime: 2026-04-10)
# DoD: tracme 선수 상세페이지 기능정의서

## 완료 기준
- [ ] 현재 기능 42개 전수 문서화 (디자인 비의존적)
- [ ] Supabase 테이블/RPC 매핑 완료
- [ ] Stitch 프롬프트 포함
- [ ] 사용자 승인

## 유형
docs (문서 작업 — tracme-solution 레포에 작성)

