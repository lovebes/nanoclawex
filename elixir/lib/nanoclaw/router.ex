defmodule NanoClaw.Router do
  @moduledoc """
  Routes outbound messages to the appropriate channel.

  Phase 1 stub: logs every outbound message to the console.

  Phase 3 will replace the stub with channel dispatch:

      find_channel(jid) |> Channel.send_message(jid, text)

  where each channel GenServer implements the `NanoClaw.Channel` behaviour and
  self-registers in `NanoClaw.ChannelRegistry` on startup.
  """

  require Logger

  @doc "Send a message to a JID through the appropriate channel."
  def send_message(jid, text) do
    # Phase 1: stub — log to console
    Logger.info("[OUTBOUND → #{jid}]\n#{text}\n")
    # Phase 3: find_channel(jid) |> Channel.send_message(jid, text)
    :ok
  end
end
