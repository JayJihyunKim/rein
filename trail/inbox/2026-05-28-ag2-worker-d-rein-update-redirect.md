# AG-2 worker_d: rein update plugin redirect message

- 날짜: 2026-05-28
- 유형: fix
- 변경 파일: [scripts/rein.sh]
- 요약: `merge|update` case 의 안내 문구에 영문 "rein is in plugin mode" 줄을
  prepend 해 `tests/scripts/test-rein-update-claude-md-untouched.sh` 의
  Assert A grep pattern (`plugin mode|plugin manager`) 을 충족. 한국어
  문구는 유지. 테스트 3/3 PASS 확인.
