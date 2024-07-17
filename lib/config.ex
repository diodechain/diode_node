defmodule Diode.Config do
  def defaults() do
    %{
      "LOG_LEVEL" => "info",
      "RPC_PORT" => "8545",
      "RPCS_PORT" => "8443",
      "EDGE2_PORT" => "41046,443,993,1723,10000",
      "PEER2_PORT" => "51055",
      "PRIVATE" => "0",
      "HOST" => fn ->
        {:ok, interfaces} = :inet.getif()
        ips = Enum.map(interfaces, fn {ip, _b, _m} -> ip end)

        {a, b, c, d} =
          Enum.find(ips, hd(ips), fn ip ->
            case ip do
              {127, _, _, _} -> false
              {10, _, _, _} -> false
              {192, 168, _, _} -> false
              {172, b, _, _} when b >= 16 and b < 32 -> false
              _ -> true
            end
          end)

        "#{a}.#{b}.#{c}.#{d}"
      end,
      "SEED_LIST" => fn ->
        [
          "diode://0xceca2f8cf1983b4cf0c1ba51fd382c2bc37aba58@us1.prenet.diode.io:51055",
          "diode://0x7e4cd38d266902444dc9c8f7c0aa716a32497d0b@us2.prenet.diode.io:51055",
          "diode://0x68e0bafdda9ef323f692fc080d612718c941d120@as1.prenet.diode.io:51055",
          "diode://0x1350d3b501d6842ed881b59de4b95b27372bfae8@as2.prenet.diode.io:51055",
          "diode://0x937c492a77ae90de971986d003ffbc5f8bb2232c@eu1.prenet.diode.io:51055",
          "diode://0xae699211c62156b8f29ce17be47d2f069a27f2a6@eu2.prenet.diode.io:51055"
        ]
        |> Enum.join(" ")
      end,
      "DATA_DIR" => fn ->
        File.cwd!() <> "/nodedata_" <> Atom.to_string(Diode.env())
      end
    }
  end

  def default!(var) do
    case Map.get(defaults(), var) do
      nil -> raise "No default for #{var}"
      other -> other
    end
  end

  def configure() do
    for {var, _default} <- defaults() do
      set(var, get(var))
    end
  end

  def get(var) do
    def = default!(var)
    do_get(var) || eval(def)
  end

  def get_int(name) do
    decode_int(get(name))
  end

  defp decode_int(int) do
    case int do
      "" ->
        0

      <<"0x", _::binary>> = bin ->
        Base16.decode_int(bin)

      bin when is_binary(bin) ->
        {num, _} = Integer.parse(bin)
        num

      int when is_integer(int) ->
        int
    end
  end

  defp do_get(var) do
    snap_get(var) || System.get_env(var)
  end

  def set(var, value) do
    snap_set(var, value)
    System.put_env(var, value)
    on_set(var, value)
    value
  end

  defp snap?() do
    System.get_env("SNAP") != nil && System.find_executable("snapctl") != nil
  end

  # For snap the DATA_DIR is dynamically moving around with each refresh
  # of the container. So we don't want to get it from the persistent
  # snap configuration but rather dynamically based on the current working directory.
  def snap_get("DATA_DIR"), do: nil

  def snap_get(var) do
    snap?() &&
      case System.cmd("snapctl", ["get", snap_name(var)]) do
        {"", _} -> nil
        {"\n", _} -> nil
        {value, 0} -> String.trim(value)
        _ -> nil
      end
  end

  def snap_set(var, value) do
    snap?() && System.cmd("snapctl", ["set", "#{snap_name(var)}=#{value}"])
  end

  defp snap_name(var) do
    String.downcase(var) |> String.replace("_", "-")
  end

  defp eval(fun) when is_function(fun), do: fun.()
  defp eval(other), do: other

  defp on_set("LOG_LEVEL", value) do
    if value in ~w(emergency alert critical error warning notice info debug) do
      Logger.configure(level: String.to_atom(value))
    end
  end

  defp on_set(_key, _value), do: :ok
end
