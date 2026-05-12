# Overflow handoff — Claude Code 의 10KB cap 처리

## 핵심 원칙

rein plugin 의 rule-inject hooks 는 **rule body 를 자체 truncate 하지 않는다**. rule body 가 Claude Code 의 `additionalContext` 10,000 chars cap 을 초과해도, Claude Code 의 공식 overflow-file handoff 메커니즘이 자동 처리한다.

## Claude Code overflow-file handoff (공식 동작)

hook 의 `stdout` / `additionalContext` / `systemMessage` 가 10,000 chars 를 초과하면 Claude Code 가:
1. full text 를 현재 session directory 의 임시 파일에 저장
2. preview (cap 안에 들어가는 일부) + file path 를 Claude (모델) 에 전달
3. Claude 가 필요 시 `Read` 도구로 full text 접근

이 메커니즘은 외부 의존 — Claude Code 가 책임지는 동작. rein 은 cap 미만/초과 무관하게 full body 만 전달.

## 왜 rein 자체 truncate 하지 않나

대안 (truncate / skip / split) 의 문제:
- **truncate**: 행동 강령 절 (mandate) 은 항상 cap 안에 inline 보장되지만, detail 본문이 잘리면 의미 일관성 손상
- **skip**: 어떤 rule 을 inject 할지 모델이 선택할 수 없게 됨
- **split**: 여러 hook 호출로 쪼개면 inject 순서/우선순위 결정 어려움

→ Claude Code 가 이미 overflow-file 메커니즘으로 무손실 전달을 보장한다. rein 은 단순 pass-through.

## diagnostic

`rule-inject.sh` 는 매 호출 시 stderr 에 다음 한 줄을 출력:
```
rein-rule-inject: rule=<name> size=<bytes> bytes
```

이는 디버깅용 — blocking 아님. cap 초과 시 운영자가 plugin runtime stderr 에서 size 를 확인할 수 있다. Claude Code 가 overflow-file 로 핸들링하므로 production 환경에서도 sane default.

## 행동 강령 절 (action mandate) 의 역할

모든 plugin-shipped rule 본문 맨 앞의 `## 행동 강령` 절 (≤ 2KB) 은 **항상 cap 안에 inline 보장**. body 전체가 overflow-file 로 가도, preview 에 mandate 가 포함될 가능성이 높다. mandate 만으로도 self-contained 한 결론 단락 — Claude 가 이 절만 봐도 본질적 의무 파악 가능.

이 패턴은 cap 무관하게 prompt-level 책임을 1-shot 으로 전달하는 핵심 메커니즘.

## 관련

- spec: `docs/specs/2026-05-12-plugin-prompt-level-operating-model.md` — 6 mode delivery taxonomy
- helper: `plugins/rein-core/hooks/lib/rule-inject.sh`
- publish-time CI: `scripts/rein-validate-plugin-rules.py` (Task 3.3) — mandate 존재 + ≤ 2KB 강제
