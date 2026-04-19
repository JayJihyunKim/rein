#!/bin/bash
# DEPRECATED alias: inbox-compress.sh → trail-rotate.sh
# 1 release (v0.8.x) 에서 alias 제거 예정
exec "$(dirname "$0")/trail-rotate.sh" "$@"
