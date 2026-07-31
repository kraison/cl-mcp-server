# cl-mcp-server

## Rule 0 — don't guess, ask the image

Before calling any Lisp function you have not already called in this session,
look up its signature. Guessing *feels* cheaper than a tool call; it isn't.

- unfamiliar function → `describe-symbol`
- generic function with a mode/algorithm/kind argument → `describe-generic-function`
  (EQL specializers list the accepted values; the lambda list cannot)
- standard CL operator semantics → `hyperspec-lookup`
- where is this defined? → `find-definition-source`, not grep
- writing a `.lisp` file → `write-lisp-file` (fail-closed; never writes invalid source)
- what does this value actually contain? → `inspect-object` (navigable)
- what did this call actually do? → `trace-call`
- recovering from an error, not just reading it → `evaluate-with-restarts`,
  then `invoke-restart` (`CONTINUE` resumes in place)

Do Lisp work through the `lisp` MCP tools. Do not shell out to `sbcl`.

## For contributors working on this project
Invoke the dev skill: `.claude/skills/dev/SKILL.md`

## For agents using the REPL tools
Invoke the integration skill: `.claude/skills/integration/SKILL.md`

## Dependencies
@../opsis/claude.md
