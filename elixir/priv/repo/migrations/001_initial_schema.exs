defmodule NanoClaw.Repo.Migrations.InitialSchema do
  use Ecto.Migration

  def change do
    create table(:messages, primary_key: false) do
      add :id, :integer, primary_key: true
      add :chat_jid, :string, null: false
      add :sender, :string
      add :sender_name, :string
      add :content, :text
      add :timestamp, :integer, null: false
      add :is_from_me, :boolean, default: false
      add :is_bot_message, :boolean, default: false
    end

    create index(:messages, [:chat_jid, :timestamp])

    create table(:chats, primary_key: false) do
      add :jid, :string, primary_key: true
      add :name, :string
      add :last_message_time, :integer
      add :channel, :string
      add :is_group, :boolean
    end

    create table(:registered_groups, primary_key: false) do
      add :jid, :string, primary_key: true
      add :name, :string
      add :folder, :string, null: false
      add :trigger_pattern, :string
      add :is_main, :boolean, default: false
      add :requires_trigger, :boolean, default: true
      add :container_config, :text
      add :added_at, :integer
    end

    create table(:sessions, primary_key: false) do
      add :group_folder, :string, primary_key: true
      add :session_id, :string
    end

    create table(:router_state, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :string
    end
  end
end
