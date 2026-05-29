# DoD — P10 .env commit-am 가드 정규식 단순화 (SIMPLIFY)

- 날짜: 2026-05-29
- 유형: fix
- security_tier: light (hook regex 조정, 외부 I/O/secret 처리 변경 없음)

## 배경 / root cause

codex Round 2 가 P10 의 R5/v6 git-argument-grammar 정규식 (CHUNK matcher,
double/single-quote span + escape 모델링) 을 SIMPLIFY 권고. 진단:
1. 5라운드 grammar 모델은 **mistake-prevention** 가드 위협 모델에 과하다 (실수로
   `.env` 를 `commit -am` 하는 것 방지가 목적 — 적대적 따옴표 중첩 우회는 비목표).
2. 그 복잡도에도 여전히 attached `-mfoo` 미포착.
3. quoted-message 안 `-a` 텍스트 오탐.
사용자가 단순화 승인.

## 위협 모델 (재확인)

P10 = "실수로 `.env` 를 auto-add (`-a`) 커밋에 포함" 방지. 작정한 적대적 우회
(`git -c "u=J K" commit -am` 따옴표 중첩) 는 **명시적 비목표**.

## 변경 파일

- plugins/rein-core/hooks/pre-bash-safety-guard.sh
- tests/hooks/test-pre-bash-safety-guard.sh

## 작업 내용

1. 복잡한 CHUNK-grammar 3-arm 정규식을 codex 제안 단순형 (실측 검증한 minimal
   PREFIX 형태) 으로 교체. PREFIX = git + (value-taking opt[bare value] |
   기타 dash-led 자기완결 flag)* + commit. arm1=combined bundle(-am/-ma),
   arm2=all→message(attached -mfoo 포함), arm3=message→all.
2. 장황한 5라운드 grammar 주석 → 단순 버전 의도 + 2개 비목표 한계 주석으로 교체.
3. 테스트: 적대적 따옴표 중첩 BLOCK 케이스 (R2/R4 의 `-c "u=J K"`, escaped-space,
   inner-quote, single-quote, two quoted-space opts) 제거/조정 (비목표화).
   `-a -mfoo` / `--message=foo -a` 차단 케이스 추가. 일상 형태 + 비차단 유지.

## 검증

- 실측 RED→GREEN (probe 로 단순 regex 사전 검증 완료)
- bash -n: pre-bash-safety-guard.sh (버그2 wrapper 2사본 미변경)
- 전체 스위트 GREEN: test-pre-bash-safety-guard / test-codex-review-wrapper /
  test-bash-guard-split / command-anchoring / test-pre-bash-test-commit-gate

## 라우팅 추천

```yaml
agent: feature-builder-fix
skills: [codex-review]
mcps: []
rationale: hook regex bug 단순화 — reproduction-first, codex 리뷰 게이트 필수
approved_by_user: true
```

## 수용 한계 (비목표, 주석 기재)

1. 적대적 따옴표 중첩 전역옵션 값 (`git -c "u=J K" commit -am`) — 안 막음.
2. quoted 메시지 안 `-a` 텍스트 오탐 (`git commit -m "use -a flag"`) — command_invokes
   따옴표 비인식 한계. 단순 버전도 못 막음 — 수용.
