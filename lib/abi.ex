# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule ABI do
  require Logger
  import Wallet

  def encode_args(types, values) when is_list(types) and is_list(values) do
    encode_data(types, values)
    |> :erlang.iolist_to_binary()
  end

  def decode_types(types, data) do
    {ret, _rest} =
      Enum.reduce(types, {[], data}, fn type, {ret, rest} ->
        {value, rest} =
          if is_dynamic(type) do
            decode("uint256", rest)
          else
            decode(type, rest)
          end

        {ret ++ [value], rest}
      end)

    Enum.zip(types, ret)
    |> Enum.map(fn {type, value} ->
      if is_dynamic(type) do
        # for dynamic types the decoded value in the header is the offset of the data
        base = binary_part(data, value, byte_size(data) - value)

        cond do
          type in ["string", "bytes"] ->
            {len, rest} = decode("uint256", base)
            slots = div(len, 32) + 1
            binary_part(rest, slots * 32 - len, len)

          String.starts_with?(type, "(") ->
            "(" <> tuple_def = type
            decode_types(tuple_types(tuple_def), base)

          String.ends_with?(type, "[]") ->
            {slots, rest} = decode("uint256", base)
            type = String.replace_trailing(type, "[]", "")

            {acc, _rest} =
              List.duplicate(type, slots)
              |> Enum.reduce({[], rest}, fn type, {acc, rest} ->
                {value, rest} = decode(type, rest)
                {acc ++ [value], rest}
              end)

            acc
        end
      else
        value
      end
    end)
  end

  defp is_dynamic("string"), do: true
  defp is_dynamic("bytes"), do: true

  defp is_dynamic("(" <> tuple_def) do
    Enum.any?(tuple_types(tuple_def), &is_dynamic/1)
  end

  defp is_dynamic(other) do
    String.ends_with?(other, "[]")
  end

  def decode_revert(<<"">>) do
    {:evmc_revert, ""}
  end

  # Decoding "Error(string)" type revert messages
  # <<8, 195, 121, 160>> = ABI.encode_spec("Error", ["string"])
  def decode_revert(
        <<8, 195, 121, 160, 32::unsigned-size(256), length::unsigned-size(256), rest::binary>>
      ) do
    {:evmc_revert, binary_part(rest, 0, length)}
  end

  def decode_revert(other) do
    Logger.debug("decode_revert(#{inspect(other)})")
    {:evmc_revert, "blubb"}
  end

  def encode_spec(name, types \\ []) do
    signature =
      "#{name}(#{Enum.join(types, ",")})"
      |> String.replace(" ", "")

    binary_part(Hash.keccak_256(signature), 0, 4)
  end

  def encode_call(name, types \\ [], values \\ []) do
    fun = encode_spec(name, types)
    args = encode_args(types, values)
    fun <> args
  end

  def do_encode_data(type, value) do
    if is_dynamic(type) do
      {types, values, len} = dynamic(type, value)
      ret = encode_data(types, values)
      {"", [len, ret]}
    else
      {encode(type, value), ""}
    end
  end

  def encode_data(subtypes, values) do
    values =
      Enum.zip([subtypes, values])
      |> Enum.map(fn {type, entry} ->
        do_encode_data(type, entry)
      end)

    {head, body, _} =
      Enum.reduce(values, {[], [], 32 * length(subtypes)}, fn
        {"", body}, {h, b, o} ->
          {h ++ [encode("uint", o)], b ++ [body], o + :erlang.iolist_size(body)}

        {head, _}, {h, b, o} ->
          {h ++ [head], b, o}
      end)

    [head, body]
  end

  defp dynamic(type, {:call, name, types, args}) do
    dynamic(type, encode_call(name, types, args))
  end

  defp dynamic(type, values) when is_list(values) do
    cond do
      String.ends_with?(type, "[]") ->
        n = length(values)
        {List.duplicate(String.replace_trailing(type, "[]", ""), n), values, encode("uint", n)}

      String.starts_with?(type, "(") ->
        {tuple_types(String.trim_leading(type, "(")), values, ""}
    end
  end

  defp dynamic(type, value) when is_binary(value) and type in ["string", "bytes"] do
    values = value <> <<0::unsigned-size(248)>>

    values =
      binary_part(values, 0, div(byte_size(values), 32) * 32)
      |> :erlang.binary_to_list()
      |> Enum.chunk_every(32)
      |> Enum.map(&:erlang.iolist_to_binary/1)

    {List.duplicate("bytes32", length(values)), values, encode("uint", byte_size(value))}
  end

  def encode(format, nil), do: encode(format, 0)

  # uint<M>: unsigned integer type of M bits, 0 < M <= 256, M % 8 == 0. e.g. uint32, uint8, uint256.
  # int<M>: two’s complement signed integer type of M bits, 0 < M <= 256, M % 8 == 0.
  # address: equivalent to uint160, except for the assumed interpretation and language typing. For computing the function selector, address is used.
  # uint, int: synonyms for uint256, int256 respectively. For computing the function selector, uint256 and int256 have to be used.
  # bool: equivalent to uint8 restricted to the values 0 and 1. For computing the function selector, bool is used.
  # fixed<M>x<N>: signed fixed-point decimal number of M bits, 8 <= M <= 256, M % 8 ==0, and 0 < N <= 80, which denotes the value v as v / (10 ** N).
  # ufixed<M>x<N>: unsigned variant of fixed<M>x<N>.
  # fixed, ufixed: synonyms for fixed128x18, ufixed128x18 respectively. For computing the function selector, fixed128x18 and ufixed128x18 have to be used.
  # bytes<M>: binary type of M bytes, 0 < M <= 32.
  # function: an address (20 bytes) followed by a function selector (4 bytes). Encoded identical to bytes24.
  for bit <- 1..32 do
    Module.eval_quoted(
      __MODULE__,
      Code.string_to_quoted("""
        def encode("uint#{bit * 8}", value), do: <<value :: unsigned-size(256)>>
        def encode("int#{bit * 8}", value), do: <<value :: signed-size(256)>>
        def encode("bytes#{bit}", <<value :: binary>>), do: <<:binary.decode_unsigned(value) :: unsigned-size(256)>>
        def encode("bytes#{bit}", value) when is_integer(value), do: <<value :: unsigned-size(256)>>
      """)
    )
  end

  def encode("uint", value), do: encode("uint256", value)
  def encode("int", value), do: encode("int256", value)
  def encode("address", value) when is_integer(value), do: encode("uint160", value)
  def encode("address", value) when is_binary(value), do: encode("bytes20", value)
  def encode("address", value = wallet()), do: encode("bytes20", Wallet.address!(value))
  def encode("bool", true), do: encode("uint8", 1)
  def encode("bool", false), do: encode("uint8", 0)
  def encode("bool", value), do: encode("uint8", value)

  def encode("function", {address, name}),
    do: encode("bytes24", encode("address", address) <> encode_spec(name))

  def encode("function", {address, name, types}),
    do: encode("bytes24", encode("address", address) <> encode_spec(name, types))

  def encode("function", value), do: encode("bytes24", value)

  def encode("(" <> tuple_def, values) do
    types = tuple_types(tuple_def)
    encode_args(types, values)
  end

  defp tuple_types(tuple_def) do
    len = byte_size(tuple_def) - 1
    <<tuple_def::binary-size(len), ")">> = tuple_def

    String.split(tuple_def, ",")
    |> Enum.map(&String.trim/1)
  end

  for bit <- 1..32 do
    Module.eval_quoted(
      __MODULE__,
      Code.string_to_quoted("""
        def decode("uint#{bit * 8}", <<value :: unsigned-size(256), rest :: binary>>), do: {value, rest}
        def decode("int#{bit * 8}", <<value :: signed-size(256), rest :: binary>>), do: {value, rest}
        def decode("bytes#{bit}", <<value :: binary-size(#{bit}), _ :: binary-size(#{32 - bit}), rest :: binary>>), do: {value, rest}
      """)
    )
  end

  def decode("uint", value), do: decode("uint256", value)
  def decode("int", value), do: decode("int256", value)
  def decode("bool", value), do: decode("uint8", value)

  def decode("address", <<_::binary-size(12), address::binary-size(20), rest::binary>>),
    do: {address, rest}

  def decode("address[]", value), do: decode("uint256", value)
  def decode("string", value), do: decode("uint256", value)
  def decode("bytes", value), do: decode("uint256", value)

  def decode("(" <> tuple_def, value) do
    types = tuple_types(tuple_def)
    {decode_types(types, value), ""}
  end
end
