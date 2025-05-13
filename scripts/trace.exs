# Run for all transactions in a specific block with:
# `mix run --no-start scripts/trace.exs 9959908`
# or for a single transaction with:
# `mix run --no-start scripts/trace.exs 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef`

alias DiodeClient.{Base16, Contracts.CallPermit, Secp256k1, Wallet}

defmodule Anvil do
  use GenServer
  defstruct [:port, :ready, :clients, :stdout]

  def start_link(url) do
    with {:ok, pid} <- GenServer.start_link(__MODULE__, url, name: __MODULE__) do
      GenServer.call(pid, :await_port_open)
      {:ok, pid}
    end
  end

  def stop(pid) do
    GenServer.stop(pid)
  end

  def init(url) do
    port =
      Port.open({:spawn, "anvil --steps-tracing --fork-url #{url} -p1454"}, [
        :binary,
        :use_stdio,
        :exit_status
      ])

    {:ok, %{port: port, ready: false, clients: [], stdout: ""}}
  end

  def handle_info({_port, {:data, info}}, state) do
    stdout = state.stdout <> info

    if String.contains?(stdout, "Listening on ") and not state.ready do
      for client <- state.clients do
        GenServer.reply(client, :ok)
      end

      {:noreply, %{state | ready: true, stdout: stdout, clients: []}}
    else
      {:noreply, %{state | stdout: stdout}}
    end
  end

  def handle_call(:await_port_open, from, state) do
    if state.ready do
      {:reply, :ok, state}
    else
      {:noreply, %{state | clients: [from | state.clients]}}
    end
  end

  def terminate(reason, state) do
    Port.close(state.port)
    IO.inspect(reason, label: "Anvil terminated")
    {:stop, reason, state}
  end
end

