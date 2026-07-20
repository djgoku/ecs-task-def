#!/bin/sh
# Configurable stand-in for the pkl CLI, driven by environment variables:
#   FAKE_PKL_VERSION  version reported by --version   (default 0.31.1)
#   FAKE_PKL_STDOUT   stdout emitted by any other invocation
#   FAKE_PKL_STDERR   stderr emitted by any other invocation
#   FAKE_PKL_EXIT     exit code for any other invocation (default 0)
#   FAKE_PKL_REQUIRE_COLOR_ALWAYS
#                     when 1, fail unless --color=always is present
#   FAKE_PKL_REMOVE_STDERR_FILE
#                     when 1, unlink the shell's stderr capture file
if [ "$1" = "--version" ]; then
  echo "Pkl ${FAKE_PKL_VERSION:-0.31.1} (fake, native)"
  exit 0
fi
if [ "$FAKE_PKL_REQUIRE_COLOR_ALWAYS" = "1" ]; then
  found_color_always=
  for arg do
    [ "$arg" = "--color=always" ] && found_color_always=1
  done

  if [ "$found_color_always" != "1" ]; then
    printf '%s\n' "missing --color=always" >&2
    exit 97
  fi
fi
if [ "$FAKE_PKL_REMOVE_STDERR_FILE" = "1" ]; then
  rm -f "$ECS_TASK_DEF_STDERR_FILE"
fi
[ -n "$FAKE_PKL_STDERR" ] && printf '%s\n' "$FAKE_PKL_STDERR" >&2
[ -n "$FAKE_PKL_STDOUT" ] && printf '%s\n' "$FAKE_PKL_STDOUT"
exit "${FAKE_PKL_EXIT:-0}"
