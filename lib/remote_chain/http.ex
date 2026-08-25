defmodule RemoteChain.HTTP do
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
    # `compressed: true` sends accept-encoding and transparently decompresses
    # gzip responses (previously done manually via :zlib.gunzip).
    case Req.post(url,
           body: Poison.encode!(request),
           headers: [{"content-type", "application/json"}],
           compressed: true,
           decode_body: false,
           retry: false,
           max_redirects: 0
         ) do
      {:ok, %{body: body}} ->
        with {:ok, json} <- Poison.decode(body) do
          json
        else
          _err ->
            {:error, "Failed to decode response. body: #{inspect(body)}"}
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
