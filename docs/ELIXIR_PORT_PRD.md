# PRD: NanoClaw — Elixir/OTP Port

## Overview

Port NanoClaw from Node.js to Elixir/OTP. The UI is the messaging app (WhatsApp, Telegram, Slack, etc.) — NanoClaw is a background daemon that connects to those channels, runs Claude agents in containers, and responds in chat. No browser, no dashboard, no CLI interaction needed.

The core thesis: every major runtime concept in NanoClaw already has a direct, idiomatic Elixir primitive. The result is a simplification — less boilerplate, stronger fault tolerance, and a supervision tree that replaces all manual crash recovery. A thin `Plug.Router` (not full Phoenix) handles the credential proxy and inbound webhooks.

---

## The Interface

```
Your phone (WhatsApp / Telegram / Slack)
    ↓  "@Andy do something"
NanoClaw daemon (Mac / Linux server)
    ↓  spawns container, runs Claude agent
    ↑  streams response back
Your phone
    ↑  reply appears in the same chat
```

Admin operations (register groups, manage scheduled tasks) happen the same way — by messaging the agent from the designated "main" group. No separate admin tool exists or is needed.

---

## Mapping: Node.js → Elixir

| Node.js Concept | Elixir Equivalent |
|---|---|
| Single process + polling loop | GenServer with `Process.send_after` |
| Per-group queue (GroupQueue) | GenServer per group (isolated mailbox) |
| MAX_CONCURRENT_CONTAINERS semaphore | `DynamicSupervisor` + counting |
| Channel registry (`Map<name, factory>`) | `Elixir.Registry` + `Behaviour` |
| SQLite via better-sqlite3 | Ecto + `exqlite` |
| Filesystem IPC polling | GenServer polling `File.ls` |
| Container spawn + streaming stdout | `Port` or `Exile` |
| Session state in SQLite + in-memory map | GenServer state (ETS for reads) |
| Task scheduler (cron/interval/once) | `Quantum` or custom GenServer |
| Crash recovery (recoverPendingMessages) | Supervisor restart strategy |
| Credential proxy (standalone Node HTTP server) | `Plug.Router` route |
| Telegram/Slack/Discord webhook receivers | `Plug.Router` routes |

---

## Architecture

### OTP Supervision Tree

```
NanoClaw.Application
├── NanoClaw.Repo                         (Ecto SQLite)
├── NanoClaw.Channels.Supervisor          (one_for_one)
│   ├── NanoClaw.Channels.WhatsApp        (GenServer, polling-based)
│   ├── NanoClaw.Channels.Telegram        (GenServer, webhook-driven)
│   └── ...
├── NanoClaw.Groups.Supervisor            (DynamicSupervisor)
│   ├── NanoClaw.Group (main)             (GenServer, one per registered group)
│   ├── NanoClaw.Group (work)             (GenServer)
│   └── ...
├── NanoClaw.MessageLoop                  (GenServer, polling-only channels)
├── NanoClaw.IPC.Watcher                  (GenServer, replaces ipc.ts)
├── NanoClaw.TaskScheduler                (GenServer or Quantum)
├── NanoClaw.ContainerPool                (DynamicSupervisor, MAX_CONCURRENT)
└── Plug.Cowboy                           (HTTP, credential proxy + webhooks only)
    ├── POST /api/proxy                   (credential proxy — replaces Node HTTP server)
    ├── POST /webhooks/telegram
    ├── POST /webhooks/slack
    └── POST /webhooks/discord
```

---

## Component Design

### 1. `NanoClaw.Group` — The Core Simplification

In Node, a "group" is scattered across:
- `sessions` map in index.ts
- `lastAgentTimestamp` map in index.ts
- GroupQueue instance
- Per-group state in SQLite

In Elixir, a group **is** a GenServer. All state lives in it.

