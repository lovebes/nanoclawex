# Phase 1 Implementation: Core OTP + Basic Message Flow

## Goal

A single hardcoded group receives a message, spawns a container, streams output, and sends the response back through a stub channel — all without any real messaging app connected. At the end of Phase 1, you can trigger this from `iex` and watch it work end-to-end.

## What We Are NOT Building in Phase 1

- Real channels (WhatsApp, Telegram, etc.)
- Credential proxy HTTP server
- IPC watcher
- Task scheduler
- Sender allowlists
- Multi-group support

---

## Project Setup

```bash
mix new nanoclaw --sup
cd nanoclaw
```

`mix.exs` dependencies:

```elixir
defp deps do
  [
    {:ecto_sql, "~> 3.11"},
    {:exqlite, "~> 0.13"},
    {:jason, "~> 1.4"},
  ]
end
```

Directory structure at end of Phase 1:

```
nanoclaw/
├── lib/
│   └── nanoclaw/
│       ├── application.ex       # supervision tree
│       ├── repo.ex              # Ecto repo
│       ├── db/
│       │   ├── message.ex       # Ecto schema
│       │   ├── registered_group.ex
│       │   └── session.ex
│       ├── group.ex             # Group GenServer
│       ├── message_loop.ex      # polling GenServer
│       ├── container_runner.ex  # Port wrapper
│       └── router.ex            # outbound stub
├── priv/
│   └── repo/
│       └── migrations/
│           └── 001_initial_schema.exs
└── config/
    ├── config.exs
    └── runtime.exs
```

---

## Step 1 — Ecto + SQLite

### `config/config.exs`

```elixir
import Config

config :nanoclaw, NanoClaw.Repo,
  database: Path.expand("../store/nanoclaw.db", __DIR__),
  journal_mode: :wal,
  cache_size: -64_000,
  temp_store: :memory

config :nanoclaw, ecto_repos: [NanoClaw.Repo]
```

The database path points at the existing Node project's SQLite file so Phase 1 can read real data without a migration.

### `lib/nanoclaw/repo.ex`

```elixir
defmodule NanoClaw.Repo do
  use Ecto.Repo,
    otp_app: :nanoclaw,
    adapter: Ecto.Adapters.Exqlite
end
```

### Migration — `priv/repo/migrations/001_initial_schema.exs`

Mirrors the existing Node schema exactly. Run only on a fresh DB — skip if pointing at the existing Node SQLite file.

```elixir
defmodule NanoClaw.Repo.Migrations.InitialSchema do
  use Ecto.Migration

  def change do
    create table(:messages, primary_key: false) do
      add :id, :integer, primary_key: true
      add :chat_jid, :string, null: false
      add :sender, :string
      add :sender_name, :string
      add :content, :text
      add :timestamp, :integer, null: false
      add :is_from_me, :boolean, default: false
      add :is_bot_message, :boolean, default: false
    end

    create index(:messages, [:chat_jid, :timestamp])

    create table(:chats, primary_key: false) do
      add :jid, :string, primary_key: true
      add :name, :string
      add :last_message_time, :integer
      add :channel, :string
      add :is_group, :boolean
    end

    create table(:registered_groups, primary_key: false) do
      add :jid, :string, primary_key: true
      add :name, :string
      add :folder, :string, null: false
      add :trigger_pattern, :string
      add :is_main, :boolean, default: false
      add :requires_trigger, :boolean, default: true
      add :container_config, :text  # stored as JSON string
      add :added_at, :integer
    end

    create table(:sessions, primary_key: false) do
      add :group_folder, :string, primary_key: true
      add :session_id, :string
    end

    create table(:router_state, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :string
    end
  end
end
```

### Schemas

**`lib/nanoclaw/db/message.ex`**

```elixir
defmodule NanoClaw.DB.Message do
  use Ecto.Schema
  import Ecto.Query

  @primary_key {:id, :integer, autogenerate: false}
  schema "messages" do
    field :chat_jid, :string
    field :sender, :string
    field :sender_name, :string
    field :content, :string
    field :timestamp, :integer
    field :is_from_me, :boolean
    field :is_bot_message, :boolean
  end

  def since(ts) do
    from m in __MODULE__,
      where: m.timestamp > ^ts and m.is_bot_message == false,
      order_by: [asc: m.timestamp]
  end

  def since_for_group(jid, ts) do
    from m in __MODULE__,
      where: m.chat_jid == ^jid and m.timestamp > ^ts,
      order_by: [asc: m.timestamp]
  end
end
```

