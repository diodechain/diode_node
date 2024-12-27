#!/usr/bin/env elixir
Mix.install([:req])

epoch = System.argv() |> List.first() |> String.to_integer()
postfix = System.argv() |> Enum.at(1, "")

now = DateTime.utc_now()
chain_id = 1284
filename = "epoch_#{epoch}/network_#{now.year}_#{now.month}_#{now.day}#{postfix}.log"
IO.puts("Writing to #{filename}")

puts = fn line ->
  File.write!(filename, line <> "\n", [:append])
  IO.puts(line)
end

puts.("epoch: #{epoch}")

%{body: body} =
  Req.post!("https://prenet.diode.io:8443",
    json: %{
      "jsonrpc" => "2.0",
      "method" => "dio_network",
      "params" => [],
      "id" => 1
    }
  )

nodes = Enum.sort_by(body["result"], fn node -> node["node_id"] end)

Task.async_stream(
  nodes,
  fn node ->
    summary = %{
      id: node["node_id"],
      ip: Enum.at(node["node"], 1),
      name:
        Enum.at(node["node"], 5)
        |> Enum.find_value(fn [key, value] -> if key == "name", do: value end)
    }

    %{body: body} =
      Req.post!("https://prenet.diode.io:8443",
        json: %{
          "jsonrpc" => "2.0",
          "method" => "dio_proxy|dio_traffic",
          "params" => [summary.id, chain_id, epoch],
          "id" => 1
        }
      )

    with %{"result" => %{"fleets" => fleets}} <- body do
      {summary, fleets}
    else
      _ -> {summary, []}
    end
  end,
  timeout: 120_000
)
|> Enum.each(fn {:ok, result} ->
  with {summary, fleets} <- result do
    puts.("#{summary.id}\t#{summary.ip}\t#{summary.name}")

    for {fleet_id, fleet} <- fleets do
      puts.("\t\tchain: #{chain_id} fleet: #{fleet_id} score: #{fleet["total_score"]}")
    end
  end
end)