defmodule Trace do
  def trace_block(block_number) do
    IO.puts("Block Number: #{block_number}")

    case rpc!("eth_getBlockByNumber", [Base16.encode(block_number), true]) do
      %{"transactions" => transactions} ->
        Enum.each(transactions, fn tx ->
          if tx["to"] in [
               Base16.encode(CallPermit.address()),
               Base16.encode(RemoteChain.Edge.wallet_factory_address())
             ] do
            trace_tx(tx["hash"])
          end
        end)
    end
  end

  def decode_signature(function_signature) do
    if String.contains?(function_signature, "(") do
      [name, args] = String.split(function_signature, "(", parts: 2)
      args = String.trim_trailing(args, ")")
      args = String.split(args, ",") |> Enum.map(&String.trim/1)
      %{name: name, args: args}
    else
      %{name: function_signature, args: []}
    end
  end

  def decode_call(function_signature, encoded_call) do
    %{name: name, args: args} = decode_signature(function_signature)

    with {:ok, params} <- DiodeClient.ABI.decode_call(name, args, encoded_call) do
      {:ok, Enum.zip(args, params)}
    end
  end

  def decode_meta_transaction(input) do
    with {:ok, [from, to, value, data, gaslimit, deadline, v, r, s]} <-
           DiodeClient.ABI.decode_call(
             "SubmitMetaTransaction",
             ["uint256", "uint256", "address", "bytes", "uint8", "bytes32", "bytes32"],
             input
           ) do
      %{
        from: from,
        to: to,
        value: value,
        data: data,
        gaslimit: gaslimit,
        deadline: deadline,
        v: v,
        r: r,
        s: s
      }
    end
  end

  def decode_create_transaction(input) do
    with {:ok, [owner, salt, target]} <-
           DiodeClient.ABI.decode_call(
             "Create",
             ["address", "bytes32", "address"],
             input
           ) do
      %{
        owner: owner,
        salt: salt,
        target: target,
        data: input,
        from: owner,
        deadline: nil,
        to: RemoteChain.Edge.wallet_factory_address()
      }
    end
  end

  def trace_tx(tx_hash, block \\ nil) do
    IO.puts("\nTX Hash: #{tx_hash}")

    tx =
      %{
        "blockNumber" => block_number,
        "input" => input,
        "chainId" => chain_id
      } = rpc!("eth_getTransactionByHash", [tx_hash])

    %{"status" => status} = rpc!("eth_getTransactionReceipt", [tx_hash])

    %{"timestamp" => block_timestamp} =
      block || rpc!("eth_getBlockByNumber", [block_number, true])

    IO.puts("\tBlock Number #{Base16.decode_int(block_number)}")
    IO.puts("\tBlock Timestamp #{Base16.decode_int(block_timestamp)}")

    if tx["to"] not in [
         Base16.encode(CallPermit.address()),
         Base16.encode(RemoteChain.Edge.wallet_factory_address())
       ] do
      IO.inspect(tx, label: "tx")
      raise "Not a CallPermit"
    end

    if status != "0x1" do
      IO.puts("\t❌ Transaction reverted")
    else
      IO.puts("\t✅ Transaction executed")
    end

    IO.puts("\tDispatch Relayer: #{tx["from"]}")
    IO.puts("\tDispatch Nonce: #{Base16.decode_int(tx["nonce"])}")

    trace =
      if System.get_env("CHAIN") == "oasis" do
        []
      else
        %{"structLogs" => trace} = rpc!("debug_traceTransaction", [tx_hash])
        trace
      end

    if length(trace) == 0 do
      IO.puts("\tTransaction reverted without any TRACE")
    else
      IO.puts("\tTransaction executed with TRACE length #{length(trace)}")
    end

    # trace = rpc!("debug_traceTransaction", [tx_hash, %{tracer: "callTracer"}])
    # IO.inspect(trace, label: "callTracer")

    args =
      with {:error, _} <- CallPermit.decode_dispatch(Base16.decode(input)),
           {:error, _} <- decode_meta_transaction(Base16.decode(input)),
           {:error, _} <- decode_create_transaction(Base16.decode(input)) do
        raise "Unknown transaction type"
      end

    sigs =
      File.read!("scripts/sigs.txt")
      |> String.split("\n", trim: true)
      |> Enum.map(fn row -> String.split(row, " ") end)

    case Enum.find(sigs, fn [sig, _name] ->
           sig == binary_part(Base16.encode(args.data), 0, 10)
         end) do
      [_sig, name] ->
        IO.puts("\tDispatch Name: #{name}")

        with {:ok, params} <- decode_call(name, args.data) do
          for {param, i} <- Enum.with_index(params) do
            printable =
              case param do
                {"string", value} -> value
                {_, value} when is_binary(value) -> Base16.encode(value)
                {_, value} -> value
              end

            IO.puts("\t\t#{i}: #{printable}")
          end
        end

      nil ->
        IO.puts("\tDispatch Name: unknown")
    end

    IO.puts("\tDispatch From: #{Base16.encode(args.from)}")
    IO.puts("\tDispatch Deadline: #{args.deadline}")
    IO.puts("\tDispatch To: #{Base16.encode(args.to)}")

    if length(trace) == 0 do
      code =
        rpc!("eth_getCode", [
          Base16.encode(args.to),
          Base16.encode(Base16.decode_int(block_number) - 1, false)
        ])

      if code == "0x" do
        IO.puts("\t🤬 Error: To address #{Base16.encode(args.to)} has no code")
      end
    end

    if args.deadline < Base16.decode_int(block_timestamp) do
      IO.puts(
        "\t🤬 Error: Dispatch deadline #{args.deadline} is before block timestamp #{Base16.decode_int(block_timestamp)}"
      )
    end

    if args[:v] != nil do
      nonce =
        rpc!("eth_call", [
          %{
            to: Base16.encode(CallPermit.address()),
            data: Base16.encode(CallPermit.nonces(args.from))
          },
          Base16.encode(Base16.decode_int(block_number) - 1, false)
        ])
        |> Base16.decode_int()

      IO.puts("\tBlock start nonce: #{nonce}")
      candidates = [nonce | Enum.to_list((nonce - 5)..(nonce + 5))]
      signature = Secp256k1.rlp_to_bitcoin(<<args.v>>, args.r, args.s)
      chain_id = Base16.decode_int(chain_id)

      Enum.find(candidates, fn nonce ->
        msg =
          CallPermit.call_permit(
            chain_id,
            args.from,
            args.to,
            args.value,
            args.data,
            args.gaslimit,
            args.deadline,
            nonce
          )

        from = Secp256k1.recover!(signature, msg, :none) |> Wallet.from_pubkey()
        recovered_address = Wallet.address!(from)

        if recovered_address == args.from do
          true
        else
          false
        end
      end)
      |> case do
        nil ->
          IO.puts("No valid nonce found")

        valid_nonce ->
          if valid_nonce == nonce do
            IO.puts("\tSigned nonce #{valid_nonce} == expected nonce #{nonce}")
          else
            IO.puts(
              "\t🤬 Error: Signed nonce #{valid_nonce} != expected nonce #{nonce} (was there another transaction in this block?)"
            )
          end
      end
    end
  end

  def rpc!(cmd, args) do
    System.get_env("RPC_URL")
    |> RemoteChain.HTTP.rpc!(cmd, args)
  end
end

Application.ensure_all_started(:hackney)

case List.first(System.argv()) do
  "oasis" ->
    System.put_env("CHAIN", "oasis")
    System.put_env("RPC_URL", "https://sapphire.oasis.io")

  "moonbeam" ->
    System.put_env("CHAIN", "moonbeam")

    System.put_env(
      "RPC_URL",
      "https://moonbeam.api.onfinality.io/rpc?apikey=49e8baf7-14c3-4d0f-916a-94abf1c4c14a"
    )

  _ ->
    raise "Usage: trace (oasis|moonbeam) <tx_hash>"
end

# {:ok, _anvil} = Anvil.start_link(System.get_env("RPC_URL"))
# System.put_env("RPC_URL", "http://localhost:1454")

case tl(System.argv()) do
  ["0x" <> _ = tx_hash] -> Trace.trace_tx(tx_hash)
  [block_number] -> Trace.trace_block(String.to_integer(block_number))
  _ -> raise "Usage: trace (oasis|moonbeam) <tx_hash>"
end

# Anvil.stop(anvil)