**`lib/nanoclaw/db/registered_group.ex`**

```elixir
defmodule NanoClaw.DB.RegisteredGroup do
  use Ecto.Schema

  @primary_key {:jid, :string, autogenerate: false}
  schema "registered_groups" do
    field :name, :string
    field :folder, :string
    field :trigger_pattern, :string
    field :is_main, :boolean
    field :requires_trigger, :boolean
    field :container_config, :string  # JSON, decoded on read
    field :added_at, :integer
  end

  def all do
    NanoClaw.Repo.all(__MODULE__)
  end
end
```

**`lib/nanoclaw/db/session.ex`**

```elixir
defmodule NanoClaw.DB.Session do
  use Ecto.Schema
  import Ecto.Query

  @primary_key {:group_folder, :string, autogenerate: false}
  schema "sessions" do
    field :session_id, :string
  end

  def get(folder) do
    NanoClaw.Repo.get(__MODULE__, folder)
  end

  def upsert(folder, session_id) do
    NanoClaw.Repo.insert!(
      %__MODULE__{group_folder: folder, session_id: session_id},
      on_conflict: {:replace, [:session_id]},
      conflict_target: :group_folder
    )
  end
end
```

---

## Step 2 — `NanoClaw.ContainerRunner`

Wraps the container spawn. The Group GenServer owns the Port — `ContainerRunner` only builds args and parses output. This keeps container lifecycle management in the GenServer where it belongs.

**`lib/nanoclaw/container_runner.ex`**

```elixir
defmodule NanoClaw.ContainerRunner do
  @output_start "---NANOCLAW_OUTPUT_START---"
  @output_end "---NANOCLAW_OUTPUT_END---"

  @doc """
  Opens a Port for the container process. The calling GenServer
  will receive `{port, {:data, binary}}` and `{port, {:exit_status, n}}` messages.
  """
  def open(group, prompt, opts \\ []) do
    runtime = System.find_executable(runtime_bin())
    unless runtime, do: raise("Container runtime not found: #{runtime_bin()}")

    args = build_args(group, opts)
    env  = build_env(group) |> Enum.map(fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    port = Port.open({:spawn_executable, runtime}, [
      :binary,
      :exit_status,
      {:args, args},
      {:env, env},
    ])

    input = Jason.encode!(%{
      prompt:        prompt,
      sessionId:     group.session_id,
      groupFolder:   group.folder,
      chatJid:       group.jid,
      isMain:        group.is_main,
      assistantName: assistant_name(),
    })

    Port.command(port, input <> "\n")
    port
  end

  @doc """
  Parses accumulated stdout for a complete output marker pair.
  Returns `{:ok, payload, remaining_buffer}` or `:incomplete`.
  """
  def parse_output(buffer) do
    with start_idx when start_idx != nil <- find(buffer, @output_start),
         after_start = binary_part(buffer, start_idx + byte_size(@output_start), byte_size(buffer) - start_idx - byte_size(@output_start)),
         end_idx when end_idx != nil <- find(after_start, @output_end) do
      json = binary_part(after_start, 0, end_idx)
      remaining = binary_part(after_start, end_idx + byte_size(@output_end), byte_size(after_start) - end_idx - byte_size(@output_end))
      case Jason.decode(json) do
        {:ok, payload} -> {:ok, payload, remaining}
        {:error, _}    -> :incomplete
      end
    else
      _ -> :incomplete
    end
  end

  # --- private ---

  defp find(binary, pattern) do
    case :binary.match(binary, pattern) do
      {pos, _len} -> pos
      :nomatch    -> nil
    end
  end

  defp runtime_bin do
    System.get_env("CONTAINER_RUNTIME", "docker")
  end

  defp assistant_name do
    System.get_env("ASSISTANT_NAME", "Andy")
  end

  defp build_env(group) do
    base_url = System.get_env("ANTHROPIC_BASE_URL", "http://host.docker.internal:4000/api/proxy")
    [
      {"TZ", System.get_env("TZ", "America/New_York")},
      {"ANTHROPIC_BASE_URL", base_url},
      {"ANTHROPIC_API_KEY", "placeholder"},
    ]
  end

  defp build_args(group, _opts) do
    project_root = File.cwd!()
    groups_dir   = Path.join(project_root, "groups")
    group_dir    = Path.join(groups_dir, group.folder)

    # These mirror the Node container-runner mount scheme exactly
    [
      "run", "--rm", "-i",
      "-v", "#{group_dir}:/workspace:rw",
      # agent-runner source (customize per group later)
      "-v", "#{project_root}/container/agent-runner.js:/agent-runner.js:ro",
      "--env", "TZ",
      "--env", "ANTHROPIC_BASE_URL",
      "--env", "ANTHROPIC_API_KEY",
      "nanoclaw-agent",  # container image name
      "node", "/agent-runner.js"
    ]
  end
end
```

