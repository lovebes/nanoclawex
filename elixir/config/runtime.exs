import Config

if config_env() == :prod do
  db_path =
    System.get_env("DATABASE_PATH") ||
      Path.expand("../store/nanoclaw.db", __DIR__)

  config :nanoclaw, NanoClaw.Repo, database: db_path
end
