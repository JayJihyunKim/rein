# services/api/AGENTS.md — Python API 규칙

> 이 파일은 services/api/ 디렉토리 작업 시 자동으로 로드된다.
> 전역 AGENTS.md를 상속하며, 여기서는 Python/FastAPI 특화 규칙만 추가한다.

---

## 기술 스택

- **Language**: Python 3.12+
- **Framework**: FastAPI
- **ORM**: SQLAlchemy 2.x (async)
- **Validation**: Pydantic v2
- **Testing**: pytest + httpx
- **Lint**: Ruff + mypy

---

## 실행 명령어

```bash
uvicorn main:app --reload      # 개발 서버
pytest                         # 테스트 실행
ruff check . --fix             # Lint 수정
ruff format .                  # 코드 포맷
mypy .                         # 타입 검사
```

---

## 디렉토리 구조

```
services/api/
├── app/
│   ├── routers/       # API 라우터 (기능별 분리)
│   ├── models/        # SQLAlchemy 모델
│   ├── schemas/       # Pydantic 스키마 (request/response)
│   ├── services/      # 비즈니스 로직
│   ├── repositories/  # DB 접근 계층
│   └── core/          # 설정, 의존성, 미들웨어
├── tests/
│   ├── unit/
│   └── integration/
├── alembic/           # DB 마이그레이션
└── main.py
```

---

## Python 코딩 규칙

- 타입 힌트 필수 (모든 함수 파라미터 및 반환값)
- async/await 일관 사용 (sync 함수와 혼용 금지)
- Pydantic 모델로 모든 외부 입력 검증
- 의존성 주입은 FastAPI `Depends()` 활용
- DB 쿼리는 Repository 계층에서만 (라우터/서비스에서 직접 쿼리 금지)

---

## API 규칙

- RESTful 컨벤션 준수 (GET/POST/PUT/DELETE)
- 응답은 항상 Pydantic 스키마 사용
- 에러 응답: `HTTPException` + 표준 에러 포맷
- API 버전: `/api/v1/` prefix
- 모든 엔드포인트에 OpenAPI 문서 주석 포함

---

## 금지 패턴

- 직접 SQL 문자열 조합 금지 → SQLAlchemy ORM 또는 파라미터화 쿼리
- 라우터에 비즈니스 로직 작성 금지 → services/ 계층으로 분리
- 전역 변수로 상태 관리 금지
- `print()` 디버그 코드 방치 금지 → `logging` 모듈 사용
