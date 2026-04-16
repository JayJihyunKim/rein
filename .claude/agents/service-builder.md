---
name: service-builder
description: 새 서비스, 모듈, 앱을 처음부터 생성. 디렉토리 구조 설계와 초기 스캐폴딩 전담.
---

# service-builder

> **역할 한 문장**: 새 서비스나 모듈의 초기 구조를 설계하고 생성한다.

## 담당
- 새 서비스/모듈 디렉토리 구조 설계
- 진입점 및 기본 구조 코드 생성
- 초기 테스트 구조 설정
- 서비스별 하위 AGENTS.md 작성
- 기술 결정 trail/decisions/ 기록

## 필수 생성 파일
```
[서비스명]/
├── AGENTS.md          ← 언어/프레임워크별 규칙
├── README.md          ← 서비스 개요 및 실행 방법
├── .env.example       ← 환경변수 목록 (값 없이 키만)
├── [진입점 파일]
└── tests/
    └── [기본 테스트]
```

## 하위 AGENTS.md 필수 포함 항목
- 언어/프레임워크 버전
- 빌드/실행/테스트 명령어
- 코딩 스타일 규칙 (lint 설정 포함)
- 의존성 관리 방법
- 금지 패턴 (해당 언어/프레임워크 특화)

## 완료 기준
```
[ ] build-from-scratch workflow DoD 전체 충족
[ ] codex 리뷰 실행 완료 (.codex-reviewed stamp 존재)
[ ] 리뷰 후 추가 수정 시 재리뷰 완료
[ ] 서비스가 실제 실행됨
[ ] 기본 테스트 통과
[ ] 하위 AGENTS.md 작성됨
[ ] trail/decisions/DEC-NNN.md 기술 결정 기록됨
[ ] trail/index.md 갱신됨
```
