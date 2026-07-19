#!/usr/bin/env bash
set -euo pipefail

: "${FAKE_GH_LOG:?FAKE_GH_LOG is required}"
: "${FAKE_GH_MODE:?FAKE_GH_MODE is required}"

{
  printf '%q' "${1:-}"
  for arg in "${@:2}"; do
    printf ' %q' "$arg"
  done
  printf '\n'
} >>"$FAKE_GH_LOG"

if [ "${1:-}" != "release" ]; then
  exit 64
fi

case "${2:-}" in
  create)
    case "$FAKE_GH_MODE" in
      create-ok) exit 0 ;;
      create-race|create-fatal) exit 1 ;;
      *) exit 64 ;;
    esac
    ;;
  view)
    case "$FAKE_GH_MODE" in
      create-race) exit 0 ;;
      create-ok|create-fatal) exit 1 ;;
      *) exit 64 ;;
    esac
    ;;
  upload)
    exit 0
    ;;
  *)
    exit 64
    ;;
esac
