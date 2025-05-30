defmodule RemoteChain.HTTP do
  require Logger

  def send_raw_transaction(url, tx) do
    case rpc(url, "eth_sendRawTransaction", [tx]) do
      {:ok, tx_hash} ->
        tx_hash

      {:error, %{"code" => -32603, "message" => "already known"}} ->
        :already_known

      {:error, error = %{"code" => -32000, "message" => message}} ->
        if String.contains?(message, "duplicate transaction") do
          :already_known
        else
          {:error, error}
        end

      {:error, error} ->
        raise "RPC error: #{inspect(error)}"
    end
  end

  def rpc(url, method, params \\ []) do
    request = %{
      jsonrpc: "2.0",
      method: method,
      params: params,
      id: 1
    }

    case post(url, request) do
      %{"result" => result} -> {:ok, result}
      %{"error" => error} -> {:error, error}
      {:error, error} -> {:error, error}
      other -> {:error, "Unexpected result #{inspect(other)}"}
    end
  end

  # @dialyzer {:nowarn_function, post: 2}
  defp post(url, request) do
    case HTTPoison.post(url, Poison.encode!(request), [
           {"Content-Type", "application/json"},
           {"Accept-Encoding", "gzip"}
         ]) do
      {:ok, %{body: body, headers: headers}} ->
        headers = Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)

        body =
          if List.keyfind(headers, "content-encoding", 0) ==
               {"content-encoding", "gzip"} do
            :zlib.gunzip(body)
          else
            body
          end

        with {:ok, json} <- Poison.decode(body) do
          json
        else
          _err ->
            {:error,
             "Failed to decode response. headers: #{inspect(headers)} body: #{inspect(body)}"}
        end

      error = {:error, _reason} ->
        error
    end
  end

  def rpc!(url, method, params \\ []) do
    case rpc(url, method, params) do
      {:ok, result} -> result
      {:error, error} -> raise "RPC error: #{inspect(error)}"
    end
  end
end