**Key design decisions:**
- `parse_output/1` returns `{:ok, payload, remaining}` — the remaining buffer is passed back so partial output after the marker isn't dropped
- Port is opened with `:binary` mode — chunks arrive as binaries, not char lists
- `:exit_status` flag means the port sends `{port, {:exit_status, n}}` on process exit rather than raising

---

## Step 3 — `NanoClaw.Group`

The core GenServer. One process per registered group.

**`lib/nanoclaw/group.ex`**

```elixir
defmodule NanoClaw.Group do
  use GenServer
  require Logger

  alias NanoClaw.{ContainerRunner, DB, Router}

  @idle_timeout_ms  30 * 60 * 1_000   # 30 min
  @container_timeout_ms 35 * 60 * 1_000

  defstruct [
    :jid,
    :name,
    :folder,
    :trigger_pattern,
    :is_main,
    :session_id,
    :last_agent_ts,
    :running_container,
    :container_timeout_ref,
    :idle_timeout_ref,
    pending_messages: [],
    output_buffer: "",
  ]

  # --- Public API ---

  def start_link(group_record) do
    GenServer.start_link(__MODULE__, group_record,
      name: via(group_record.folder))
  end

  def inbound_messages(folder, messages) do
    GenServer.cast(via(folder), {:inbound_messages, messages})
  end

  def via(folder) do
    {:via, Registry, {NanoClaw.GroupRegistry, folder}}
  end

  # --- Callbacks ---

  @impl true
  def init(record) do
    session = DB.Session.get(record.folder)

    state = %__MODULE__{
      jid:             record.jid,
      name:            record.name,
      folder:          record.folder,
      trigger_pattern: record.trigger_pattern,
      is_main:         record.is_main,
      session_id:      session && session.session_id,
      last_agent_ts:   load_last_agent_ts(record.folder),
    }

    Logger.info("Group started: #{record.folder} (#{record.jid})")
    {:ok, state}
  end

  # New messages from MessageLoop or webhook
  @impl true
  def handle_cast({:inbound_messages, messages}, state) do
    filtered = filter_trigger(messages, state)

    cond do
      filtered == [] ->
        {:noreply, state}

      state.running_container != nil ->
        # Container already running — queue messages
        {:noreply, %{state | pending_messages: state.pending_messages ++ filtered}}

      true ->
        new_state = run_container(filtered, state)
        {:noreply, new_state}
    end
  end

  # Streaming stdout from container
  @impl true
  def handle_info({port, {:data, chunk}}, %{running_container: port} = state) do
    buffer = state.output_buffer <> chunk

    case ContainerRunner.parse_output(buffer) do
      {:ok, payload, remaining} ->
        handle_output(payload, state)
        # Reset idle timeout on activity
        state = reset_idle_timer(state)
        {:noreply, %{state | output_buffer: remaining}}

      :incomplete ->
        {:noreply, %{state | output_buffer: buffer}}
    end
  end

  # Container process exited
  @impl true
  def handle_info({port, {:exit_status, status}}, %{running_container: port} = state) do
    Logger.info("Container exited (status #{status}) for group: #{state.folder}")
    state = cancel_timers(state)
    state = %{state | running_container: nil, output_buffer: ""}

    # Drain any pending messages that arrived while container was running
    case state.pending_messages do
      [] ->
        {:noreply, state}
      pending ->
        new_state = run_container(pending, %{state | pending_messages: []})
        {:noreply, new_state}
    end
  end

  # Idle timeout — close container stdin to allow graceful shutdown
  @impl true
  def handle_info(:idle_timeout, %{running_container: port} = state) when port != nil do
    Logger.info("Idle timeout for group: #{state.folder}, closing container stdin")
    Port.command(port, "")  # EOF
    {:noreply, state}
  end

  def handle_info(:idle_timeout, state), do: {:noreply, state}

  # Hard container timeout
  @impl true
  def handle_info(:container_timeout, %{running_container: port} = state) when port != nil do
    Logger.warning("Container timeout for group: #{state.folder}, killing port")
    Port.close(port)
    {:noreply, %{state | running_container: nil, output_buffer: ""}}
  end

  def handle_info(:container_timeout, state), do: {:noreply, state}

  # Port closed (no exit_status — shouldn't happen with :exit_status flag, but guard it)
  def handle_info({port, :closed}, %{running_container: port} = state) do
    {:noreply, %{state | running_container: nil, output_buffer: ""}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.session_id do
      DB.Session.upsert(state.folder, state.session_id)
    end
    :ok
  end

  # --- Private ---

  defp run_container(messages, state) do
    context  = build_context(messages, state)
    port     = ContainerRunner.open(state, context)

    container_ref = Process.send_after(self(), :container_timeout, @container_timeout_ms)
    idle_ref      = Process.send_after(self(), :idle_timeout, @idle_timeout_ms)

    last_ts = messages |> Enum.map(& &1.timestamp) |> Enum.max()
    save_last_agent_ts(state.folder, last_ts)

    %{state |
      running_container:    port,
      container_timeout_ref: container_ref,
      idle_timeout_ref:      idle_ref,
      last_agent_ts:         last_ts,
      output_buffer:         "",
    }
  end

  defp handle_output(%{"text" => text, "sessionId" => sid}, state) when is_binary(text) do
    # Strip <internal> reasoning blocks before sending
    outbound = Regex.replace(~r/<internal>.*?<\/internal>/s, text, "") |> String.trim()
    unless outbound == "", do: Router.send_message(state.jid, outbound)

    if sid && sid != state.session_id do
      DB.Session.upsert(state.folder, sid)
    end
  end

  defp handle_output(payload, state) do
    Logger.warning("Unexpected output payload for #{state.folder}: #{inspect(payload)}")
  end

  defp build_context(messages, state) do
    # Load full message history since last agent response for context
    history = NanoClaw.Repo.all(DB.Message.since_for_group(state.jid, state.last_agent_ts || 0))
    format_xml(history, messages)
  end

  defp format_xml(history, new_messages) do
    tz = System.get_env("TZ", "UTC")

    all = Enum.uniq_by(history ++ new_messages, & &1.id)

    rows = Enum.map_join(all, "\n", fn m ->
      time = DateTime.from_unix!(m.timestamp, :millisecond)
             |> Calendar.strftime("%Y-%m-%d %H:%M")
      sender = if m.is_from_me, do: "assistant", else: (m.sender_name || m.sender || "unknown")
      content = xml_escape(m.content || "")
      ~s(<message sender="#{sender}" time="#{time}">#{content}</message>)
    end)

    "<messages>\n#{rows}\n</messages>"
  end

  defp xml_escape(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp filter_trigger(messages, %{requires_trigger: false}), do: messages
  defp filter_trigger(messages, %{trigger_pattern: nil}), do: messages
  defp filter_trigger(messages, state) do
    pattern = Regex.compile!(state.trigger_pattern || "@#{assistant_name()}", [:caseless])
    Enum.filter(messages, fn m ->
      not m.is_from_me and Regex.match?(pattern, m.content || "")
    end)
  end

  defp assistant_name, do: System.get_env("ASSISTANT_NAME", "Andy")

  defp reset_idle_timer(state) do
    if state.idle_timeout_ref, do: Process.cancel_timer(state.idle_timeout_ref)
    ref = Process.send_after(self(), :idle_timeout, @idle_timeout_ms)
    %{state | idle_timeout_ref: ref}
  end

  defp cancel_timers(state) do
    if state.idle_timeout_ref, do: Process.cancel_timer(state.idle_timeout_ref)
    if state.container_timeout_ref, do: Process.cancel_timer(state.container_timeout_ref)
    %{state | idle_timeout_ref: nil, container_timeout_ref: nil}
  end

  defp load_last_agent_ts(folder) do
    case NanoClaw.Repo.get_by(DB.RouterState, key: "last_agent_ts:#{folder}") do
      nil    -> 0
      record -> String.to_integer(record.value)
    end
  end

  defp save_last_agent_ts(folder, ts) do
    NanoClaw.Repo.insert!(
      %DB.RouterState{key: "last_agent_ts:#{folder}", value: to_string(ts)},
      on_conflict: {:replace, [:value]},
      conflict_target: :key
    )
  end
end
```

