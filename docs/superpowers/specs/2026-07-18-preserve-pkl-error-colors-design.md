# Preserve Pkl Error Colors

## Problem

`EcsTaskDef.Pkl` redirects the Pkl process's stderr to a temporary file so it
can return generated JSON and diagnostics separately. Pkl's default
`--color=auto` behavior sees that stderr is not a terminal and removes ANSI
color from its diagnostics before the CLI replays them to the user's stderr.

## Design

Invoke `pkl eval` with `--color=always`. The CLI will continue to capture and
replay Pkl stderr unchanged, so Pkl's original diagnostic colors survive the
temporary-file boundary. Generated JSON on stdout and the CLI's own progress
and error formatting remain unchanged.

Always-colored Pkl diagnostics are intentional even when the CLI's stderr is
redirected or piped. This gives the command one predictable behavior and
directly matches the request to preserve Pkl's colors.

## Testing

Extend the fake Pkl executable with an opt-in assertion that
`--color=always` was passed to `eval`. Add a focused `EcsTaskDef.Pkl` test that
enables this assertion and initially fails with the current invocation.

After the minimal command change makes that test pass, run the Pkl and CLI
tests followed by the complete test suite.
