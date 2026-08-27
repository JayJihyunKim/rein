"""Git fact resolution — walking skeleton 은 현재 브랜치 1종만 제공한다."""
import subprocess

_BRANCH_COMMAND = ("git", "rev-parse", "--abbrev-ref", "HEAD")
_GIT_TIMEOUT_SECONDS = 5


def current_branch(cwd=None):
    """현재 브랜치 이름, 해석 불가면 None.

    예외가 아니라 None 인 이유: repo 부재·git 부재는 fact 의 부재일 뿐
    평가 실패(failure_mode 대상)가 아니다 (spec §3.4).
    """
    try:
        proc = subprocess.run(
            _BRANCH_COMMAND,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=_GIT_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    branch = proc.stdout.strip()
    return branch or None