---

## Step 4 — `NanoClaw.MessageLoop`

Polls for new messages and dispatches to group GenServers. Only needed for polling-based channels (WhatsApp, Gmail). Webhook channels will bypass this entirely.

**`lib/nanoclaw/message_loop.ex`**

```elixir
defmodule NanoClaw.MessageLoop do
  use GenServer
  require Logger

  alias NanoClaw.{DB, Repo, Group}

  @poll_ms 2_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    last_ts = load_last_ts()
    Logger.info("MessageLoop starting from ts=#{last_ts}")
    schedule_poll()
    {:ok, %{last_ts: last_ts}}
  end

  @impl true
  def handle_info(:poll, state) do
    messages = Repo.all(DB.Message.since(state.last_ts))

    unless messages == [] do
      messages
      |> Enum.group_by(& &1.chat_jid)
      |> Enum.each(fn {jid, msgs} ->
        # Look up group by jid — registered groups are keyed by folder in Registry
        # so we resolve jid → folder first
        case find_group_for_jid(jid) do
          nil   -> :ok
          folder -> Group.inbound_messages(folder, msgs)
        end
      end)
    end

    new_ts = messages |> Enum.map(& &1.timestamp) |> Enum.max(fn -> state.last_ts end)
    if new_ts > state.last_ts, do: save_last_ts(new_ts)

    schedule_poll()
    {:noreply, %{state | last_ts: new_ts}}
  end

  defp find_group_for_jid(jid) do
    # Groups are registered in Registry by folder, not jid
    # Walk registered groups to find matching jid
    NanoClaw.Groups.folder_for_jid(jid)
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_ms)
  end

  defp load_last_ts do
    case Repo.get_by(DB.RouterState, key: "last_timestamp") do
      nil    -> 0
      record -> String.to_integer(record.value)
    end
  end

  defp save_last_ts(ts) do
    Repo.insert!(
      %DB.RouterState{key: "last_timestamp", value: to_string(ts)},
      on_conflict: {:replace, [:value]},
      conflict_target: :key
    )
  end
end
```

