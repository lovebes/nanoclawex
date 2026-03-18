defmodule NanoClaw.DB.Session do
  @moduledoc """
  Ecto schema and persistence helpers for Claude SDK session IDs.

  A session ID is an opaque continuation token issued by the Claude Agent SDK
  that allows a subsequent container invocation to resume an existing
  conversation rather than starting a new one.  It is keyed by `group_folder`
  so each group maintains its own independent conversation thread.

  `upsert/2` uses an insert-or-replace so callers never need to check whether
  a row already exists.
  """

  use Ecto.Schema

  @primary_key {:group_folder, :string, autogenerate: false}
  schema "sessions" do
    field(:session_id, :string)
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