```elixir
defmodule NanoClaw.Group do
  use GenServer

  defstruct [
    :jid,
    :name,
    :folder,
    :trigger_pattern,
    :is_main,
    :session_id,          # Claude SDK session, persisted to DB on update
    :last_agent_ts,       # message cursor for this group
    :running_container,   # Port ref or nil (serializes execution)
    :pending_messages,    # queue of messages waiting while container runs
    :container_timer,     # idle timeout ref
    :output_buffer,       # partial stdout accumulator for marker parsing
  ]

  # Called by MessageLoop or webhook router when new messages arrive
  def handle_cast({:inbound_messages, messages}, state) do
    # If container running, buffer into pending_messages
    # Otherwise, format XML context and spawn container
  end

  # Streaming stdout from container
  def handle_info({port, {:data, chunk}}, %{running_container: port} = state) do
    buffer = state.output_buffer <> chunk
    case NanoClaw.ContainerRunner.parse_output(buffer) do
      {:ok, output} ->
        NanoClaw.Router.route_outbound(state.jid, output["text"])
        {:noreply, %{state | output_buffer: ""}}
      :incomplete ->
        {:noreply, %{state | output_buffer: buffer}}
    end
  end

  # Container process exited
  def handle_info({:DOWN, _, :port, port, _reason}, %{running_container: port} = state) do
    # Drain pending_messages if any, else go idle
    {:noreply, %{state | running_container: nil, output_buffer: ""}}
  end

  # Idle timeout — close container stdin gracefully
  def handle_info(:idle_timeout, state) do
    Port.close(state.running_container)
    {:noreply, state}
  end
end
```

**Why this is simpler than Node**: No GroupQueue class. No semaphore for per-group serialization. The GenServer mailbox IS the queue. Messages pile up in the process inbox while a container runs; the group drains them on `{:DOWN, ...}`.

---

### 2. `NanoClaw.ContainerRunner` — Port-based Process I/O

```elixir
defmodule NanoClaw.ContainerRunner do
  def spawn_container(group, prompt, opts \\ []) do
    args = build_args(group, opts)
    port = Port.open({:spawn_executable, container_runtime()}, [
      :binary,
      :exit_status,
      {:args, args},
      {:env, build_env(group)},
    ])
    Port.command(port, Jason.encode!(build_input(group, prompt)))
    port
  end

  def parse_output(buffer) do
    case Regex.run(~r/---NANOCLAW_OUTPUT_START---(.*?)---NANOCLAW_OUTPUT_END---/s, buffer) do
      [_, json] -> {:ok, Jason.decode!(json)}
      nil       -> :incomplete
    end
  end
end
```

For fully streaming line-by-line output, upgrade to `Exile` (NIF-based subprocess library) in a later pass — better backpressure and binary handling than raw Port.

---

### 3. `NanoClaw.MessageLoop` — Polling Channels Only

Webhook-capable channels (Telegram, Slack, Discord) bypass this entirely — their messages arrive via the Plug router and go straight to the Group GenServer. The MessageLoop only serves polling channels (WhatsApp, Gmail).

```elixir
defmodule NanoClaw.MessageLoop do
  use GenServer

  @poll_ms 2_000

  def handle_info(:poll, state) do
    messages = Repo.all(new_messages_query(state.last_ts))

    messages
    |> Enum.group_by(& &1.chat_jid)
    |> Enum.each(fn {jid, msgs} ->
      case Registry.lookup(NanoClaw.GroupRegistry, jid) do
        [{pid, _}] -> GenServer.cast(pid, {:inbound_messages, msgs})
        []         -> :ok
      end
    end)

    new_ts = messages |> Enum.map(& &1.timestamp) |> Enum.max(fn -> state.last_ts end)
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, %{state | last_ts: new_ts}}
  end
end
```

Crash recovery (`recoverPendingMessages`) disappears — the Supervisor restarts `MessageLoop` and it re-reads the last persisted `last_ts` from DB.

---

### 4. Plug Router — Credential Proxy + Webhooks

A single `Plug.Router` replaces both the standalone Node credential proxy process and adds webhook receivers for push-capable channels. No full web framework needed.

```elixir
defmodule NanoClaw.Web.Router do
  use Plug.Router

  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :match
  plug :dispatch

  # Credential proxy — containers point ANTHROPIC_BASE_URL here
  post "/api/proxy" do
    {:ok, body, conn} = read_body(conn)
    headers = inject_real_credentials(get_req_header(conn, "authorization"))
    response = NanoClaw.AnthropicProxy.forward(conn.request_path, headers, body)
    send_resp(conn, response.status, response.body)
  end

  # Webhook receivers — zero polling latency for push channels
  post "/webhooks/telegram" do
    jid = NanoClaw.Channels.Telegram.jid_from_update(conn.body_params)
    stored = NanoClaw.DB.store_message(jid, conn.body_params)
    case Registry.lookup(NanoClaw.GroupRegistry, jid) do
      [{pid, _}] -> GenServer.cast(pid, {:inbound_messages, [stored]})
      []         -> :ok
    end
    send_resp(conn, 200, "ok")
  end

  post "/webhooks/slack" do
    # similar
  end

  post "/webhooks/discord" do
    # similar
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
```

