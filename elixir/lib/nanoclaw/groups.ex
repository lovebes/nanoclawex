defmodule NanoClaw.Groups do
  @moduledoc """
  Read-only interface to the `registered_groups` table.

  Groups are keyed by their chat JID (e.g. `"123@s.whatsapp.net"`) in the
  database, but the `Group` GenServer registry uses the human-readable
  `folder` name as the key.  `folder_for_jid/1` bridges the two.
  """

  alias NanoClaw.DB
  alias NanoClaw.Repo

  def all do
    Repo.all(DB.RegisteredGroup)
  end

  def folder_for_jid(jid) do
    case Repo.get(DB.RegisteredGroup, jid) do
      nil -> nil
      record -> record.folder
    end
  end
end