---

## Step 5 — `NanoClaw.Router` (Stub)

In Phase 1, outbound messages just log to the console. Real channel routing comes in Phase 3.

**`lib/nanoclaw/router.ex`**

```elixir
defmodule NanoClaw.Router do
  require Logger

  @doc "Send a message to a JID through the appropriate channel."
  def send_message(jid, text) do
    # Phase 1: stub — log to console
    Logger.info("[OUTBOUND → #{jid}]\n#{text}\n")
    # Phase 3: find_channel(jid) |> Channel.send_message(jid, text)
    :ok
  end
end
```

---

## Step 6 — `NanoClaw.Groups`

Thin module that loads registered groups from DB and maps jid → folder for the MessageLoop.

**`lib/nanoclaw/groups.ex`**

```elixir
defmodule NanoClaw.Groups do
  alias NanoClaw.{Repo, DB}

  def all do
    Repo.all(DB.RegisteredGroup)
  end

  def folder_for_jid(jid) do
    case Repo.get(DB.RegisteredGroup, jid) do
      nil    -> nil
      record -> record.folder
    end
  end
end
```

---

## Step 7 — Supervision Tree

**`lib/nanoclaw/application.ex`**

```elixir
defmodule NanoClaw.Application do
  use Application

  @impl true
  def start(_type, _args) do
    groups = NanoClaw.Groups.all()

    group_children = Enum.map(groups, fn g ->
      {NanoClaw.Group, g}
    end)

    children = [
      NanoClaw.Repo,
      {Registry, keys: :unique, name: NanoClaw.GroupRegistry},
      {DynamicSupervisor, name: NanoClaw.Groups.Supervisor, strategy: :one_for_one},
    ] ++ group_children ++ [
      NanoClaw.MessageLoop,
    ]

    opts = [strategy: :one_for_one, name: NanoClaw.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

Groups are started statically on boot from the `registered_groups` table. Dynamic group registration (from IPC) comes in Phase 3 — at that point, `NanoClaw.Groups.Supervisor` (`DynamicSupervisor`) takes over for new groups.

---

## Step 8 — Missing Schema: `router_state`

Add this schema (used by Group and MessageLoop for cursor persistence):

**`lib/nanoclaw/db/router_state.ex`**

```elixir
defmodule NanoClaw.DB.RouterState do
  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}
  schema "router_state" do
    field :value, :string
  end
