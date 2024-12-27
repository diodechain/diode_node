#!/usr/bin/env elixir

epoch = System.argv() |> List.first() |> String.to_integer()
IO.puts("epoch: #{epoch}")

files =
  File.ls!("epoch_#{epoch}")
  |> Enum.filter(&Regex.match?(~r/network_\d{4}_\d{2}_\d{2}.?.log/, &1))
  |> Enum.sort()

list =
  for file <- files do
    content = File.read!(Path.join("epoch_#{epoch}", file))
    lines = String.split(content, "\n") |> Enum.drop(1)

    list =
      Enum.reduce(lines, [], fn line, acc ->
        line = String.replace(line, "\t", " ")

        case String.split(line, " ", trim: true) do
          [node_id, ip, name] ->
            [%{node_id: node_id, ip: ip, name: name, score: 0} | acc]

          ["chain:", "1284", "fleet:", _fleet, "score:", "0x" <> score] ->
            [prev | acc] = acc
            score = String.to_integer(score, 16)
            [%{prev | score: prev.score + score} | acc]

          [] ->
            acc
        end
      end)
      |> Enum.filter(&(&1.score > 0))

    IO.puts("#{file}: #{length(list)} unique entries")
    list
  end
  |> List.flatten()
  |> Enum.uniq_by(& &1.node_id)
  |> Enum.sort_by(& &1.node_id)

IO.puts("total unique entries: #{length(list)}")

for node <- list do
  ip = String.pad_trailing(node.ip, 15)
  IO.puts("#{node.node_id} #{ip} score:#{node.score}\t#{node.name}")
end
