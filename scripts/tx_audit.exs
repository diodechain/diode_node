#!/bin/env elixir
Mix.install([:req, :jason])
# Reference request
# https://api-moonbase.moonscan.io/api
#    ?module=account
#    &action=txlist
#    &address=0x1038F9E41836b3E8BBD3416fbdbE9836F1EA83C5
#    &startblock=0
#    &endblock=latest
#    &page=1
#    &offset=3
#    &sort=asc
#    &apikey=YourApiKeyToken

defmodule TxAudit do
  def nodes() do
    %{
      us1: "0xCECA2F8CF1983B4CF0C1BA51FD382C2BC37ABA58",
      as1: "0x68E0BAFDDA9EF323F692FC080D612718C941D120",
      eu1: "0x937C492A77AE90DE971986D003FFBC5F8BB2232C",
      us2: "0x7E4CD38D266902444DC9C8F7C0AA716A32497D0B",
      as2: "0x1350D3B501D6842ED881B59DE4B95B27372BFAE8",
      eu2: "0xAE699211C62156B8F29CE17BE47D2F069A27F2A6"
    }
  end

  def api_key() do
    IO.puts("Reading moonscan_api.key #{File.cwd!()}")
    String.trim(File.read!("./scripts/moonscan_api.key"))
  end

  # Reference tx receipt
  # {
  #   "blockHash":"0x3dd93390c6f9bacb609cf0f4adf2f46745321172e3fabdfd64825732f3a20b3f",
  #   "blockNumber":"9502809",
  #   "confirmations":"419",
  #   "contractAddress":"",
  #   "cumulativeGasUsed":"236467",
  #   "from":"0xceca2f8cf1983b4cf0c1ba51fd382c2bc37aba58",
  #   "functionName":"dispatch(address from,address to,uint256 value,bytes data,uint64 gaslimit,uint256 deadline,uint8 v,bytes32 r,bytes32 s)","gas":"12000000",
  #   "gasPrice":"34375000000","gasUsed":"33845","hash":"0xcef67a1886cbb1d55441586c589e73f29d4b5e722a9d67c434eae7e201a4881e",
  #   "input":"0xb5ea0966000000000000000000000000caef1dd49fea66d2594a9e58e904d96606811b860000000000000000000000002c53e6d52745b0a9c2f0a7d67bda1e13303ec3a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000009896800000000000000000000000000000000000000000000000000000000067a4af3d000000000000000000000000000000000000000000000000000000000000001c57b37ea6cdf84d64b11d110006e7f311a11575981d3de046eb6f4a2e1c4cce06423709c43e9e04824121247b6251b6544c9b0f5b9dcc2e5159dcacbc81ca76df00000000000000000000000000000000000000000000000000000000000000241a2323d9000000000000000000000000caef1dd49fea66d2594a9e58e904d96606811b8600000000000000000000000000000000000000000000000000000000",
  #   "isError":"1","methodId":"0xb5ea0966",
  #   "nonce":"74373","timeStamp":"1738842414","to":"0x000000000000000000000000000000000000080a","transactionIndex":"3","txreceipt_status":"0","value":"0"}

  def main() do
    for {name, address} <- nodes() do
      ret =
        fetch(name, address)
        |> Enum.filter(fn tx -> String.starts_with?(tx["functionName"], "dispatch(") end)

      for tx <- ret do
        from = tx_user(tx)
        filename = "scripts/txlog/users/#{from}.csv"

        File.write!(
          filename,
          "\n#{tx["blockNumber"]},#{tx["timeStamp"]},#{name},#{tx["hash"]},#{tx["isError"]}\n",
          [:append]
        )
      end
    end

    for file <- File.ls!("scripts/txlog/users") do
      filename = "scripts/txlog/users/#{file}"
      IO.puts("Processing #{filename}")

      uniq =
        File.read!(filename)
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          row =
            [_block, _timestamp, _name, hash, _is_error] = String.split(String.trim(line), ",")

          Map.put(acc, hash, row)
        end)
        |> Map.values()
        |> Enum.sort()
        |> Enum.map(&Enum.join(&1, ","))
        |> Enum.join("\n")

      File.write!(filename, uniq <> "\n")
    end
  end

  defp tx_user(tx) do
    case tx["input"] do
      <<"0x", _code::binary-size(8), rest::binary>> ->
        chunks = for <<chunk::size(64)-binary <- rest>>, do: chunk

        from = hd(chunks)
        "0x#{binary_part(from, 24, 40)}"

      _ ->
        "none"
    end
  end

  defp fetch(name, address) do
    filename = "scripts/txlog/#{name}.json"
    max_age = {5, 0}

    if File.exists?(filename) and
         :calendar.time_difference(
           File.stat!(filename).mtime,
           :calendar.now_to_datetime(:erlang.now())
         ) < max_age do
      IO.puts("Skipping fetch of #{name} because it already exists")
      ret = Jason.decode!(File.read!(filename))

      if !File.exists?("scripts/txlog/#{name}.csv") do
        dump_csv(name, ret)
      end

      ret
    else
      IO.puts("Processing fetch of #{name}")
      Process.sleep(1000)

      req =
        "https://api-moonbeam.moonscan.io/api?module=account&action=txlist&address=#{address}&apikey=#{api_key()}&startblock=9000000&endblock=latest&offset=10000&sort=desc"

      ret = Req.get!(req)
      File.write!(filename, Jason.encode!(ret.body["result"]))
      dump_csv(name, ret.body["result"])
      IO.puts("Processed fetch of #{name} => #{length(ret.body["result"])}")
      ret.body["result"]
    end
  end

  defp dump_csv(name, result) do
    lines =
      for tx <- result do
        "#{tx["blockNumber"]},#{tx["timeStamp"]},#{name},#{tx_user(tx)},#{tx["hash"]},#{tx["isError"]}"
      end

    filename = "scripts/txlog/#{name}.csv"
    File.write!(filename, Enum.join(lines, "\n") <> "\n")
    result
  end
end

TxAudit.main()
