# NanoClaw — Elixir/OTP Port

An Elixir/OTP rewrite of [NanoClaw](../README.md): a personal Claude assistant that connects to messaging apps, runs Claude agents in isolated containers, and replies in chat.

This directory is a self-contained Mix project that lives alongside the original Node.js code. It reads the same SQLite database, uses the same container image, and preserves the same per-group isolation model.

## Phase status

| Phase | Status | What it covers |
|---|---|---|
| **Phase 1** | ✅ **This code** | OTP supervision tree, Ecto/SQLite, Group GenServer, MessageLoop polling, ContainerRunner (Port), stub Router |
| Phase 2 | 🔲 | `Plug.Router` — credential proxy + webhook receivers |
| Phase 3 | 🔲 | Channel behaviours, WhatsApp/Telegram GenServers, IPC watcher, task scheduler |
| Phase 4 | 🔲 | `Exile` subprocess streaming, `:fs` file watcher, LiveDashboard |

**Phase 1 limitation:** the `Router` stubs outbound messages to the logger. Responses appear in logs but are not sent back to WhatsApp. Full outbound delivery lands in Phase 3.

---

## Architecture

```
WhatsApp (Node.js channel)
    │  writes messages
    ▼
store/nanoclaw.db  (shared SQLite)
    │  polled every 2 s
    ▼
NanoClaw.MessageLoop  ──►  NanoClaw.Group (one per registered group)
                                  │
                                  │  Port.open / stdin JSON
                                  ▼
                           Docker container  (nanoclaw-agent image)
                                  │
                                  │  stdout marker frames
                                  ▼
                           NanoClaw.Router  ──►  [Phase 1: Logger]
                                               [Phase 3: WhatsApp outbound]
```

