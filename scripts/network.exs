#!/usr/bin/env elixir
Mix.install([:req])

epoch = 667
IO.puts("epoch: #{epoch}")

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

for node <- nodes do
  summary = %{
    id: node["node_id"],
    ip: Enum.at(node["node"], 1),
    name:
      Enum.at(node["node"], 5)
      |> Enum.find_value(fn [key, value] -> if key == "name", do: value end)
  }

  IO.puts("#{summary.id}\t#{summary.ip}\t#{summary.name}")

  for chain_id <- [15] do
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
      for {fleet_id, fleet} <- fleets do
        IO.puts("\t\tchain: #{chain_id} fleet: #{fleet_id} score: #{fleet["total_score"]}")
      end
    end
  end
end
