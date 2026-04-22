# Windows Troubleshooting

Rein 의 훅은 bash + GNU coreutils 를 전제로 동작하며, 일부 Python 스크립트는 `fcntl` 같은 POSIX API 에 의존합니다. Windows 에서는 **WSL2 (Ubuntu) 환경이 공식 지원 경로** 입니다.

## WSL2 설치 (권장 — 공식 지원)

PowerShell 을 **관리자 권한**으로 열고 실행:

```powershell
wsl --install
```

- Windows 10 2004 (빌드 19041) 이상 또는 Windows 11 에서 한 줄로 완료됩니다
- 기본 배포판 Ubuntu 가 자동 설치되고 사용자 계정을 만들라는 프롬프트가 뜹니다
- 재부팅 후 `wsl` 을 다시 실행하면 Ubuntu 셸로 진입합니다

그 다음 WSL Ubuntu 셸 안에서 일반 Linux 와 동일하게 설치합니다:

```bash
# 필수 도구 (대부분 Ubuntu 기본 포함)
sudo apt update && sudo apt install -y git curl python3

# Rein 설치
curl -fsSL https://raw.githubusercontent.com/JayJihyunKim/rein/main/install.sh | bash
source ~/.rein/env
rein --version
```

프로젝트 체크아웃 경로는 `/mnt/c/...` (Windows 파일시스템) 보다 `~/` (WSL 파일시스템) 가 디스크 I/O 가 훨씬 빠릅니다.

자세한 안내: Microsoft 공식 문서 [aka.ms/wsl-install](https://aka.ms/wsl-install).

## Git Bash / MSYS2 (best-effort, 정식 테스트 대상 아님)

Windows Git Bash 에서 동작하도록 노력했지만, 정식 테스트 매트릭스에 포함되지 않습니다. 문제가 생기면 WSL2 로 전환하는 것이 가장 빠른 해결입니다.

### `python3 exit 49` 진단 (v0.10.1+)

훅이 아래 메시지로 차단되면 3종 명령으로 진단합니다:

```
BLOCKED: ... Python launch 실패 (9009 계열)
```

```bash
command -v python3      # python3 가 PATH 에 잡히는가
python3 -V              # 실제 실행 성공하는가
py -3 -V                # py launcher 가 real Python 을 가리키는가
```

### 해석

| 결과 | 원인 |
|---|---|
| `command -v` 성공 + `python3 -V` 실패 + `py -3 -V` 성공 | **WindowsApps App Execution Alias stub 문제** (가장 흔함) |
| 세 명령 모두 실패 | real Python 미설치 |
| `command -v` 실패 | PATH 설정 문제 |

**참고**: 훅이 보고하는 `python3 exit 49` 는 Python 의 JSON 파싱 실패가 아니라 Windows 의 `9009` (command not found / App Execution Alias stub 실행 실패) 가 Git Bash/MSYS 에서 8비트로 잘린 값입니다 (`9009 mod 256 = 49`).

### 해결책 (우선순위 순)

1. **WSL2 로 전환** — Rein 의 공식 Windows 지원 경로
2. Windows Settings → "앱 실행 별칭 관리 (Manage app execution aliases)" 에서 `python.exe` / `python3.exe` 스위치를 **off** 로 바꾸고, [python.org](https://www.python.org/downloads/) 또는 Python install manager 로 실제 Python 을 설치
3. PATH 에서 real Python 또는 `py` launcher 가 `WindowsApps` 디렉토리보다 **앞에** 오도록 순서 조정
4. venv 사용자는 `export REIN_PYTHON=/path/to/python3` 로 명시 지정 (resolver 우선순위에서 1순위로 사용됨)

### Alias 주의

비대화형 hook 은 `alias python3=...` 같은 shell alias 를 상속받지 못합니다. 훅은 bash script 로 fork 되어 interactive rc 파일을 source 하지 않기 때문입니다. **실제 실행파일 wrapper 또는 PATH 조정** 이 필요합니다.

### Local hook 수정 주의

local hook 수정 (예: fail-closed 를 `exit 0` 으로 바꿔 gate 를 우회) 은 언제든 기술적으로 가능하지만, 그 시점에 Rein 의 gate 보장은 무효가 됩니다. 이 경로를 의도적으로 쓰는 경우 Rein 트래킹 대상이 아닙니다.

## PowerShell / CMD native

**미지원**. 훅이 POSIX bash + GNU coreutils 를 전제로 하므로 PowerShell 또는 CMD 에서는 동작하지 않습니다. WSL2 를 사용하세요.