end
```

---

## Validation: How to Know Phase 1 Works

### 1. Unit test `ContainerRunner.parse_output/1`

This is the most important function to test in isolation — it handles partial chunks.

```elixir
# test/nanoclaw/container_runner_test.exs
defmodule NanoClaw.ContainerRunnerTest do
  use ExUnit.Case

  alias NanoClaw.ContainerRunner

  test "parses complete output" do
    json = Jason.encode!(%{"text" => "hello", "sessionId" => "abc"})
    buffer = "some prefix\n---NANOCLAW_OUTPUT_START---#{json}---NANOCLAW_OUTPUT_END---"
    assert {:ok, %{"text" => "hello"}, ""} = ContainerRunner.parse_output(buffer)
  end

  test "returns :incomplete on partial output" do
    assert :incomplete = ContainerRunner.parse_output("---NANOCLAW_OUTPUT_START---{\"text\":")
  end

  test "handles multiple output markers, returns first" do
    json1 = Jason.encode!(%{"text" => "first"})
    json2 = Jason.encode!(%{"text" => "second"})
    buffer = "---NANOCLAW_OUTPUT_START---#{json1}---NANOCLAW_OUTPUT_END---" <>
             "---NANOCLAW_OUTPUT_START---#{json2}---NANOCLAW_OUTPUT_END---"
    assert {:ok, %{"text" => "first"}, remaining} = ContainerRunner.parse_output(buffer)
    assert {:ok, %{"text" => "second"}, ""} = ContainerRunner.parse_output(remaining)
  end

  test "remaining buffer preserved after marker" do
    json = Jason.encode!(%{"text" => "hi"})
    buffer = "---NANOCLAW_OUTPUT_START---#{json}---NANOCLAW_OUTPUT_END---trailing stuff"
    assert {:ok, _, "trailing stuff"} = ContainerRunner.parse_output(buffer)
  end
end
```

### 2. Integration test via `iex`

Insert a test message directly into the DB, then watch the Group GenServer process it:

```elixir
# In iex -S mix

# 1. Check that the group loaded from DB
Registry.lookup(NanoClaw.GroupRegistry, "main")
# => [{#PID<0.xxx.0>, nil}]

# 2. Manually inject a message (bypasses MessageLoop)
msg = %NanoClaw.DB.Message{
  id: 999999,
  chat_jid: "your-main-jid@s.whatsapp.net",
  sender: "test",
  sender_name: "Test User",
  content: "@Andy what is 2+2?",
  timestamp: System.system_time(:millisecond),
  is_from_me: false,
  is_bot_message: false,
}
NanoClaw.Group.inbound_messages("main", [msg])

# 3. Watch logs for container spawn and [OUTBOUND → ...] response
```

### 3. What success looks like

```
[info] Group started: main (xxx@s.whatsapp.net)
[info] MessageLoop starting from ts=1234567890
[info] Container spawning for group: main
... (container output lines) ...
[info] [OUTBOUND → xxx@s.whatsapp.net]
4
```

### 4. Failure modes to watch for

| Symptom | Likely cause |
|---|---|
| `Port.open` raises | Container runtime not in PATH, image not built |
| Output never parsed | Marker mismatch — check agent-runner.js output format |
| Session not persisted | `router_state` table missing (run migration) |
| Group not found in Registry | `registered_groups` table empty — insert a test row |
| Buffer fills but never resolves | Partial chunk arriving — check `parse_output` with real agent output |

---

## Definition of Done

Phase 1 is complete when:

- [ ] `mix test` passes (ContainerRunner unit tests)
- [ ] `iex` manual injection triggers a container and produces `[OUTBOUND]` log
- [ ] Session ID is persisted to `sessions` table after first run
- [ ] Killing the BEAM and restarting resumes from the correct `last_ts` cursor
- [ ] Supervisor restarts a crashed Group GenServer and it re-reads state from DB correctly
