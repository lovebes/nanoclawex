defmodule NanoClaw.DB.RegisteredGroup do
  @moduledoc """
  Ecto schema for the `registered_groups` table.

  Each row represents a chat group that NanoClaw monitors.  Key fields:

  - `jid` — the channel-specific chat identifier (primary key), e.g.
    `"123456789@s.whatsapp.net"` for WhatsApp.
  - `folder` — human-readable subdirectory name under `groups/`, used as the
    `Group` GenServer registry key.
  - `trigger_pattern` — regex that a message must match to invoke the agent.
    Ignored when `requires_trigger` is `false`.
  - `is_main` — marks the designated admin group whose agent can register new
    groups and manage scheduled tasks.
  - `container_config` — JSON blob of per-group container overrides (image
    name, extra mounts, env vars).
  """

  use Ecto.Schema

  @primary_key {:jid, :string, autogenerate: false}
  schema "registered_groups" do
    field(:name, :string)
    field(:folder, :string)
    field(:trigger_pattern, :string)
    field(:is_main, :boolean)
    field(:requires_trigger, :boolean)
    field(:container_config, :string)
    field(:added_at, :integer)
  end

  def all do
    NanoClaw.Repo.all(__MODULE__)
  end
end
