"""ChangeSet + 내용 기반 digest (spec §3.3).

- Scope 4종: `WORKTREE` / `STAGED` / `COMMIT` / `TASK`. v2.0 은
  WORKTREE/STAGED 를 주요 Enforcement Scope 로 사용한다.
- Digest = ChangeSet 식별자 — "Evidence 생성 후 대상이 변경되었는가"
  에 **내용으로** 답한다. mtime 은 validity 판단 근거가 아니며 (캐시
  invalidation hint 로만 허용), 이 모듈은 mtime 을 아예 읽지 않는다
  (v1 게이트 freshness 교훈의 계약화: content 기준 > 시각 기준).
- kernel 은 버전관리 도구를 모른다 (spec §3.1 의존 규칙) — 파일 내용은
  주입된 `read_content(path) -> bytes | None` 공급자가 제공하고, 여기는
  순수 계산만 한다. WORKTREE/STAGED 해석은 platform 소관이다.
"""
import hashlib
from dataclasses import dataclass

SCOPE_WORKTREE = "WORKTREE"
SCOPE_STAGED = "STAGED"
SCOPE_COMMIT = "COMMIT"
SCOPE_TASK = "TASK"

# Scope 폐쇄 집합 (spec §3.3). 순서도 계약의 일부로 고정한다.
SCOPES = (SCOPE_WORKTREE, SCOPE_STAGED, SCOPE_COMMIT, SCOPE_TASK)

_DIGEST_ALGORITHM = "sha256"

# 닫힌 값 계약 2상태 (spec §3.6 "digest scope 프로필" 절, 2026-08-19) —
# subject digest 산정 결과가 "확인했더니 대상 없음"(SUBJECT_EMPTY, 충족
# 방향)인지 "산정 불가"(SUBJECT_UNRESOLVED, 보수 미충족 방향)인지를 값
# 하나로 표현하는, 발급측과 평가측이 공유하는 센티널이다. 이 모듈이
# 정의하는 실제 digest 값 공간(`content_digest`/`changeset_digest` 가
# 만드는 `"{algorithm}:{hexdigest}"`, 예 `"sha256:<64 hex chars>"`)과
# 절대 같은 값이 될 수 없는 형태를 고른다 — `hexdigest()` 는 언제나
# `[0-9a-f]` 문자만으로 구성되므로, 접미사 `no-subject` 처럼 hex 범위
# 밖 문자('n','o','-','s','j','e','c','t' 등)를 포함한 문자열은 어떤
# 해시 알고리즘·어떤 입력으로도 재현될 수 없다(접두어 자체가 실제
# 알고리즘 이름과 겹쳐도 무해하다). `rein.kernel.evidence.Evidence`
# 는 `subject` 가 비어 있지 않은 값이어야 한다는 계약을 가지므로
# (`Evidence.__post_init__`), 두 센티널 모두 non-empty 문자열이다 —
# Evidence.subject 에 그대로 대입 가능하다.
SUBJECT_EMPTY = "empty:no-subject"
SUBJECT_UNRESOLVED = "unresolved:no-subject"

# 프레이밍 마커 — 경로/내용/부재 레코드의 경계를 고정해 연접 충돌
# ("ab"+"c" == "a"+"bc")과 상태 혼동(부재 vs 빈 내용)을 제거한다.
_MARK_PATH = b"P"
_MARK_BLOB = b"B"
_MARK_ABSENT = b"A"
_LENGTH_PREFIX_BYTES = 8


@dataclass(frozen=True)
class ChangeSet:
    """단일 ChangeSet — scope + 정규화된 경로 집합 (spec §3.3).

    paths 는 저장소 상대 경로의 정렬·중복제거된 tuple 로 정규화된다 —
    같은 변경 집합은 입력 순서와 무관하게 같은 값이다.
    """

    scope: str
    paths: tuple

    def __post_init__(self):
        if self.scope not in SCOPES:
            raise ValueError(
                "ChangeSet.scope must be one of {} (spec §3.3), got "
                "{!r}".format(SCOPES, self.scope)
            )
        paths = tuple(self.paths)
        for path in paths:
            if not isinstance(path, str) or not path:
                raise ValueError(
                    "ChangeSet.paths must contain non-empty strings, got "
                    "{!r}".format(path)
                )
        object.__setattr__(self, "paths", tuple(sorted(set(paths))))


def content_digest(paths, read_content):
    """경로 집합의 내용 기반 digest — 순수 함수 (spec §3.3).

    `read_content(path)` 는 bytes(현재 내용) 또는 None(부재 — 삭제된
    경로)을 반환하는 주입 공급자다. 부재(None)와 빈 내용(b"")은 다른
    상태로 결속된다. 경로는 정렬해 순회하므로 입력 순서는 결과에
    영향을 주지 않는다. mtime 등 시각 정보는 어떤 형태로도 개입하지
    않는다.
    """
    hasher = hashlib.new(_DIGEST_ALGORITHM)
    for path in sorted(set(paths)):
        encoded_path = path.encode("utf-8", "surrogateescape")
        hasher.update(_MARK_PATH)
        hasher.update(
            len(encoded_path).to_bytes(_LENGTH_PREFIX_BYTES, "big")
        )
        hasher.update(encoded_path)
        content = read_content(path)
        if content is None:
            hasher.update(_MARK_ABSENT)
            continue
        if not isinstance(content, (bytes, bytearray)):
            raise TypeError(
                "read_content({!r}) must return bytes or None, got "
                "{!r}".format(path, type(content).__name__)
            )
        content = bytes(content)
        hasher.update(_MARK_BLOB)
        hasher.update(len(content).to_bytes(_LENGTH_PREFIX_BYTES, "big"))
        hasher.update(content)
    return "{}:{}".format(_DIGEST_ALGORITHM, hasher.hexdigest())


def changeset_digest(changeset, read_content):
    """ChangeSet 의 digest — 정규화된 paths 에 대한 `content_digest`."""
    return content_digest(changeset.paths, read_content)