Every group is a GenServer. Its mailbox is the queue — no extra queue class needed. A container Port is owned by the GenServer; messages arriving while a container runs are buffered in `pending_messages` and drained automatically on exit.

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Elixir | ≥ 1.18 | Install via [asdf](https://asdf-vm.com) or [mise](https://mise.jdx.dev) — see below |
| Erlang/OTP | ≥ 26 | Installed automatically alongside Elixir by asdf/mise |
| Docker | any recent | Or Apple Container on macOS — see below |
| Claude API key | — | From [console.anthropic.com](https://console.anthropic.com) |
| Node.js | ≥ 20 | Required only for the WhatsApp channel (Phase 1 dependency) |

---

## 1. Install Elixir

**Recommended: use `mise` (replaces asdf, nvm, rbenv in one tool)**

```bash
# macOS
brew install mise

# Linux
curl https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc
source ~/.bashrc
```

```bash
# Install Elixir + Erlang
mise use --global erlang@27
mise use --global elixir@1.18

# Verify
elixir --version
# Erlang/OTP 27 ... Elixir 1.18.x
```

<details>
<summary>Alternative: asdf</summary>

```bash
asdf plugin add erlang
asdf plugin add elixir
asdf install erlang 27.2
asdf install elixir 1.18.2
asdf global erlang 27.2
asdf global elixir 1.18.2
```

</details>

<details>
<summary>Alternative: Homebrew (macOS, simpler but version-pinned)</summary>

```bash
brew install elixir
```

</details>

---

## 2. Install Docker (or Apple Container)

### Docker (macOS + Linux)

Download [Docker Desktop](https://www.docker.com/products/docker-desktop/) and start it, or on Linux:

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install docker.io
sudo usermod -aG docker $USER
newgrp docker
```

### Apple Container (macOS Apple Silicon — lighter weight)

Apple Container is a macOS-native container runtime that avoids the Docker VM overhead. Each container runs in its own lightweight Apple Virtualization Framework VM.

```bash
# Requires macOS 15+ and Apple Silicon
# Install from the GitHub releases page:
# https://github.com/apple/container/releases

# After installation, verify:
container --version

# Tell NanoClaw to use it instead of Docker:
export CONTAINER_RUNTIME=container
```

> Add `export CONTAINER_RUNTIME=container` to your `~/.zshrc` or `~/.bashrc` to make it permanent.

---

## 3. Build the agent container image

The container image is shared with the Node.js side — build it once from the repo root.

```bash
# From the nanoclaw/ repo root (not the elixir/ subdirectory)
cd ..
./container/build.sh
```

This tags the image as `nanoclaw-agent:latest`. The script respects `$CONTAINER_RUNTIME`, so if you set it to `container` above it will use Apple Container.

**Verify the build:**

```bash
echo '{"prompt":"What is 2+2?","sessionId":null,"groupFolder":"test","chatJid":"test@g.us","isMain":false,"assistantName":"Andy"}' \
  | docker run --rm -i \
      -e ANTHROPIC_API_KEY=your-key-here \
      -e ANTHROPIC_BASE_URL=https://api.anthropic.com \
      nanoclaw-agent
```

You should see output ending with `---NANOCLAW_OUTPUT_START---{"text":"4","sessionId":"..."}---NANOCLAW_OUTPUT_END---`.

---

## 4. Set up WhatsApp

WhatsApp connectivity is provided by the Node.js channel in Phase 1. The Elixir process reads from the same SQLite database the Node.js channel writes to.

### 4a. Install the Node.js NanoClaw with WhatsApp

From the repo root:

```bash
# From nanoclaw/ repo root
npm install
```

Install Claude Code if you haven't already:

```bash
npm install -g @anthropic-ai/claude-code
```

Run the setup skill to install the WhatsApp channel:

```bash
claude
# Inside the claude prompt:
/add-whatsapp
```

The `/add-whatsapp` skill will:
1. Pull the WhatsApp channel branch and merge it into your working tree
2. Run `npm install` to pick up the Baileys dependency
3. Build the TypeScript

### 4b. Authenticate WhatsApp

Start the Node.js service:

```bash
npm run dev
```

On first run it will print a **QR code** in the terminal. Open WhatsApp on your phone:

- **Android:** WhatsApp → ⋮ menu → Linked devices → Link a device → scan the QR code
- **iPhone:** WhatsApp → Settings → Linked devices → Link a device → scan the QR code

The QR code refreshes every ~20 seconds. If it expires before you scan it, a new one will appear automatically.

**Alternative: pairing code (no QR scanner needed)**

```bash
WHATSAPP_PAIRING_CODE=true npm run dev
```

Enter your phone number in international format when prompted (e.g. `+12025551234`). WhatsApp will send an 8-character code to your phone — enter it in the terminal.

### 4c. Register your main group

Once connected, the Node.js process will show:

```
[WhatsApp] Connected as +1 (202) 555-1234
```

In WhatsApp, send yourself a message (use the "Message yourself" / "Saved messages" contact):

```
@Andy register
```

The agent will register your self-chat as the `main` group. This creates an entry in the `registered_groups` table that the Elixir process will pick up.

### 4d. Where credentials are stored

WhatsApp session credentials are saved to `store/whatsapp-auth/` in the repo root. The messages database is `store/nanoclaw.db`. Both are `.gitignore`d — never commit them.

> **You can stop the Node.js process now.** The Elixir process will take over message handling. The WhatsApp channel in the Node process needs to stay running only if you need it for authentication or outbound sending (until Phase 3 adds a native Elixir WhatsApp channel).

---

## 5. Configure the Elixir app

### Environment variables

Create a `.env` file in the `elixir/` directory (or export these in your shell):

```bash
# Required
ANTHROPIC_API_KEY=sk-ant-...         # Your Claude API key

# Optional — defaults shown
ASSISTANT_NAME=Andy                   # Trigger word (@Andy by default)
CONTAINER_RUNTIME=docker              # or: container (Apple Container)
TZ=America/New_York                   # Timezone for message timestamps
ANTHROPIC_BASE_URL=http://host.docker.internal:4000/api/proxy
                                      # Points containers at the credential proxy.
                                      # Phase 2 adds the proxy; until then containers
                                      # need direct API access — set to:
                                      # https://api.anthropic.com
```

> **Phase 1 note on `ANTHROPIC_BASE_URL`:** Phase 2 adds the in-process credential proxy at `localhost:4000/api/proxy`. For now, set `ANTHROPIC_BASE_URL=https://api.anthropic.com` so containers can reach the API directly using `ANTHROPIC_API_KEY`.

### Database path

`config/config.exs` points to `../store/nanoclaw.db` by default — the same database the Node.js WhatsApp channel writes to. If your database is elsewhere:

```bash
export DATABASE_PATH=/absolute/path/to/nanoclaw.db
```

Or edit `config/config.exs` directly.

---

## 6. Install dependencies and run

```bash
# From the elixir/ directory
cd elixir/

mix deps.get

# Run the test suite to verify everything compiles
mix test

# Start the application
iex -S mix
```

On startup you will see:

```
[info] == Running 1 NanoClaw.Repo.Migrations.InitialSchema.change/0 forward
[info] == Migrated 1 in 0.0s
[info] GroupLoader: starting 1 group(s)
[info] Group started: main (123456789@s.whatsapp.net)
[info] MessageLoop starting from ts=1234567890123
```

> If pointing at an existing Node.js database, migrations will detect the tables already exist and skip. If the database is fresh, they will create the schema.

---

## 7. Test end-to-end

The quickest way to verify Phase 1 is working without needing WhatsApp:

```elixir
# Inside the iex -S mix session

# 1. Confirm the group loaded
Registry.lookup(NanoClaw.GroupRegistry, "main")
# => [{#PID<0.xxx.0>, nil}]

# 2. Inject a synthetic message
msg = %NanoClaw.DB.Message{
  id: 999_999,
  chat_jid: "123456789@s.whatsapp.net",   # must match your group's jid
  sender: "test",
  sender_name: "Test User",
  content: "@Andy what is 2+2?",
  timestamp: System.system_time(:millisecond),
  is_from_me: false,
  is_bot_message: false,
}

NanoClaw.Group.inbound_messages("main", [msg])

# 3. Watch the logs
```

Expected output:

```
[info] Container spawning for group: main
... (container output) ...
[info] [OUTBOUND → 123456789@s.whatsapp.net]
4
```

### What to check if it doesn't work

| Symptom | Likely cause |
|---|---|
| `Registry.lookup` returns `[]` | `registered_groups` table is empty — register a group via the Node.js process first, or insert a row manually |
| `Container runtime not found: docker` | Docker is not running, or `$CONTAINER_RUNTIME` points to a binary not in `$PATH` |
| `Port.open` raises | Container image `nanoclaw-agent` not built — run `../container/build.sh` |
| Output never appears | `ANTHROPIC_BASE_URL` still points at the Phase 2 proxy — set it to `https://api.anthropic.com` for Phase 1 |
| `Migrations already up` but group not found | The Node.js DB has data but no `registered_groups` row — register a group from WhatsApp first |

---

## 8. Run as a background service

### macOS (launchd)

Create `~/Library/LaunchAgents/com.nanoclaw.elixir.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.nanoclaw.elixir</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>cd /path/to/nanoclaw/elixir && mix run --no-halt</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>ANTHROPIC_API_KEY</key>
    <string>sk-ant-...</string>
    <key>ANTHROPIC_BASE_URL</key>
    <string>https://api.anthropic.com</string>
    <key>MIX_ENV</key>
    <string>prod</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/nanoclaw-elixir.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/nanoclaw-elixir.log</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.nanoclaw.elixir.plist
launchctl start com.nanoclaw.elixir

# View logs
tail -f /tmp/nanoclaw-elixir.log

# Stop
launchctl stop com.nanoclaw.elixir
launchctl unload ~/Library/LaunchAgents/com.nanoclaw.elixir.plist
```

### Linux (systemd)

Create `~/.config/systemd/user/nanoclaw-elixir.service`:

```ini
[Unit]
Description=NanoClaw Elixir
After=network.target

[Service]
Type=simple
WorkingDirectory=/path/to/nanoclaw/elixir
ExecStart=/usr/bin/env mix run --no-halt
Restart=on-failure
RestartSec=5
Environment=MIX_ENV=prod
Environment=ANTHROPIC_API_KEY=sk-ant-...
Environment=ANTHROPIC_BASE_URL=https://api.anthropic.com

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable nanoclaw-elixir
systemctl --user start nanoclaw-elixir

# View logs
journalctl --user -u nanoclaw-elixir -f

# Restart
systemctl --user restart nanoclaw-elixir
```

---

## Development

```bash
# Run tests
mix test

# Strict lint
mix credo --strict

# Auto-format (Styler runs as a mix format plugin — also fixes alias ordering)
mix format

# Interactive shell with the app running
iex -S mix
```

### Key files

| File | Purpose |
|---|---|
| `lib/nanoclaw/group.ex` | Core GenServer — message queue, container lifecycle, timers |
| `lib/nanoclaw/message_loop.ex` | 2-second polling loop, dispatches to Group GenServers |
| `lib/nanoclaw/container_runner.ex` | Opens Port, sends stdin JSON, parses stdout marker frames |
| `lib/nanoclaw/router.ex` | Outbound stub (Phase 1 logs; Phase 3 sends to channel) |
| `lib/nanoclaw/groups.ex` | DB lookup helpers — JID → folder mapping |
| `lib/nanoclaw/db/` | Ecto schemas + query functions |
| `priv/repo/migrations/` | Schema migrations (run automatically on startup) |
| `config/config.exs` | Database path, Ecto config |
| `config/test.exs` | In-memory SQLite for `mix test` |

---

## Environment variable reference

| Variable | Default | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | *(required)* | Claude API key injected into containers |
| `ANTHROPIC_BASE_URL` | `http://host.docker.internal:4000/api/proxy` | API endpoint for containers. Use `https://api.anthropic.com` until Phase 2 adds the proxy |
| `ASSISTANT_NAME` | `Andy` | Trigger word — messages must contain `@Andy` (or `@<name>`) |
| `CONTAINER_RUNTIME` | `docker` | Container binary: `docker` or `container` (Apple Container) |
| `TZ` | `America/New_York` | Timezone for message timestamp formatting inside containers |
| `DATABASE_PATH` | *(from config.exs)* | Override the SQLite path at runtime (prod only) |
