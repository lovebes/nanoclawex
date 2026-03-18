defmodule NanoClaw.DB.Message do
  @moduledoc """
  Ecto schema for the `messages` table and reusable query helpers.

  `since/1` is used by `MessageLoop` to poll for new inbound messages across
  all groups.  `since_for_group/2` is used by `Group` to load the full
  conversation history for a specific chat before invoking the agent, so the
  agent has context for the current exchange.
  """

  use Ecto.Schema

  import Ecto.Query

  @primary_key {:id, :integer, autogenerate: false}
  schema "messages" do
    field(:chat_jid, :string)
    field(:sender, :string)
    field(:sender_name, :string)
    field(:content, :string)
    field(:timestamp, :integer)
    field(:is_from_me, :boolean)
    field(:is_bot_message, :boolean)
  end

  def since(ts) do
    from(m in __MODULE__,
      where: m.timestamp > ^ts and m.is_bot_message == false,
      order_by: [asc: m.timestamp]
    )
  end

  def since_for_group(jid, ts) do
    from(m in __MODULE__,
      where: m.chat_jid == ^jid and m.timestamp > ^ts,
      order_by: [asc: m.timestamp]
    )
  end
end
