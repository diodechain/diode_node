# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule BertInt do
  @moduledoc """
  Binary Erlang Term encoding for internal node-to-node encoding.
  """
  @spec encode!(any()) :: binary()
  def encode!(term) do
    term
    |> :erlang.term_to_binary()
    |> zip()
  end

  # Custom impl of :zlib.zip() for faster compression
  defp zip(data, level \\ 1) do
    z = :zlib.open()

    bs =
      try do
        :zlib.deflateInit(z, level, :deflated, -15, 8, :default)
        b = :zlib.deflate(z, data, :finish)
        :zlib.deflateEnd(z)
        b
      after
        :zlib.close(z)
      end

    :erlang.iolist_to_binary(bs)
  end

  @spec decode!(binary()) :: any()
  def decode!(term) do
    try do
      :zlib.unzip(term)
    rescue
      ErlangError -> term
    end
    |> :erlang.binary_to_term()
  end

  @doc """
    decode! variant for decoding locally created files, can decode atoms.
  """
  def decode_unsafe(term) do
    term =
      try do
        :zlib.unzip(term)
      rescue
        ErlangError -> term
      end

    try do
      {:ok, :erlang.binary_to_term(term)}
    rescue
      e in ErlangError -> {:error, e}
    end
  end

  def decode_unsafe!(term) do
    {:ok, term} = decode_unsafe(term)
    term
  end
end

defmodule ZBert do
  require Record
  Record.defrecord(:zbert, in_stream: nil, out_stream: nil, module: nil)

  def init(mod) do
    out = :zlib.open()
    :ok = :zlib.deflateInit(out)

    inc = :zlib.open()
    :ok = :zlib.inflateInit(inc)

    zbert(in_stream: inc, out_stream: out, module: mod)
  end

  def encode!(zbert(out_stream: str, module: mod), term) do
    data = mod.encode!(term)
    :zlib.deflate(str, data, :sync)
  end

  def decode!(zbert(in_stream: str, module: mod), data) do
    :zlib.inflate(str, data)
    |> mod.decode!()
  end
end
