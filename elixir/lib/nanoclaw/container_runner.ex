defmodule NanoClaw.ContainerRunner do
  @moduledoc """
  Builds and opens an OS `Port` for a container invocation, and parses its
  streaming stdout.

  ## Container protocol

  Input is written as a single JSON line to the container's stdin immediately
  after the port opens:

      {"prompt":"…","sessionId":"…","groupFolder":"…","chatJid":"…",
       "isMain":false,"assistantName":"Andy"}

  The container writes arbitrary log lines to stdout, followed by one output
  frame delimited by sentinel markers:

      ---NANOCLAW_OUTPUT_START---{"text":"…","sessionId":"…"}---NANOCLAW_OUTPUT_END---

  `parse_output/1` accumulates raw binary chunks from the port and returns
  `{:ok, payload, remaining}` once a complete frame is found, or `:incomplete`
  while still buffering.  The `remaining` binary preserves any bytes that
  arrived after the closing marker so they are not silently dropped.

  ## Volume mounts

  The group's workspace folder (`groups/<folder>/`) is mounted read-write at
  `/workspace` so the agent can read/write persistent files.  The shared
  `agent-runner.js` script is mounted read-only at `/agent-runner.js`.

  The container image is expected to be named `nanoclaw-agent`.  Override the
  runtime binary with the `CONTAINER_RUNTIME` env var (defaults to `docker`).
  """

  @output_start "---NANOCLAW_OUTPUT_START---"
  @output_end "---NANOCLAW_OUTPUT_END---"

  @doc """
  Opens a Port for the container process. The calling GenServer
  will receive `{port, {:data, binary}}` and `{port, {:exit_status, n}}` messages.
  """
  def open(group, prompt, opts \\ []) do
    runtime = System.find_executable(runtime_bin())
    if !runtime, do: raise("Container runtime not found: #{runtime_bin()}")

    args = build_args(group, opts)
    env = group |> build_env() |> Enum.map(fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    port =
      Port.open({:spawn_executable, runtime}, [
        :binary,
        :exit_status,
        {:args, args},
        {:env, env}
      ])

    input =
      Jason.encode!(%{
        prompt: prompt,
        sessionId: group.session_id,
        groupFolder: group.folder,
        chatJid: group.jid,
        isMain: group.is_main,
        assistantName: assistant_name()
      })

    Port.command(port, input <> "\n")
    port
  end

  @doc """
  Parses accumulated stdout for a complete output marker pair.
  Returns `{:ok, payload, remaining_buffer}` or `:incomplete`.
  """
  def parse_output(buffer) do
    start_size = byte_size(@output_start)
    end_size = byte_size(@output_end)

    # Single flat with — intermediate bindings (=) never fail, so no else needed.
    # Unmatched find_marker calls return :incomplete directly (no else block needed).
    with {:ok, start_idx} <- find_marker(buffer, @output_start),
         after_offset = start_idx + start_size,
         after_start = binary_part(buffer, after_offset, byte_size(buffer) - after_offset),
         {:ok, end_idx} <- find_marker(after_start, @output_end),
         json = binary_part(after_start, 0, end_idx),
         rest_off = end_idx + end_size,
         remaining = binary_part(after_start, rest_off, byte_size(after_start) - rest_off),
         {:ok, payload} <- Jason.decode(json) do
      {:ok, payload, remaining}
    end
  end

  # --- private ---

  defp find_marker(binary, pattern) do
    case :binary.match(binary, pattern) do
      {pos, _len} -> {:ok, pos}
      :nomatch -> :incomplete
    end
  end

  defp runtime_bin do
    System.get_env("CONTAINER_RUNTIME", "docker")
  end

  defp assistant_name do
    System.get_env("ASSISTANT_NAME", "Andy")
  end

  defp build_env(_group) do
    base_url = System.get_env("ANTHROPIC_BASE_URL", "http://host.docker.internal:4000/api/proxy")

    [
      {"TZ", System.get_env("TZ", "America/New_York")},
      {"ANTHROPIC_BASE_URL", base_url},
      {"ANTHROPIC_API_KEY", "placeholder"}
    ]
  end

  defp build_args(group, _opts) do
    project_root = File.cwd!()
    groups_dir = Path.join(project_root, "../groups")
    group_dir = Path.join(groups_dir, group.folder)

    [
      "run",
      "--rm",
      "-i",
      "-v",
      "#{group_dir}:/workspace:rw",
      "-v",
      "#{project_root}/../container/agent-runner.js:/agent-runner.js:ro",
      "--env",
      "TZ",
      "--env",
      "ANTHROPIC_BASE_URL",
      "--env",
      "ANTHROPIC_API_KEY",
      "nanoclaw-agent",
      "node",
      "/agent-runner.js"
    ]
  end
end
