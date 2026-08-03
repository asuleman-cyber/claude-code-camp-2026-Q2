# Running `11_tui`'s tests and smoke tests (Windows host, via WSL)

`11_tui` depends on `charm` (bubbletea/lipgloss/bubbles/ntcharts/etc.), which
ships native extensions. Their build scripts only handle `darwin` and
`linux` — there is no Windows branch — so `bundle install` cannot build them
under native Windows Ruby, no matter what's on `PATH`. `Gemfile.lock` already
pins precompiled gems for `x86_64-linux-gnu`, so WSL is the supported route,
not a workaround.

This documents the one-time setup and the exact commands used to get
`rake test` and both `bin/boukensha` entry points running, plus two
Windows/WSL-specific gotchas that will bite again if skipped.

## One-time setup (inside WSL Ubuntu)

```sh
wsl
sudo apt update && sudo apt install -y build-essential golang-go
```

`build-essential` provides `gcc` (needed to link the native extensions);
`golang-go` is only needed if a gem's prebuilt platform binary is missing and
it falls back to compiling its Go sources locally (see the "if a native gem
insists on compiling" note below — normally unnecessary).

## Gotcha 1: the project path has a space in it — avoid `bundle exec`

The repo lives under `.../VSCode Projects/...` on the Windows-mounted drive.
`bundle exec` re-execs Ruby internally, and that re-exec breaks on the space,
failing with a nonsensical `invalid option -P` from Ruby itself. Confirmed by
reproducing the same command from a space-free path (`/tmp/...`), where it
worked fine.

**Workaround: don't use `bundle exec`.** Install gems into a local vendor
path, then put that path on `GEM_PATH` for a plain `ruby`/`rake` invocation
instead of routing through `bundle exec`.

## Gotcha 2: `rake` and `minitest` aren't in the Gemfile

Neither `11_tui`'s nor `10_standard_tool_library`'s `Gemfile` declares `rake`
or `minitest` — this is a pre-existing property of both steps, not something
introduced here. They're present as Ruby's own default gems instead. Two
consequences:

- `bundle exec rake test` fails outright: Bundler's exec wrapper refuses to
  activate `rake` because it isn't part of the bundle.
- Since we're avoiding `bundle exec` anyway (gotcha 1), this doesn't matter —
  plain `rake`, found via `PATH`, already sees the system's default `rake`
  and `minitest`. It just also needs the vendored `charm` stack on
  `GEM_PATH` so `require "boukensha"` (which requires `boukensha/tui`, which
  requires `bubbletea`) resolves.

## Commands

All run from WSL (`wsl -e bash -lc "..."` from a Windows shell, or directly
if you're already inside WSL). Substitute the repo path as needed.

```sh
REPO='/mnt/c/Users/Administrator/VSCode Projects/claude-code-camp-2026-Q2'
cd "$REPO/week1_baseline/ruby/11_tui"

# Install gems to a local path (not the system gem dir — that needs sudo —
# and not the default bundle path, to sidestep gotcha 1).
bundle config set --local path 'vendor/bundle'
bundle install

# Run the suite. No `bundle exec` (gotchas 1+2) — add the vendored gems to
# GEM_PATH instead so `require "boukensha"` finds `charm`/`bubbletea`/etc.
# alongside the system's default rake/minitest.
GEM_PATH="$(gem env gempath):$(pwd)/vendor/bundle/ruby/3.2.0" rake test
# => 22 runs, 65 assertions, 0 failures, 0 errors, 0 skips
```

Skips instead of passes for the `TestMcpClient`/`TestToolsMcp`/
`TestMcpServersConfig` tests mean `week0_explore/mud_manager` wasn't found at
`../../../../week0_explore/mud_manager` relative to `test/` — run from the
real repo checkout (not an isolated copy of just `11_tui`) so that relative
path resolves.

### Smoke test — plain REPL (`--no-tui`)

Boots the loader → config → MCP registration → REPL banner path without
needing a live LLM call; `/exit` piped on stdin exits immediately after the
banner.

```sh
cd "$REPO/week1_baseline/ruby/11_tui"
GEM_PATH="$(gem env gempath):$(pwd)/vendor/bundle/ruby/3.2.0" \
BOUKENSHA_DIR=/tmp/boukensha_smoke \
BOUKENSHA_PATH="$(pwd)" \
ANTHROPIC_API_KEY=dummy \
bash -c 'echo "/exit" | timeout 20 ruby -Ilib bin/boukensha --no-tui'
```

Expect the banner (`BOUKENSHA MUD Assistant (v0.11.1)`), a `servers:` line
showing the MCP tool count, then `Goodbye.` and a clean exit.

### Smoke test — TUI

`bubbletea` needs a real TTY (raw terminal mode), so allocate a pseudo-tty
with `script` when driving it non-interactively:

```sh
cd "$REPO/week1_baseline/ruby/11_tui"
GEM_PATH="$(gem env gempath):$(pwd)/vendor/bundle/ruby/3.2.0" \
BOUKENSHA_DIR=/tmp/boukensha_smoke \
BOUKENSHA_PATH="$(pwd)" \
ANTHROPIC_API_KEY=dummy \
script -qec 'timeout 8 ruby -Ilib bin/boukensha' /tmp/tui_smoke.log
cat /tmp/tui_smoke.log
```

Expect the charm four-zone layout to render (status bar with version/model/
context/tool count, a ticking clock, an idle input box) until the `timeout`
kills it (exit 124 — that's the timeout firing, not a crash).

### Throwaway `BOUKENSHA_DIR` used above

Both smoke tests point `BOUKENSHA_DIR` at a scratch config so the real
`mud-manager` binary doesn't need to be `gem install`ed first — `settings.yaml`
documents a `command: ruby, args: [.../bin/mud-manager, --mcp]` fallback for
exactly this:

```sh
mkdir -p /tmp/boukensha_smoke
cat > /tmp/boukensha_smoke/settings.yaml <<EOF
tasks:
  player:
    provider: anthropic
    model: claude-haiku-4-5
mcp_servers:
  mud:
    command: ruby
    args:    ["$REPO/week0_explore/mud_manager/bin/mud-manager", --mcp]
    prefix:  tbamud
    env:
      MUD_HOST:     localhost
      MUD_PORT:     "4000"
      MUD_NAME:     dummy
      MUD_PASSWORD: helloworld
EOF
```

## Cleanup — do not commit these

```sh
rm -rf "$REPO/week1_baseline/ruby/11_tui/vendor" \
       "$REPO/week1_baseline/ruby/11_tui/.bundle" \
       /tmp/boukensha_smoke /tmp/tui_smoke.log
```

`vendor/bundle` is ~225MB of Linux-only precompiled native gems — useless on
Windows and not something either step currently checks in (`10`'s tree has
no `vendor/`/`.bundle/` either). Regenerate it locally with the install
command above whenever the suite needs to run again; don't commit it.

## If a native gem insists on compiling from source

The precompiled `x86_64-linux-gnu` platform gems (`bubbletea`, `ntcharts`,
`lipgloss`, `glamour`, `bubblezone`) covered every dependency here, so this
wasn't needed in the end — but if a future gem version lacks a prebuilt
binary for your platform, `ntcharts`'s `ext/ntcharts/extconf.rb` documents
the two-stage build it expects:

```sh
cd path/to/gems/ntcharts-<version>/go
CGO_ENABLED=1 go build -buildmode=c-archive -o build/linux_amd64/libntcharts.a .
```

(`goos_arch` in the output path must match `extconf.rb`'s `detect_platform`
— e.g. `linux_amd64`, not `windows_x64`.) This requires `gcc` (cgo needs a C
compiler) — `build-essential` from the one-time setup above already covers
it. Re-run `gem install`/`bundle install` afterward so the extension links
against the archive you just built.
