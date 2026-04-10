# apps/web/AGENTS.md — Next.js / TypeScript 규칙

> 이 파일은 apps/web/ 디렉토리 작업 시 자동으로 로드된다.
> 전역 AGENTS.md를 상속하며, 여기서는 Next.js/TypeScript 특화 규칙만 추가한다.

---

## 기술 스택

- **Framework**: Next.js 15 (App Router)
- **Language**: TypeScript 5.x
- **Styling**: Tailwind CSS + shadcn/ui
- **State**: Zustand (전역) / React Query (서버 상태)
- **Testing**: Vitest + Testing Library
- **Lint**: ESLint + Prettier

---

## 실행 명령어

```bash
npm run dev        # 개발 서버
npm run build      # 프로덕션 빌드
npm run test       # 테스트 실행
npm run lint       # ESLint 실행
npm run type-check # TypeScript 타입 검사
```

---

## 디렉토리 구조

```
apps/web/
├── app/           # Next.js App Router 페이지
├── components/    # 재사용 가능한 UI 컴포넌트
│   ├── ui/        # shadcn/ui 기반 기본 컴포넌트
│   └── [feature]/ # 기능별 컴포넌트
├── hooks/         # 커스텀 React hooks
├── lib/           # 유틸리티 함수
├── store/         # Zustand 상태 관리
└── types/         # TypeScript 타입 정의
```

---

## TypeScript 규칙

- `any` 타입 사용 금지 — `unknown` 또는 구체 타입 사용
- 컴포넌트 props는 반드시 interface로 정의
- API 응답 타입은 `types/` 폴더에 중앙 관리
- `as` 타입 단언은 최소화 (불가피한 경우 주석으로 이유 설명)

---

## 컴포넌트 규칙

- 서버 컴포넌트와 클라이언트 컴포넌트를 명확히 분리
- 클라이언트 컴포넌트는 파일 상단에 `'use client'` 필수
- 컴포넌트 파일명: PascalCase (`UserCard.tsx`)
- 한 파일에 한 컴포넌트 (default export)
- Props 인터페이스명: `[컴포넌트명]Props`

---

## 금지 패턴

- `pages/` 디렉토리 사용 금지 (App Router 전용)
- `useEffect`로 데이터 패칭 금지 → React Query 사용
- 인라인 스타일 (`style={{}}`) 금지 → Tailwind 클래스 사용
- `console.log` 운영 코드 방치 금지
