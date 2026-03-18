defmodule NanoClaw.MigrationRunner do
  @moduledoc false
  # Runs Ecto migrations synchronously during supervision tree startup,
  # then exits by returning :ignore so no persistent child is added.
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [])
  end

  @impl true
  def init(_) do
    path = Application.app_dir(:nanoclaw, "priv/repo/migrations")
    Ecto.Migrator.run(NanoClaw.Repo, path, :up, all: true)
    :ignore
  end
end
