defmodule NanoClaw.MessageLoop do
  @poll_ms 2_000

  @moduledoc """
  Polling GenServer that drives message delivery for polling-based channels
  (currently WhatsApp via the shared SQLite database).

  Every #{@poll_ms}ms it queries `messages` for rows newer than the last seen
  timestamp, groups them by `chat_jid`, and dispatches each batch to the
  matching `Group` GenServer via `Group.inbound_messages/2`.

  The high-water timestamp is persisted to the `router_state` table under the
  key `"last_timestamp"` so that a supervisor restart (or BEAM crash) picks up
  exactly where it left off with no duplicate or dropped messages.

  Webhook-capable channels (Telegram, Slack, Discord) bypass this loop
  entirely — their messages arrive via the HTTP router and go straight to
  the relevant `Group` process.
  """

  use GenServer

  alias NanoClaw.DB
  alias NanoClaw.Group
  alias NanoClaw.Repo

  require Logger

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

    messages
    |> Enum.group_by(& &1.chat_jid)
    |> Enum.each(fn {jid, msgs} -> dispatch_group(jid, msgs) end)

    new_ts = messages |> Enum.map(& &1.timestamp) |> Enum.max(fn -> state.last_ts end)
    if new_ts > state.last_ts, do: save_last_ts(new_ts)

    schedule_poll()
    {:noreply, %{state | last_ts: new_ts}}
  end

  defp dispatch_group(jid, messages) do
    case NanoClaw.Groups.folder_for_jid(jid) do
      nil -> :ok
      folder -> Group.inbound_messages(folder, messages)
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_ms)
  end

  defp load_last_ts do
    case Repo.get_by(DB.RouterState, key: "last_timestamp") do
      nil -> 0
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
