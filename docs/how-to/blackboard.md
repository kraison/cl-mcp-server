# How to: Register a blackboard's tools

Give every session on this server one MCP tool per operator of a
running [blackboard](https://github.com/kraison/blackboard) service.
The tool set is derived from the service's own vocabulary at startup,
so a new operator on the service needs no change here.

## When to Use This

- A blackboard service is listening on your network and its principals
  file admits this host.
- You want its operators (`recall`, `conclude`, …) beside the REPL
  tools in one session, as `blackboard-recall`, `blackboard-conclude`,
  plus `blackboard-form` (a raw request) and `blackboard-status`.

## Prerequisites

- The `blackboard` repository and the checkouts it pins (its README,
  "Building and testing", names them), reachable by this server's user.
- This server started with `BLACKBOARD_ASDF_REGISTRY` in its
  environment: a colon-separated list of those checkouts, the
  blackboard's first. Without it the load resolves an older engine from
  quicklisp's `local-projects` and fails; the failure is logged and the
  server starts without the tools.

## Steps

1. Name the target in `~/.config/cl-mcp-server/config.sexp`, beside
   the allowlist. The file holds one plist:

   ```lisp
   (:armable-targets ("scratch")
    :blackboard (:host "100.64.0.9" :port 4020 :role "claude-code"
                 :instance "main"))
   ```

   `:host`, `:port` and `:role` are required; `:instance`,
   `:connect-timeout` and `:request-timeout` are optional. Omit the key
   and nothing is loaded and nothing is registered.

2. Put the registry in the server's environment in your client's MCP
   configuration. For Claude Code:

   ```bash
   claude mcp add cl-mcp -s user \
     -e BLACKBOARD_ASDF_REGISTRY=$HOME/work/blackboard:$HOME/work/vivace-graph:$HOME/work/cl-llm:$HOME/work/cl-mcp \
     -- sbcl --script /path/to/cl-mcp-server/run-server.lisp
   ```

3. Start a new session and call `blackboard-status`, then
   `blackboard-recall` for a subject the service holds. Both answer in
   the blackboard's own printed s-expressions; a refusal is text, not a
   tool error.

## What it costs

`blackboard/mcp` depends on the whole blackboard, which depends on
`cl-llm` and `graph-db`, so the first start with the key present
compiles and loads both into this server's image. That is why the key
is the switch: a server with no `:blackboard` key pays nothing. The
server's exit closes the blackboard connection.

## Reference

The tool set, the argument types, the local refusals and the one
connection's rules are the blackboard's:
`docs/protocol.md`, "Derived tools", in that repository.
