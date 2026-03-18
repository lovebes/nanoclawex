import Config

config :nanoclaw, NanoClaw.Repo,
  database: Path.expand("../store/nanoclaw.db", __DIR__),
  journal_mode: :wal,
  cache_size: -64_000,
  temp_store: :memory

config :nanoclaw, ecto_repos: [NanoClaw.Repo]
