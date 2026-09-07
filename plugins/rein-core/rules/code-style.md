# Code Style Rules

## 행동 강령

코드는 항상 다음을 따른다: 함수/메서드는 동사형 camelCase, 변수는 명사형 camelCase, 상수는 UPPER_SNAKE_CASE, 클래스/타입은 PascalCase, 파일명은 kebab-case, Boolean 은 is/has/can/should 접두사. 함수 길이 50줄 이내·파라미터 3개 이하·중첩 3단계 이하·단일 책임. 운영 코드에 console.log/print 방치 금지, TypeScript any 금지, 매직 넘버·하드코딩 URL/API 키 금지. 주석은 지속 계약(why)만 — 회차·이력·측정수치는 trail 로, 자명한 코드 주석 금지. 자세한 규칙은 본문.

## 네이밍 규칙
- **함수/메서드**: 동사형 camelCase (`getUserById`, `calculateTotal`)
- **변수**: 명사형 camelCase (`userList`, `totalAmount`)
- **상수**: UPPER_SNAKE_CASE (`MAX_RETRY_COUNT`, `API_BASE_URL`)
- **클래스/타입**: PascalCase (`UserService`, `ApiResponse`)
- **파일명**: kebab-case (`user-service.ts`, `api-client.py`)
- **Boolean**: `is`, `has`, `can`, `should` 접두사 (`isLoading`, `hasError`)

## 함수 작성 규칙
- 단일 책임 원칙 (한 함수 = 한 가지 일)
- 함수 길이 50줄 이내 권장
- 파라미터 3개 이하 권장 (초과 시 객체로 묶기)
- 중첩 depth 3단계 이하 (early return 또는 함수 분리)

## 주석 규칙
- 주석은 **지속되는 계약(what/why)** 만 남긴다 — 설계 근거("왜 이 자료구조/알고리즘인가"), 불변식, API 계약, 엣지케이스 이유, 고정 임계값·설정값("함수는 50줄 이내", "최대 재시도 3회"). "무엇"은 코드가 설명한다.
- **회차·수리 이력·실행 결과 측정 수치는 코드 주석이 아니라 trail 로** — `trail/inbox` 작업기록 또는 `trail/index.md` 게이트 대장에 남긴다. 금지 예: 회차 서수("N차 수정", "Round N", "R1/R2/R3", "코드리뷰 3회차"), 수리 이력 서사("이전에는 X 였으나 Y 로 고침", "버그 수정:", "원래 …였다가 …로 변경"), 실행 결과 측정 수치("N줄 중 M줄", "N/M 통과", "커버리지 N%", "테스트 N건 통과", "회귀 0건 확인").
- 이 규칙은 diff 에서 **추가되거나 수정된(added/modified) 주석 줄에만** 적용된다 — 리뷰어는 규칙 위반을 이유로 해당 diff 목적과 무관한 기존 주석 전체의 일괄 청소를 요구하지 않는다.
- 이미 박제된 회차·수리이력·측정수치가 리뷰에서 지적되면 수치를 현재값으로 **정정하지 않는다** — 해당 서술을 삭제하거나 `trail/inbox` 작업기록 또는 `trail/index.md` 대장으로 이동한다(정정은 리뷰 자기증폭 편집 패턴 그 자체).
- 자명한 코드에 주석 금지
- TODO 주석: `// TODO(이름, 날짜): 내용`

## 임포트 순서
1. 표준 라이브러리
2. 외부 라이브러리
3. 내부 모듈 (절대 경로)
4. 상대 경로

## 금지 패턴
- 운영 코드에 `console.log` / `print` 방치 금지
- `any` 타입 사용 금지 (TypeScript)
- 매직 넘버/문자열 인라인 사용 금지 → 상수로 분리
- 하드코딩된 URL, API 키 금지