Started in the supervision tree as:
```elixir
{Plug.Cowboy, scheme: :http, plug: NanoClaw.Web.Router, options: [port: 4000]}
```

---

### 5. `NanoClaw.Channels` — Behaviour-based Channel System

```elixir
defmodule NanoClaw.Channel do
  @callback connect() :: :ok | {:error, term()}
  @callback disconnect() :: :ok
  @callback send_message(jid :: String.t(), text :: String.t()) :: :ok | {:error, term()}
  @callback owns_jid?(jid :: String.t()) :: boolean()
  @callback connected?() :: boolean()
  @optional_callbacks [set_typing: 2, sync_groups: 1]
end
```

Each channel implements this behaviour and is a GenServer. Channels self-register in `Elixir.Registry` on init — no factory map needed.

```elixir
defmodule NanoClaw.Channels.Telegram do
  use GenServer
  @behaviour NanoClaw.Channel

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(:telegram))
  end

  defp via(name), do: {:via, Registry, {NanoClaw.ChannelRegistry, name}}
end
```

Finding the right channel for an outbound message:

```elixir
def find_channel(jid) do
  Registry.select(NanoClaw.ChannelRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}])
  |> Enum.find(fn pid -> GenServer.call(pid, {:owns_jid?, jid}) end)
end
```

---

### 6. `NanoClaw.IPC.Watcher` — Filesystem IPC

Unchanged protocol — containers still write JSON files to `data/ipc/{group}/messages/`. The Elixir watcher replaces the Node polling loop.

```elixir
defmodule NanoClaw.IPC.Watcher do
  use GenServer

  @poll_ms 1_000

  def handle_info(:poll, state) do
    for group <- NanoClaw.Groups.all() do
      dir = Path.join([ipc_dir(), group.folder, "messages"])
      case File.ls(dir) do
        {:ok, files} ->
          Enum.each(files, &process_ipc_file(group, Path.join(dir, &1)))
        _ -> :ok
      end
    end
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, state}
  end

  defp process_ipc_file(group, path) do
    with {:ok, raw} <- File.read(path),
         {:ok, cmd} <- Jason.decode(raw),
         :ok        <- File.rm(path) do
      NanoClaw.IPC.dispatch(group, cmd)
    end
  end
end
```

Optionally replace with `:fs` (inotify/kqueue) for event-driven file watching — sub-millisecond IPC latency on macOS.

---

### 7. `NanoClaw.TaskScheduler` — Cron/Interval/Once

Use `Quantum` for cron expressions. `interval` and `once` types managed as GenServer timers.

```elixir
defmodule NanoClaw.TaskScheduler do
  use GenServer

  @check_ms 60_000

  def handle_info(:check, state) do
    NanoClaw.Repo.all(due_tasks_query())
    |> Enum.each(&run_task/1)
    Process.send_after(self(), :check, @check_ms)
    {:noreply, state}
  end

  defp run_task(task) do
    case Registry.lookup(NanoClaw.GroupRegistry, task.group_folder) do
      [{pid, _}] ->
        GenServer.cast(pid, {:scheduled_task, task})
        NanoClaw.DB.log_task_run(task)
      [] ->
        NanoClaw.DB.log_task_run(task, {:error, :group_not_found})
    end
    update_next_run(task)
  end
end
```

---

### 8. Database — Ecto + `exqlite`

Schema mirrors existing SQLite tables exactly. Ecto migrations replace manual `CREATE TABLE IF NOT EXISTS` calls.

```elixir
defmodule NanoClaw.Message do
  use Ecto.Schema
  schema "messages" do
    field :chat_jid, :string
    field :sender, :string
    field :sender_name, :string
    field :content, :string
    field :timestamp, :integer
    field :is_from_me, :boolean
    field :is_bot_message, :boolean
  end
end

defmodule NanoClaw.RegisteredGroup do
  use Ecto.Schema
  schema "registered_groups" do
    field :jid, :string
    field :name, :string
    field :folder, :string
    field :trigger_pattern, :string
    field :is_main, :boolean
    field :requires_trigger, :boolean
    field :container_config, :map
  end
end

defmodule NanoClaw.ScheduledTask do
  use Ecto.Schema
  schema "scheduled_tasks" do
    field :group_folder, :string
    field :chat_jid, :string
    field :prompt, :string
    field :schedule_type, Ecto.Enum, values: [:cron, :interval, :once]
    field :schedule_value, :string
    field :context_mode, Ecto.Enum, values: [:isolated, :group]
    field :next_run, :utc_datetime
    field :status, Ecto.Enum, values: [:active, :paused, :completed, :cancelled]
    has_many :run_logs, NanoClaw.TaskRunLog
  end
end
```

