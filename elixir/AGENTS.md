# NanoClaw Elixir — Agent Guidelines

This is an Elixir/OTP application (no Phoenix, no LiveView). It is a
background daemon that polls a SQLite database for messages, spawns Claude
agents in Docker containers via `Port`, and routes responses back to messaging
channels.

## Elixir guidelines

- Elixir lists **do not support index-based access via the access syntax**

  **Never do this (invalid):**

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead **always** use `Enum.at`, pattern matching, or `List`:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**.
  **Never use `else if` or `elseif`** — always use `cond` or `case` for
  multiple conditionals.

- Variables are immutable but can be rebound. For block expressions like `if`,
  `case`, `cond`, etc. you **must** bind the result of the expression if you
  want to use it — you cannot rebind inside the block:

      # INVALID
      if some_condition do
        state = %{state | running: true}
      end

      # VALID
      state =
        if some_condition do
          %{state | running: true}
        else
          state
        end

- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`.
  Prefer a flat `with` with intermediate `=` bindings over nested `with` blocks
  — see `ContainerRunner.parse_output/1` for the established pattern.

- **Never** nest multiple modules in the same file — it can cause cyclic
  dependencies and compilation errors.

- **Never** use map access syntax (`struct[:field]`) on plain structs. Structs
  do not implement the `Access` behaviour by default. Always use dot access
  (`struct.field`) or pattern matching.

- Don't use `String.to_atom/1` on external input — atoms are not garbage
  collected and exhausting the atom table crashes the VM.

- Predicate function names should end in `?` and should **not** start with
  `is_`. Names like `is_thing` are reserved for guard-safe functions (macros).

- Use `Task.async_stream/3` for concurrent enumeration with back-pressure.
  Pass `timeout: :infinity` unless you have a specific deadline.

- Elixir's standard library covers all date/time needs via `Date`, `Time`,
  `DateTime`, and `Calendar`. **Never** add a date/time dependency unless
  asked — the only exception is `date_time_parser` for parsing arbitrary
  user-supplied strings.

## Mix guidelines

- Read the docs before using unfamiliar tasks: `mix help <task_name>`
- Run a specific test file with `mix test test/path/to_test.exs`
- Re-run only previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed** — avoid it.

## OTP / GenServer guidelines

- **Always** place long-running processes in the supervision tree. Unsupervised
  processes have no lifecycle guarantees and no crash recovery.

- OTP primitives like `DynamicSupervisor` and `Registry` require a `:name` in
  their child spec:

      {DynamicSupervisor, name: NanoClaw.Groups.Supervisor, strategy: :one_for_one}
      {Registry, keys: :unique, name: NanoClaw.GroupRegistry}

  Then reference them by name:

      DynamicSupervisor.start_child(NanoClaw.Groups.Supervisor, {NanoClaw.Group, group})
      Registry.lookup(NanoClaw.GroupRegistry, folder)

- Use `GenServer.cast/2` for fire-and-forget messages (e.g. delivering
  inbound messages to a group). Use `GenServer.call/2` only when you need a
  synchronous reply and can tolerate blocking the caller.

- Keep GenServer state as a named struct (`defstruct`) rather than a plain map
  — it makes pattern matching in `handle_*` clauses self-documenting and
  catches typos at compile time.

- Cancel timers before resetting them. `Process.cancel_timer/1` is idempotent
  — always cancel the old ref before sending a new `Process.send_after/3`.

- GenServer `terminate/2` is **not guaranteed to be called** (e.g. on
  `kill` signals or node crashes). Use it only for best-effort cleanup like
  flushing state to the DB — never rely on it for correctness.

- Avoid storing large binaries in GenServer state. If a binary grows
  unboundedly (e.g. an output buffer), ensure it is cleared after processing.

## Ecto guidelines

- **Always** preload associations in queries when they will be accessed
  downstream — accessing an unloaded association raises at runtime.

- `Ecto.Schema` fields always use `:string` even for `TEXT` columns:

      field :content, :string   # not :text

- Use `Ecto.Changeset.get_field(changeset, :field)` to read changeset fields —
  never use map access (`changeset[:field]`) on a changeset struct.

- Fields set programmatically (e.g. foreign keys, computed values) must
  **not** appear in `cast/3` calls — set them explicitly after casting.

- Prefer `Repo.insert!/1` with `on_conflict:` options for upsert patterns
  (see `DB.Session.upsert/2` and `DB.RouterState` writes for the established
  pattern).

- Remember `import Ecto.Query` in any module that writes query expressions.

## Project-specific conventions

- **Supervision order matters.** `MigrationRunner` must be started before
  `GroupLoader` and `MessageLoop` because both query the database during
  `init/1`. Never reorder them in `Application.start/2`.

- **Container protocol.** The agent container receives a single JSON line on
  stdin and emits output framed by:

      ---NANOCLAW_OUTPUT_START---{...}---NANOCLAW_OUTPUT_END---

  Always use `ContainerRunner.parse_output/1` to extract frames — never
  parse the markers manually elsewhere.

- **Group registry key = folder name**, not JID. The `Group` GenServer is
  registered as `{:via, Registry, {NanoClaw.GroupRegistry, folder}}`. The JID
  is stored in state and used for outbound routing. Don't confuse the two.

- **All public Group interaction goes through `NanoClaw.Group`'s API**
  (`start_link/1`, `inbound_messages/2`, `via/1`). Never call
  `GenServer.cast/call` on a Group pid directly from outside the module —
  scatter is the "Scattered Process Interfaces" anti-pattern.

- **Non-assertive truthiness is banned.** Never use `&&` or `||` with operands
  that are known boolean. Use `and`/`or`/`not` for booleans, `is_binary/1` or
  pattern matching for nil-checks on typed values.

- `mix credo --strict` must pass with zero issues before committing.
- `mix format` must be run before committing (Styler auto-sorts aliases).
- `mix test` must pass before committing.
