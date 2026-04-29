# Code Style Rules

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
- 주석은 **"왜(why)"**를 설명한다 — "무엇"은 코드가 설명
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
