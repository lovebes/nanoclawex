import Config

config :nanoclaw, NanoClaw.Repo,
  database: ":memory:",
  pool_size: 1

config :nanoclaw, ecto_repos: [NanoClaw.Repo]
