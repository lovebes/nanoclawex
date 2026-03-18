defmodule NanoClaw.DB.RouterState do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}
  schema "router_state" do
    field(:value, :string)
  end
end
