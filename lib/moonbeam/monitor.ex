defmodule Monitor do
  alias DiodeClient.{Base16, Hash}

  def chain(), do: Chains.Moonbeam

  def nodes() do
    %{
      us1: 0xCECA2F8CF1983B4CF0C1BA51FD382C2BC37ABA58,
      as1: 0x68E0BAFDDA9EF323F692FC080D612718C941D120,
      eu1: 0x937C492A77AE90DE971986D003FFBC5F8BB2232C,
      us2: 0x7E4CD38D266902444DC9C8F7C0AA716A32497D0B,
      as2: 0x1350D3B501D6842ED881B59DE4B95B27372BFAE8,
      eu2: 0xAE699211C62156B8F29CE17BE47D2F069A27F2A6
    }
  end

  def balance(address, block \\ "latest") do
    RemoteChain.RPC.get_balance(Chains.Moonbeam, hex_address(address), hex_blockref(block))
    |> Base16.decode_int()
  end

  def dump(block \\ "latest") do
    print("Name", "Address", "Moonbeam")

    for {name, address} <- nodes() do
      bal1 = balance(address, block)
      print(name, address, bal1)
      {name, bal1}
    end
  end

  def print(name, _address, beam) do
    name = String.pad_trailing("#{name}", 5)
    beam = String.pad_leading("#{beam}", 10)
    IO.puts("#{name} #{beam}")
  end

  defp hex_blockref(ref) when ref in ["latest", "earliest"], do: ref
  defp hex_blockref(ref), do: Base16.encode(ref, false)

  defp hex_address(<<_::binary-size(20)>> = address) do
    Base16.encode(address)
  end

  defp hex_address(address) when is_integer(address) do
    Base16.encode(Hash.to_address(address))
  end
end
