defmodule NanoClaw.GroupLoader do
  @moduledoc false

  use GenServer

  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    groups = NanoClaw.Groups.all()
    Logger.info("GroupLoader: starting #{length(groups)} group(s)")

    for group <- groups do
      DynamicSupervisor.start_child(NanoClaw.Groups.Supervisor, {NanoClaw.Group, group})
    end

    {:ok, %{}}
  end
end
