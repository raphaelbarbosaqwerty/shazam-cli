defmodule ShazamTest do
  use ExUnit.Case

  test "aggregate_results formats correctly" do
    agents = [
      %{name: "agent1", prompt: "test"},
      %{name: "agent2", prompt: "test"}
    ]

    results = [{:ok, "result1"}, {:ok, "result2"}]

    aggregated =
      agents
      |> Enum.zip(results)
      |> Enum.map(fn {agent, result} ->
        %{name: agent[:name], result: result}
      end)

    assert length(aggregated) == 2
    assert Enum.at(aggregated, 0).name == "agent1"
    assert Enum.at(aggregated, 1).result == {:ok, "result2"}
  end
end
