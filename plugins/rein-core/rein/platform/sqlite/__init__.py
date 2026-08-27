"""SQLite runtime store 부트스트랩."""
import sqlite3

# 경로 미지정 실행이 저장소 트리에 파일을 남기지 않도록 in-memory 가 기본값
IN_MEMORY_DB = ":memory:"
_PROBE_STATEMENT = "PRAGMA user_version"


def open_store(db_path):
    """store 를 열고 probe 1회를 실행해 실제 I/O 를 일으킨다.

    콜드스타트 측정(SPIKE-1)이 lazy handle 이 아닌 진짜 open 비용을
    보게 하기 위한 조치다.
    """
    connection = sqlite3.connect(db_path)
    connection.execute(_PROBE_STATEMENT).fetchone()
    return connection
