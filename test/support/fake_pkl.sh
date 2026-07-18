#!/bin/sh
# Configurable stand-in for the pkl CLI, driven by environment variables:
#   FAKE_PKL_VERSION  version reported by --version   (default 0.31.1)
#   FAKE_PKL_STDOUT   stdout emitted by any other invocation
#   FAKE_PKL_STDERR   stderr emitted by any other invocation
#   FAKE_PKL_EXIT     exit code for any other invocation (default 0)
if [ "$1" = "--version" ]; then
  echo "Pkl ${FAKE_PKL_VERSION:-0.31.1} (fake, native)"
  exit 0
fi
[ -n "$FAKE_PKL_STDERR" ] && printf '%s\n' "$FAKE_PKL_STDERR" >&2
[ -n "$FAKE_PKL_STDOUT" ] && printf '%s\n' "$FAKE_PKL_STDOUT"
exit "${FAKE_PKL_EXIT:-0}"
