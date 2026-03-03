# Verifies hex encoding behaviour used by RpcClient (dio_ticket, dio_message).
# DiodeClient.Base16.encode/2 always returns 0x-prefixed hex, so RpcClient must not prepend "0x" again.
defmodule RpcClientEncodingTest do
  use ExUnit.Case, async: true
  alias DiodeClient.Base16

  test "Base16.encode(binary, false) returns 0x-prefixed string" do
    bin = <<1, 2, 3, 255>>
    result = Base16.encode(bin, false)

    assert String.starts_with?(result, "0x"),
           "Base16.encode/2 already prefixes 0x; got #{inspect(result)}. Do not prepend \"0x\" in RpcClient."
  end

  test "prepending 0x to Base16.encode causes double 0x (RpcClient must not add 0x)" do
    # "Hello"
    bin = <<72, 101, 108, 108, 111>>
    encoded = Base16.encode(bin, false)
    assert encoded == "0x48656c6c6f", "encode already returns 0x-prefixed"

    # Code that does "0x" <> Base16.encode(bin, false) would produce 0x0x...:
    with_extra_prefix = "0x" <> encoded

    assert String.starts_with?(with_extra_prefix, "0x0x"),
           "Prepending \"0x\" causes double prefix: #{inspect(with_extra_prefix)}. RpcClient must use Base16.encode(...) only."
  end
end
