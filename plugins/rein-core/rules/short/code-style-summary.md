# Code Style — quick rule

## 행동 강령

함수/메서드는 동사형 camelCase, 변수는 명사형 camelCase, 상수는 UPPER_SNAKE_CASE, 클래스/타입은 PascalCase, 파일명은 kebab-case, Boolean 은 is/has/can/should 접두사. 함수 길이 50줄 이내·파라미터 3개 이하·중첩 3단계 이하·단일 책임. 운영 코드에 console.log/print 방치 금지, TypeScript any 금지, 매직 넘버·하드코딩 URL/API 키 금지. 주석은 "왜(why)"만 — 자명한 코드 주석 금지.

> 전체 본문은 `${CLAUDE_PLUGIN_ROOT}/rules/code-style.md` 참조.
