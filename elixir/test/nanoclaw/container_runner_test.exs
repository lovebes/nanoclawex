defmodule NanoClaw.ContainerRunnerTest do
  use ExUnit.Case

  alias NanoClaw.ContainerRunner

  test "parses complete output" do
    json = Jason.encode!(%{"text" => "hello", "sessionId" => "abc"})
    buffer = "some prefix\n---NANOCLAW_OUTPUT_START---#{json}---NANOCLAW_OUTPUT_END---"
    assert {:ok, %{"text" => "hello"}, ""} = ContainerRunner.parse_output(buffer)
  end

  test "returns :incomplete on partial output" do
    assert :incomplete = ContainerRunner.parse_output("---NANOCLAW_OUTPUT_START---{\"text\":")
  end

  test "handles multiple output markers, returns first" do
    json1 = Jason.encode!(%{"text" => "first"})
    json2 = Jason.encode!(%{"text" => "second"})

    buffer =
      "---NANOCLAW_OUTPUT_START---#{json1}---NANOCLAW_OUTPUT_END---" <>
        "---NANOCLAW_OUTPUT_START---#{json2}---NANOCLAW_OUTPUT_END---"

    assert {:ok, %{"text" => "first"}, remaining} = ContainerRunner.parse_output(buffer)
    assert {:ok, %{"text" => "second"}, ""} = ContainerRunner.parse_output(remaining)
  end

  test "remaining buffer preserved after marker" do
    json = Jason.encode!(%{"text" => "hi"})
    buffer = "---NANOCLAW_OUTPUT_START---#{json}---NANOCLAW_OUTPUT_END---trailing stuff"
    assert {:ok, _, "trailing stuff"} = ContainerRunner.parse_output(buffer)
  end
end
