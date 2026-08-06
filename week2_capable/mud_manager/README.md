# MudManager

One gem, one binary. `MudManager` has two halves:

- **Domain** — `MudManager::Session` (a long-lived telnet connection, with
  background buffering, IAC stripping, and the login dance) and
  `MudManager::Primitives` (a stateless table of typed CircleMUD command
  builders, plus a small immortal-only slice — `admin_goto`/`admin_transfer`
  — used by `week2_capable/bin/reset` to put a test character back at the
  start, never exposed as MCP tools). This is the part any bootcamper who
  `require "mud_manager"` touches directly.
- **Daemon** — `MudManager::Mcp::*` plus the `mud-manager` executable: an MCP
  server over stdio that owns one `Session`, hides connect/login behind the
  tool boundary, and exposes gameplay as 27 typed MCP tools (including the
  `inspect` composite — `look` + `exits` in one round trip, added so the
  agent stops burning two tool calls on every new room). This is how every
  non-Ruby bootcamp track (and the Ruby track too, via `boukensha`) drives a
  MUD — see [`docs/plans/mud_manager/04_mud_manager_mcp_integration.md`](../../docs/plans/mud_manager/04_mud_manager_mcp_integration.md)
  for the full picture and the rest of [`docs/plans/mud_manager/`](../../docs/plans/mud_manager/)
  for the design history.

## Packaging

`gem install mud_manager` gets you `Session`, `Primitives`, and the
`mud-manager` binary in one shot — no second gem to keep version-locked, and
no Ruby toolchain archaeology for a Rust/Go/Python bootcamper who just wants
the binary.

## Build the Gem

From this directory:

```sh
gem build mud_manager.gemspec
gem install ./mud_manager-0.2.0.gem
```

## Uninstall

```sh
gem uninstall mud_manager
```

## The `mud-manager` binary

```sh
# Run the MCP daemon over stdio (credentials from MUD_HOST/MUD_PORT/MUD_NAME/MUD_PASSWORD):
mud-manager --mcp

# Print the language-neutral tool spec (what primitives.json is generated from):
mud-manager --dump-spec

# List tool names:
mud-manager --list-tools
```

Regenerate `primitives.json` after changing `lib/mud_manager/mcp/tool_spec.rb`:

```sh
rake spec
```

## Tests

```sh
rake test
```

Uses `MudManager::FakeMud`, an in-process CircleMUD stand-in — no live MUD or
credentials needed.

## Examples

Test the live session:

```sh
MUD_NAME=YourCharacterName MUD_PASSWORD=yourpassword ruby examples/live_session_test.rb
```

Exercise the daemon end-to-end against the fake MUD, no API key required:

```sh
ruby ../boukensha/examples/mcp_mud_demo.rb --dry
```

## Observability

Two logs, off by default, both read by the sibling `mud_monitor` app:

- `MudManager::ManagerLog` — one record per tool call the daemon executes
  (tool, args, elapsed time, error). Set `MUD_MANAGER_LOG_DIR` to enable.
- `MudManager::TelnetLog` — every raw byte crossing the socket, both
  directions, with the login password redacted at the source. Set
  `MUD_TELNET_LOG_DIR` to enable. This is the more expensive one; leave it
  off unless you're chasing something specific.

Both are wired into the `mud:` MCP server's `env:` block in whichever
`settings.yaml` boukensha is using.