Session IDs live in ETS during runtime, persisted to DB on change — reads are free, writes are rare.

---

## What Disappears

| Node component | Why it's gone |
|---|---|
| GroupQueue class | GenServer mailbox is the queue |
| `sessions` map in index.ts | GenServer state per group |
| `lastAgentTimestamp` map in index.ts | GenServer state per group |
| `recoverPendingMessages()` | Supervisor restart + re-read last DB cursor |
| `MAX_CONCURRENT_CONTAINERS` semaphore | `DynamicSupervisor` child count + guard |
| Channel factory registry | `Elixir.Registry` + Behaviour |
| Manual state persistence to `router_state` | GenServer `terminate/2` flushes to DB |
| Standalone credential proxy Node process | One route in `Plug.Router` |

---

## What Stays the Same

- Container runtime (Docker/Apple Container) — unchanged
- Volume mount scheme — unchanged
- Filesystem IPC protocol — unchanged (containers still write JSON files)
- Per-group isolation model — unchanged
- Output marker parsing (`---NANOCLAW_OUTPUT_START---`) — unchanged
- SQLite as the database — unchanged (Ecto + exqlite)
- `CLAUDE.md` per group — unchanged
- The UI — your messaging app, unchanged

---

## Migration Path

### Phase 1 — Core OTP + Basic Message Flow
1. Set up OTP application, Ecto + exqlite with existing schema
2. Implement `NanoClaw.Group` GenServer (state + container spawning via Port)
3. Implement `NanoClaw.MessageLoop` GenServer (polling + dispatch)
4. Implement `NanoClaw.ContainerRunner` (Port-based, stream parsing)
5. Wire supervision tree — single-group message → response works end-to-end

### Phase 2 — HTTP Layer
6. Add `Plug.Router` with credential proxy route — unblocks container execution
7. Add webhook routes for Telegram, Slack, Discord

### Phase 3 — Channels + Full Parity
8. Define `NanoClaw.Channel` behaviour
9. Port channels as GenServers (start with Telegram — webhook-native, simplest auth)
10. Port WhatsApp channel (polling-based, most complex auth)
11. Implement `NanoClaw.IPC.Watcher`
12. Implement `NanoClaw.TaskScheduler`
13. Sender allowlist enforcement in `NanoClaw.Group`

### Phase 4 — Polish
14. Replace Port with `Exile` for cleaner subprocess streaming
15. Replace IPC file polling with `:fs` (inotify/kqueue) for event-driven IPC
16. Add `Phoenix.LiveDashboard` as a single optional dep if runtime introspection is wanted (no custom LiveViews needed — it reads GenServer/process state out of the box)

---

## Key Dependencies

```elixir
defp deps do
  [
    {:plug_cowboy, "~> 2.7"},          # HTTP server (credential proxy + webhooks)
    {:ecto_sql, "~> 3.11"},
    {:exqlite, "~> 0.13"},             # SQLite adapter for Ecto
    {:jason, "~> 1.4"},                # JSON
    {:quantum, "~> 3.5"},              # cron scheduler
    {:crontab, "~> 1.1"},              # cron expression parsing
    {:exile, "~> 0.10"},               # subprocess streaming (Phase 4 upgrade from Port)
    {:fs, "~> 3.4"},                   # inotify/kqueue for IPC watching (Phase 4)
  ]
end
```

---

## Estimated LOC Comparison

| Component | Node (current) | Elixir |
|---|---|---|
| Orchestrator (Group + MessageLoop) | ~350 lines | ~200 lines |
| Container runner | ~250 lines | ~120 lines |
| IPC watcher | ~200 lines | ~80 lines |
| Task scheduler | ~180 lines | ~100 lines |
| DB layer | ~300 lines | ~200 lines |
| Router/channels | ~200 lines | ~150 lines |
| Credential proxy + webhooks | ~150 lines | ~60 lines |
| **Total** | **~1,630 lines** | **~910 lines** |

The reduction comes from Elixir's process model absorbing all the concurrency infrastructure that Node requires explicit code for.
