defmodule NanoClaw.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      NanoClaw.Repo,
      {Registry, keys: :unique, name: NanoClaw.GroupRegistry},
      {DynamicSupervisor, name: NanoClaw.Groups.Supervisor, strategy: :one_for_one},
      # Runs migrations synchronously before GroupLoader queries the DB.
      # Returns :ignore so no persistent child is registered.
      NanoClaw.MigrationRunner,
      NanoClaw.GroupLoader,
      NanoClaw.MessageLoop
    ]

    opts = [strategy: :one_for_one, name: NanoClaw.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
