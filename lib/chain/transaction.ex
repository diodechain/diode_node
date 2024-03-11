# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chain.Transaction do
  @enforce_keys [:chain_id]
  defstruct nonce: 1,
            gasPrice: 0,
            gasLimit: 0,
            to: nil,
            value: 0,
            chain_id: nil,
            signature: nil,
            init: nil,
            data: nil

  @type t :: %Chain.Transaction{}

  def nonce(%Chain.Transaction{nonce: nonce}), do: nonce
  def data(%Chain.Transaction{data: nil}), do: ""
  def data(%Chain.Transaction{data: data}), do: data
  def gas_price(%Chain.Transaction{gasPrice: gas_price}), do: gas_price
  def gas_limit(%Chain.Transaction{gasLimit: gas_limit}), do: gas_limit
  def value(%Chain.Transaction{value: val}), do: val
  def signature(%Chain.Transaction{signature: sig}), do: sig
  def payload(%Chain.Transaction{to: nil, init: nil}), do: ""
  def payload(%Chain.Transaction{to: nil, init: init}), do: init
  def payload(%Chain.Transaction{data: nil}), do: ""
  def payload(%Chain.Transaction{data: data}), do: data
  def to(%Chain.Transaction{to: nil} = tx), do: new_contract_address(tx)
  def to(%Chain.Transaction{to: to}), do: to
  def chain_id(%Chain.Transaction{chain_id: chain_id}), do: chain_id

  @spec from_rlp(binary()) :: Chain.Transaction.t()
  def from_rlp(bin) do
    [nonce, gas_price, gas_limit, to, value, init, rec, r, s] = Rlp.decode!(bin)

    to = Rlpx.bin2addr(to)

    %Chain.Transaction{
      nonce: Rlpx.bin2num(nonce),
      gasPrice: Rlpx.bin2num(gas_price),
      gasLimit: Rlpx.bin2num(gas_limit),
      to: to,
      value: Rlpx.bin2num(value),
      init: if(to == nil, do: init, else: nil),
      data: if(to != nil, do: init, else: nil),
      signature: Secp256k1.rlp_to_bitcoin(rec, r, s),
      chain_id: Secp256k1.chain_id(rec)
    }
  end

  @spec print(Chain.Transaction.t()) :: :ok
  def print(tx) do
    hash = Base16.encode(hash(tx))
    from = Base16.encode(from(tx))
    to = Base16.encode(to(tx))
    type = Atom.to_string(type(tx))
    value = value(tx)
    code = Base16.encode(payload(tx))
    nonce = nonce(tx)

    code =
      if byte_size(code) > 40 do
        binary_part(code, 0, 37) <> "... [#{byte_size(code)}]"
      end

    IO.puts("")
    IO.puts("\tTransaction: #{hash} Type: #{type}")
    IO.puts("\tFrom:        #{from} (#{nonce}) To: #{to}")
    IO.puts("\tValue:       #{value} Code: #{code}")

    # rlp = to_rlp(tx) |> Rlp.encode!()
    # IO.puts("\tRLP:          #{Base16.encode(rlp)}")
    :ok
  end

  @spec valid?(Chain.Transaction.t()) :: boolean()
  def valid?(tx) do
    validate(tx) == true
  end

  @spec type(Chain.Transaction.t()) :: :call | :create
  def type(tx) do
    if contract_creation?(tx) do
      :create
    else
      :call
    end
  end

  @spec validate(Chain.Transaction.t()) :: true | {non_neg_integer(), any()}
  def validate(tx) do
    with {1, %Chain.Transaction{}} <- {1, tx},
         {2, 65} <- {2, byte_size(signature(tx))},
         {4, true} <- {4, value(tx) >= 0},
         {5, true} <- {5, gas_price(tx) >= 0},
         {6, true} <- {6, gas_limit(tx) >= 0},
         {7, true} <- {7, byte_size(payload(tx)) >= 0} do
      true
    else
      {nr, error} -> {nr, error}
    end
  end

  @spec contract_creation?(Chain.Transaction.t()) :: boolean()
  def contract_creation?(%Chain.Transaction{to: to}) do
    to == nil
  end

  @spec new_contract_address(Chain.Transaction.t()) :: binary()
  def new_contract_address(%Chain.Transaction{to: to}) when to != nil do
    nil
  end

  def new_contract_address(%Chain.Transaction{nonce: nonce} = tx) do
    address = Wallet.address!(origin(tx))

    Rlp.encode!([address, nonce])
    |> Hash.keccak_256()
    |> Hash.to_address()
  end

  @spec to_rlp(Chain.Transaction.t()) :: [...]
  def to_rlp(tx) do
    [tx.nonce, gas_price(tx), gas_limit(tx), tx.to, tx.value, payload(tx)] ++
      Secp256k1.bitcoin_to_rlp(tx.signature, tx.chain_id)
  end

  @spec from(Chain.Transaction.t()) :: <<_::160>>
  def from(tx) do
    Wallet.address!(origin(tx))
  end

  @spec recover(Chain.Transaction.t()) :: binary()
  def recover(tx) do
    Secp256k1.recover!(signature(tx), to_message(tx), :kec)
  end

  @spec origin(Chain.Transaction.t()) :: Wallet.t()
  def origin(%Chain.Transaction{signature: {:fake, pubkey}}) do
    Wallet.from_address(pubkey)
  end

  def origin(tx) do
    recover(tx) |> Wallet.from_pubkey()
  end

  @spec sign(Chain.Transaction.t(), <<_::256>>) :: Chain.Transaction.t()
  def sign(tx = %Chain.Transaction{}, priv) do
    %{tx | signature: Secp256k1.sign(priv, to_message(tx), :kec)}
  end

  def hash(tx = %Chain.Transaction{signature: {:fake, _pubkey}}) do
    to_message(tx) |> Diode.hash()
  end

  @spec hash(Chain.Transaction.t()) :: binary()
  def hash(tx) do
    to_rlp(tx) |> Rlp.encode!() |> Diode.hash()
  end

  @spec to_message(Chain.Transaction.t()) :: binary()
  def to_message(tx = %Chain.Transaction{chain_id: nil}) do
    # pre EIP-155 encoding
    [tx.nonce, gas_price(tx), gas_limit(tx), tx.to, tx.value, payload(tx)]
    |> Rlp.encode!()
  end

  def to_message(tx = %Chain.Transaction{chain_id: 0}) do
    # pre EIP-155 encoding
    [tx.nonce, gas_price(tx), gas_limit(tx), tx.to, tx.value, payload(tx)]
    |> Rlp.encode!()
  end

  def to_message(tx = %Chain.Transaction{chain_id: chain_id}) do
    # EIP-155 encoding
    [tx.nonce, gas_price(tx), gas_limit(tx), tx.to, tx.value, payload(tx), chain_id, 0, 0]
    |> Rlp.encode!()
  end
end
