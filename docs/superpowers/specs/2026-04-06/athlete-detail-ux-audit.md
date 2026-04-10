# 선수 상세페이지 UX/UI 문제점 분석

> 대상: TracMe `/dashboard/athletes/[id]` (636줄 단일 컴포넌트)
> 분석 도구: Stitch Design Skill + Magic MCP (21st.dev)
> 분석일: 2026-04-06

---

## 목차

1. [Stitch 디자인 분석](#1-stitch-디자인-분석)
2. [Magic MCP 참고 패턴 비교](#2-magic-mcp-참고-패턴-비교)
3. [종합 문제점 우선순위](#3-종합-문제점-우선순위)
4. [개선 방향 제안](#4-개선-방향-제안)

---

## 1. Stitch 디자인 분석

현재 코드, 기능 스펙(42개 기능), 디자인 시스템(`.stitch/DESIGN.md`), Stitch "Precision Observer" 스크린샷을 기반으로 분석.

### 1.1 정보 계층 (Information Hierarchy)

| 문제 | 심각도 | 설명 |
|------|--------|------|
| KPI 가독성 부족 | 🔴 높음 | 프로필 헤더 KPI 3개(달성률, 운동일수, 칼로리)가 프로필 정보와 같은 시각적 무게로 배치됨. 코치가 가장 먼저 봐야 할 핵심 수치인데 시선을 끌지 못함 |
| 세션 분석 조건부 렌더링 | 🔴 높음 | 코치의 핵심 워크플로우인 세션 분석이 선택해야만 보임. 페이지 로드 시 자동 선택되나 above the fold에 없을 수 있음 |
| AI 인사이트 매몰 | 🟡 중간 | `WeeklyAISummary`가 차트 아래 배치되어 코치가 놓치기 쉬움. AI 전문 분석이 부차적 콘텐츠로 취급됨 |

### 1.2 레이아웃 & 공간 효율

| 문제 | 심각도 | 설명 |
|------|--------|------|
| 과도한 세로 스크롤 | 🔴 높음 | Zone 1(프로필) → Zone 2(차트 8:4) → Zone 3(세션 분석) → Zone 4(운동 기록)이 모두 풀와이드 세로 스택. "Precision Observer" 컨셉(Datadog/Grafana 스타일 고밀도)과 정반대 |
| 차트 영역 비효율 | 🟡 중간 | 주간 오버뷰 차트 높이 240px + 카드 패딩 + 헤더 ≈ 350px. 바디 밸런스도 별도 카드. 데스크톱에서 화면 절반을 차트 2개가 차지 |
| 운동 기록 밀도 부족 | 🟡 중간 | 6건 기본 표시 + "더 보기" 페이지네이션으로 47건 전체 탐색이 번거로움 |

### 1.3 인터랙션 디자인

| 문제 | 심각도 | 설명 |
|------|--------|------|
| 선택 모델 혼란 | 🔴 높음 | 차트 바 클릭과 운동 기록 클릭이 상호 배타적이라는 것을 코치가 인지하기 어려움. 시각적 피드백 부족 — 어디를 클릭해서 세션이 바뀌었는지 불명확 |
| 피드백 채팅 접근성 | 🟡 중간 | FloatingChatPanel FAB 버튼은 좋으나, 특정 세션에 대한 피드백을 보내려면 해당 세션을 먼저 선택해야 함. 운동 기록 카드에서 바로 피드백으로 가는 동선 없음 |
| 프로그램 진행률 인터랙션 부재 | 🟢 낮음 | 진행률 %만 표시, 클릭해도 아무 일 없음. 프로그램 상세 보기로의 동선 직관적이지 않음 |

### 1.4 디자인 시스템 위반

| 문제 | 심각도 | 설명 |
|------|--------|------|
| 하드코딩 색상값 | 🟡 중간 | `page.tsx`에 `text-[#343C6A]`, `bg-[#2D60FF]`, `text-[#4D667F]` 등 hex값 직접 사용. DESIGN.md의 `--foreground`, `--primary`, `--muted-foreground` 토큰 미사용 |
| "No-Line" 규칙 위반 | 🟡 중간 | Precision Observer DESIGN.md의 "No-Line Rule"(1px border 금지)인데, 주간 네비게이션 버튼에 `border border-[#E5E8F0]` 사용 |
| border-radius 불일치 | 🟢 낮음 | Precision Observer는 `sm`(4px) radius 권장, shadcn 기본 `rounded-xl`(0.8rem) 혼재 사용 |

### 1.5 컴포넌트 수준 문제

| 컴포넌트 | 문제 |
|----------|------|
| **ProfileHeader** | KPI와 프로필 사이 시각적 구분 부족. 프로그레스 바 없이 % 텍스트만 표시 |
| **WeeklyOverviewChart** | 바+라인 혼합이 작은 영역에서 가독성 저하. 달성률 구간(높/중/낮) 색상 구분이 미묘 |
| **BodyBalanceBar** | 50% 기준선 없음 → 코치가 "이 부위가 약한가?" 판단에 수치 직접 읽어야 함 |
| **SessionAnalysisPanel** | 파란 테두리 강조(`border-blue-500`)가 디자인 시스템과 불일치. 4개 탭 정보 과다, 탭 전환 없이 핵심 불가 |
| **WorkoutRecordList** | 카드 간 정보 밀도 차이 큼. 칼로리/달성률이 작게 표시되어 스캔 어려움 |

### 1.6 코드 수준 UX 영향

| 문제 | 영향 |
|------|------|
| 636줄 단일 컴포넌트 | 상태 관리 복잡 → 불필요한 리렌더링 발생 가능. 차트 바 클릭 → 전체 페이지 리렌더 |
| `useMemo` 6개+ 과다 사용 | `computedStats`, `weeklyData`, `selectedWorkout` 등. 컴포넌트 분리가 더 적절 |
| `as any` 캐스팅 | `handleSendActiveProgramFeedback`에서 사용 — 타입 안전성 저하, 런타임 에러 위험 |
| `console.error` 2곳 | 운영 코드 기준 위반 (code-style.md §금지 패턴) |

---

## 2. Magic MCP 참고 패턴 비교

21st.dev에서 검색한 고품질 컴포넌트 패턴과 현재 구현 간 갭 분석.

### 2.1 KPI 카드 — `KpiCard` 패턴 vs 현재

**21st.dev `KpiCard` (by 21st.dev)**:
- tone별 배경색 분리 (primary/success/warning/danger)
- delta 표시 (`+6.1% ↑` TrendingUp 아이콘)
- caption ("vs Previous 30 Days")
- 코너 pulse 장식 효과
- 크기 variant (sm/md/lg)

```
구조: label → value(대형, tabular-nums) → delta(색상+아이콘) → caption
시각: tone별 ring-1 테두리 + 반투명 배경 → 상태별 즉시 인지
```

**현재 TracMe ProfileHeader KPI**:
- 텍스트만 나열 (달성률 78%, 운동 42일, 칼로리 15,240kcal)
- trend/delta 없음 → 이전 대비 변화 모름
- tone 구분 없음 → 달성률 낮아도 같은 색
- 비교 기준 없음 → 수치의 맥락 부재

| 항목 | 21st.dev 패턴 | 현재 TracMe | Gap |
|------|-------------|------------|-----|
| Delta/Trend | `+6.1% ↑` 아이콘 표시 | 없음 | 코치가 변화 방향 즉시 파악 불가 |
| Tone 시스템 | primary/success/warning/danger | 단일 색상 | 상태 심각도 구분 불가 |
| 수치 크기 | `text-2xl font-bold` 독립 카드 | 작은 텍스트 inline | KPI 존재감 부족 |
| 비교 기준 | "vs Previous 30 Days" caption | 없음 | 수치의 의미 맥락 부재 |
| 시각 효과 | ring-1 + pulse corner | 없음 | 시각적 단조로움 |

### 2.2 대시보드 레이아웃 — `MarketingDashboard` 패턴 vs 현재

**21st.dev `MarketingDashboard`**:
- `grid-cols-2` 카드 기반 레이아웃
- Framer Motion `staggerChildren` 진입 애니메이션
- `whileHover: { scale: 1.03, y: -5 }` 마이크로인터랙션
- 차트 + KPI + 팀 정보를 2x2 그리드에 밀집 배치
- CTA 배너로 행동 유도

**현재 TracMe 레이아웃**:
- 순차적 세로 스택 (Zone 1 → 2 → 3 → 4)
- 애니메이션 없음
- 호버 효과 없음
- 카드 간 시각적 계층 없음

| 항목 | 참고 패턴 | 현재 TracMe | Gap |
|------|----------|------------|-----|
| 그리드 | `grid-cols-2 grid-rows-2` | 모두 풀와이드 세로 스택 | 한 화면 정보량 절반 |
| 카드 밀도 | 4개 영역 동시 노출 | 스크롤해야 다음 영역 | "Precision Observer" 위반 |
| 호버 | `whileHover: scale 1.03` | 없음 | 인터랙티브 피드백 부재 |
| 진입 애니메이션 | `staggerChildren` | 없음 | 데이터 로딩 시 단조로움 |
| 시각 계층 | 카드별 색상 tone 차별화 | 모두 동일 white 카드 | 영역 구분 힘듦 |

### 2.3 운동 기록 — `WorkoutSummaryCard` 패턴 vs 현재

**21st.dev `WorkoutSummaryCard`**:
- 헤더: 날짜 + 액션 버튼 (Like/Delete/Close)
- 메인: 이미지 + 평균 속도/경사 메트릭
- 통계: 아이콘(원형 컬러 배경) + 라벨 + 값, `rounded-full` 배경
- Framer Motion `listVariants` 스태거 애니메이션

```
구조: header → activity card(이미지+메트릭) → stat list(아이콘+라벨+값)
특징: 각 stat에 bgColor/textColor 매핑 → 한눈에 항목 구분
```

**현재 TracMe WorkoutRecordList**:
- 카드에 루틴명, 날짜, 운동 수, 칼로리, 달성률 텍스트 나열
- 아이콘 기반 시각화 없음
- 인라인 액션 없음 (클릭 → 세션 분석 이동만)

| 항목 | 참고 패턴 | 현재 TracMe | Gap |
|------|----------|------------|-----|
| Stat 표시 | 아이콘 + 컬러 원형 배경 | 텍스트만 | 스캔 효율 낮음 |
| 인라인 액션 | 좋아요/삭제/닫기 직접 접근 | 없음 (클릭 → 다른 영역) | 동선 길어짐 |
| 시각 구분 | `bgColor`/`textColor` 매핑 | 달성률 색상만 | 정보 계층 부족 |
| 애니메이션 | `staggerChildren` 리스트 | 없음 | 시각적 단조로움 |

### 2.4 탭 패널 — `Feature108` 패턴 vs 현재

**21st.dev `Feature108`**:
- 아이콘 + 라벨 탭 트리거 (`<Zap /> Boost Revenue`)
- `data-[state=active]:bg-muted` 명확한 활성 상태
- 넓은 콘텐츠 영역 (`max-w-screen-xl rounded-2xl bg-muted/70 p-16`)
- Badge + 제목 + 설명 + CTA 버튼 구조화된 콘텐츠

**현재 SessionAnalysisPanel 탭**:
- 텍스트만 탭 라벨 (요약/비교/AI/상세)
- 활성 상태 구분 미약
- 4개 탭에 과도한 정보 집약

| 항목 | 참고 패턴 | 현재 TracMe | Gap |
|------|----------|------------|-----|
| 탭 라벨 | 아이콘 + 텍스트 | 텍스트만 | 탭 내용 예측 어려움 |
| 활성 상태 | `bg-muted` 배경 변화 | 밑줄만 | 현재 탭 인지 약함 |
| 콘텐츠 영역 | 넓은 패딩, 구조화 | 조밀한 데이터 | 정보 과밀 |

### 2.5 Stats 카드 — `Stats cards with links` 패턴 vs 현재

**21st.dev `Stats05`**:
- 3열 그리드 KPI 카드
- 각 카드: 라벨 + change% + 대형 수치 + "View more →" 링크
- change가 positive면 `text-emerald-700`, negative면 `text-red-700`
- `border-t` 구분선 + footer 링크

**현재 TracMe KPI**:
- ProfileHeader 내부에 텍스트로 인라인 배치
- 드릴다운 링크 없음
- 변화율 표시 없음

---

## 3. 종합 문제점 우선순위

### 🔴 Critical (코치 워크플로우 직접 영향)

1. **KPI에 trend/delta 없음**
   - Stitch: 핵심 수치가 시선 못 끔
   - Magic: `KpiCard` 패턴 대비 정보 50% 부족
   - 영향: 코치가 "이 선수가 나아지고 있나?" 즉시 판단 불가

2. **세션 분석 조건부 렌더링**
   - Stitch: 핵심 기능이 숨겨짐
   - Magic: 대시보드 패턴은 모든 핵심 정보 상시 노출
   - 영향: 코치가 세션 분석 도달에 추가 클릭 필요

3. **레이아웃 밀도 부족 (세로 스크롤 과다)**
   - Stitch: "Precision Observer" 컨셉과 정반대
   - Magic: `MarketingDashboard` 2x2 밀집 대비 정보 밀도 절반
   - 영향: 의사결정에 필요한 정보를 한 화면에서 못 봄

4. **선택 모델 시각 피드백 부족**
   - Stitch: 차트↔기록 상호 배타 선택이 불명확
   - Magic: 참고 패턴은 `whileHover`, `scale` 등으로 명확한 피드백
   - 영향: 코치가 현재 어떤 세션을 보고 있는지 혼란

### 🟡 Important (디자인 품질)

5. **하드코딩 색상 → 디자인 토큰 불일치**
   - `#343C6A`, `#2D60FF`, `#4D667F`, `#E5E8F0` 직접 사용
   - DESIGN.md 토큰 (`--foreground`, `--primary` 등) 무시
   - 테마 변경/다크 모드 대응 불가

6. **호버/마이크로인터랙션 전무**
   - Magic 패턴: 카드 호버 시 `scale 1.03, y -5`, 진입 시 `stagger`
   - 현재: 정적 렌더링만. 대시보드가 "살아있다"는 느낌 부재

7. **운동 기록 카드 정보 밀도 낮음**
   - Magic `WorkoutSummaryCard`: 아이콘+컬러+값 조합으로 즉시 스캔
   - 현재: 텍스트 나열로 시각적 앵커 없음

8. **바디 밸런스 50% 기준선 없음**
   - Stitch: 기준선 없어 "약한 부위" 판단에 수치 직접 읽어야 함
   - Precision Observer DESIGN.md에는 기준선 명시되어 있으나 미구현

9. **AI 인사이트 위치 매몰**
   - 차트 아래 배치 → 스크롤해야 도달
   - AI 분석은 코치 의사결정의 핵심인데 부차적 취급

### 🟢 Enhancement (참고 패턴에서 배울 점)

10. **KPI tone 시스템 도입**
    - `KpiCard` 패턴의 primary/success/warning/danger 톤
    - 달성률 구간별 카드 색상 자동 변경

11. **Framer Motion 진입 애니메이션**
    - `staggerChildren` 카드 순차 등장
    - 데이터 로딩 후 자연스러운 전환

12. **탭 아이콘 + 라벨 조합**
    - `Feature108` 패턴의 `<Zap /> + label` 구조
    - 탭 내용 예측 가능성 향상

13. **Stats 카드 드릴다운 링크**
    - `Stats05` 패턴의 "View more →" footer
    - KPI 클릭 시 상세 분석 이동

14. **컴포넌트 분리 (636줄 → 300줄 이하)**
    - `useMemo` 6개+ → 자식 컴포넌트로 책임 분산
    - `as any` 제거, `console.error` 정리

---

## 4. 개선 방향 제안

### Phase 1: 구조 개선 (코치 워크플로우 영향 최대)

```
변경 1: 세션 분석 상시 표시 (조건부 렌더링 제거)
변경 2: KPI 카드 독립 분리 + trend/delta 추가
변경 3: 레이아웃 밀도 개선 (2열 활용, 스크롤 감소)
변경 4: 선택 모델 시각 피드백 강화 (active state 명확화)
```

### Phase 2: 디자인 품질 (토큰 + 인터랙션)

```
변경 5: 하드코딩 색상 → CSS 변수/Tailwind 토큰 교체
변경 6: 바디 밸런스 50% 기준선 추가
변경 7: 호버 효과 + 진입 애니메이션 추가
변경 8: 운동 기록 카드 재디자인 (아이콘+컬러 stat)
```

### Phase 3: 고도화 (새로운 패턴 도입)

```
변경 9: KpiCard tone 시스템 (달성률 구간별 자동 색상)
변경 10: 탭 아이콘 + 라벨 조합
변경 11: 컴포넌트 분리 + 성능 최적화
변경 12: AI 인사이트 위치 재배치 (세션 분석 근처)
```

---

## 참고 자료

- **Stitch 디자인 시스템**: `/tracme-solution/.stitch/DESIGN.md`
- **Precision Observer 스크린샷**: `/tracme-solution/docs/superpowers/specs/선수상세화면/screen.png`
- **기능 스펙**: `/tracme-solution/docs/superpowers/specs/2026-04-06-athlete-detail-feature-spec.md`
- **리디자인 스펙**: `/tracme-solution/docs/superpowers/specs/2026-04-06-athlete-detail-redesign-design.md`
- **21st.dev 참고 패턴**: KpiCard, MarketingDashboard, WorkoutSummaryCard, Feature108, Stats05

---

*작성일: 2026-04-06*
*분석 도구: Stitch Design Skill, Magic MCP (21st.dev)*
