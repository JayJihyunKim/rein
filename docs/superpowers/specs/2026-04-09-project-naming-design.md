# Rein — 프로젝트 네이밍 디자인

> 날짜: 2026-04-09
> 상태: 승인됨

---

## 요약

AI Native 개발 프레임워크의 공식 이름을 **Rein**으로 결정한다.
"고삐를 쥐다"라는 메타포로, AI를 규칙·게이트·훅으로 통제하며 실패 시 시스템이 진화하는 프레임워크의 정체성을 표현한다.

## 네이밍 결정

- **이름**: Rein
- **태그라인**: "Rein in your AI"
- **의미**: AI를 자유롭게 실행하되, 규칙(AGENTS.md)·게이트(hooks)·감시(SOT/incidents)로 방향을 잡아주는 고삐
- **선정 이유**: 4글자, 발음 용이, CLI 명령어로 자연스러움, 메타포가 프레임워크 핵심과 정확히 일치

## 적용 범위

### 변경 대상

| 항목 | Before | After |
|------|--------|-------|
| GitHub 레포명 | `claude-code-ai-native` | `rein` |
| CLI 명령어 | `claude-init` | `rein` |
| README 타이틀 | "Claude Code AI-Native Repo Template" | "Rein — AI Native development framework" |
| README 본문 | "이 저장소는~" | "Rein은~" |
| 스크립트 파일명 | `scripts/claude-init.sh` | `scripts/rein.sh` |
| 환경변수 | `CLAUDE_TEMPLATE_REPO` | `REIN_TEMPLATE_REPO` (하위 호환 유지) |

### 변경하지 않는 것

- `.claude/` 디렉토리 구조 — Claude Code의 컨벤션이므로 유지
- `AGENTS.md`, `CLAUDE.md` — 내부 시스템 파일명은 유지
- `SOT/index.md`의 `{{PROJECT_NAME}}` — 사용자 프로젝트명 플레이스홀더이므로 유지
- hooks, orchestrator, router 등 내부 시스템 로직

### CLI 사용 예시

```bash
# 설치
gh api repos/JayJihyunKim/rein/contents/scripts/rein.sh \
  --jq '.content' | base64 -d | sudo tee /usr/local/bin/rein > /dev/null \
  && sudo chmod +x /usr/local/bin/rein

# 사용
rein new my-project        # 새 프로젝트 생성
rein merge                 # 기존 프로젝트에 병합
rein update                # 템플릿 업데이트
```

## 구현 시 주의사항

- GitHub 레포 rename은 GitHub Settings에서 수동 수행
- 기존 `claude-init` 사용자를 위해 스크립트에 deprecation notice 또는 alias 고려
- `CLAUDE_TEMPLATE_REPO` 환경변수는 `REIN_TEMPLATE_REPO`로 변경하되, 기존 변수도 fallback으로 인식
