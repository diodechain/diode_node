#!/usr/bin/env elixir

files = File.ls!(".") |> Enum.filter(&String.ends_with?(&1, ".log"))

list =
  for file <- files do
    content = File.read!(file)
    lines = String.split(content, "\n") |> Enum.drop(1)

    list =
      Enum.reduce(lines, [], fn line, acc ->
        line = String.replace(line, "\t", " ")

        case String.split(line, " ", trim: true) do
          [node_id, ip, name] ->
            [%{node_id: node_id, ip: ip, name: name, score: %{}} | acc]

          ["chain:", "1284", "fleet:", fleet, "score:", "0x" <> score] ->
            [prev | acc] = acc
            [%{prev | score: %{fleet: fleet, score: score}} | acc]

          [] ->
            acc
        end
      end)
      |> Enum.filter(&(map_size(&1.score) > 0))

    IO.puts("#{file}: #{length(list)} unique entries")
    list
  end
  |> List.flatten()
  |> Enum.uniq_by(& &1.node_id)
  |> Enum.sort_by(& &1.node_id)

IO.puts("total unique entries: #{length(list)}")

for node <- list do
  ip = String.pad_trailing(node.ip, 15)
  IO.puts("#{node.node_id} #{ip} score:#{node.score.score}\t#{node.name}")
end
