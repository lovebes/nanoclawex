defmodule NanoClaw.Group do
  @moduledoc """
  GenServer representing a single registered chat group.

  One `Group` process runs per entry in the `registered_groups` table. It owns
  the full lifecycle of a container invocation:

  1. Receives inbound messages via `inbound_messages/2` (cast from `MessageLoop`
     or a webhook handler).
  2. Filters messages against the group's trigger pattern.
  3. Builds an XML message-history prompt and spawns a container via
     `ContainerRunner.open/3`, holding the `Port` reference in state.
  4. Accumulates streaming stdout until `ContainerRunner.parse_output/1` finds
     a complete `---NANOCLAW_OUTPUT_START---…---NANOCLAW_OUTPUT_END---` frame,
     then forwards the payload to `Router.send_message/2`.
  5. While a container is running, additional inbound messages are queued in
     `pending_messages` and drained automatically once the container exits.

  Session IDs (Claude SDK continuation tokens) are persisted to the `sessions`
  table on change and on process termination so that a supervisor restart
  resumes the same conversation.

  Two timers are active during a container run:
  - **idle timeout** (30 min) — sends EOF to stdin, allowing the agent to wrap
    up gracefully.
  - **container timeout** (35 min) — force-closes the port if the agent hangs.
  """

  use GenServer

  alias NanoClaw.ContainerRunner
  alias NanoClaw.DB
  alias NanoClaw.Router

  require Logger

  @idle_timeout_ms 30 * 60 * 1_000
  @container_timeout_ms 35 * 60 * 1_000

  defstruct [
    :jid,
    :name,
    :folder,
    :trigger_pattern,
    :is_main,
    :requires_trigger,
    :session_id,
    :last_agent_ts,
    :running_container,
    :container_timeout_ref,
    :idle_timeout_ref,
    pending_messages: [],
    output_buffer: ""
  ]

  # --- Public API ---

  def start_link(group_record) do
    GenServer.start_link(__MODULE__, group_record, name: via(group_record.folder))
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
    session_id =
      case DB.Session.get(record.folder) do
        nil -> nil
        session -> session.session_id
      end

    state = %__MODULE__{
      jid: record.jid,
      name: record.name,
      folder: record.folder,
      trigger_pattern: record.trigger_pattern,
      is_main: record.is_main,
      requires_trigger: record.requires_trigger,
      session_id: session_id,
      last_agent_ts: load_last_agent_ts(record.folder)
    }

    Logger.info("Group started: #{record.folder} (#{record.jid})")
    {:ok, state}
  end

  @impl true
  def handle_cast({:inbound_messages, messages}, state) do
    filtered = filter_trigger(messages, state)

    cond do
      filtered == [] ->
        {:noreply, state}

      state.running_container != nil ->
        {:noreply, %{state | pending_messages: state.pending_messages ++ filtered}}

      true ->
        new_state = run_container(filtered, state)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{running_container: port} = state) do
    buffer = state.output_buffer <> chunk

    case ContainerRunner.parse_output(buffer) do
      {:ok, payload, remaining} ->
        handle_output(payload, state)
        state = reset_idle_timer(state)
        {:noreply, %{state | output_buffer: remaining}}

      :incomplete ->
        {:noreply, %{state | output_buffer: buffer}}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{running_container: port} = state) do
    Logger.info("Container exited (status #{status}) for group: #{state.folder}")
    state = cancel_timers(state)
    state = %{state | running_container: nil, output_buffer: ""}

    case state.pending_messages do
      [] ->
        {:noreply, state}

      pending ->
        new_state = run_container(pending, %{state | pending_messages: []})
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(:idle_timeout, %{running_container: port} = state) when port != nil do
    Logger.info("Idle timeout for group: #{state.folder}, closing container stdin")
    Port.command(port, "")
    {:noreply, state}
  end

  def handle_info(:idle_timeout, state), do: {:noreply, state}

  @impl true
  def handle_info(:container_timeout, %{running_container: port} = state) when port != nil do
    Logger.warning("Container timeout for group: #{state.folder}, killing port")
    Port.close(port)
    {:noreply, %{state | running_container: nil, output_buffer: ""}}
  end

  def handle_info(:container_timeout, state), do: {:noreply, state}

  def handle_info({port, :closed}, %{running_container: port} = state) do
    {:noreply, %{state | running_container: nil, output_buffer: ""}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{session_id: nil}), do: :ok

  def terminate(_reason, state) do
    DB.Session.upsert(state.folder, state.session_id)
    :ok
  end

  # --- Private ---

  defp run_container(messages, state) do
    context = build_context(messages, state)
    port = ContainerRunner.open(state, context)

    container_ref = Process.send_after(self(), :container_timeout, @container_timeout_ms)
    idle_ref = Process.send_after(self(), :idle_timeout, @idle_timeout_ms)

    last_ts = messages |> Enum.map(& &1.timestamp) |> Enum.max()
    save_last_agent_ts(state.folder, last_ts)

    %{
      state
      | running_container: port,
        container_timeout_ref: container_ref,
        idle_timeout_ref: idle_ref,
        last_agent_ts: last_ts,
        output_buffer: ""
    }
  end

  defp handle_output(%{"text" => text, "sessionId" => sid}, state) when is_binary(text) do
    outbound = ~r/<internal>.*?<\/internal>/s |> Regex.replace(text, "") |> String.trim()
    if outbound != "", do: Router.send_message(state.jid, outbound)

    # Use is_binary/1 guard — sid from Jason decode is either a string or nil,
    # so we assert the type explicitly rather than relying on truthiness.
    if is_binary(sid) and sid != state.session_id do
      DB.Session.upsert(state.folder, sid)
    end
  end

  defp handle_output(payload, state) do
    Logger.warning("Unexpected output payload for #{state.folder}: #{inspect(payload)}")
  end

  defp build_context(messages, state) do
    history = NanoClaw.Repo.all(DB.Message.since_for_group(state.jid, state.last_agent_ts || 0))
    format_xml(history, messages)
  end

  defp format_xml(history, new_messages) do
    all = Enum.uniq_by(history ++ new_messages, & &1.id)

    rows =
      Enum.map_join(all, "\n", fn m ->
        time = m.timestamp |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d %H:%M")
        sender = if m.is_from_me, do: "assistant", else: m.sender_name || m.sender || "unknown"
        ~s(<message sender="#{sender}" time="#{time}">#{xml_escape(m.content || "")}</message>)
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

  # Pattern match on requires_trigger and trigger_pattern to avoid relying on
  # truthiness — see "Non-assertive Pattern Matching" anti-pattern.
  defp filter_trigger(messages, %{requires_trigger: false}), do: messages
  defp filter_trigger(messages, %{trigger_pattern: nil}), do: messages

  defp filter_trigger(messages, %{trigger_pattern: pattern_str}) do
    pattern = Regex.compile!(pattern_str, [:caseless])

    Enum.filter(messages, fn m ->
      not m.is_from_me and Regex.match?(pattern, m.content || "")
    end)
  end

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
      nil -> 0
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
