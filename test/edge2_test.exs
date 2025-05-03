# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Edge2Test do
  use ExUnit.Case, async: false
  alias Network.Server, as: Server
  alias Network.EdgeV2, as: EdgeHandler
  alias Object.TicketV2, as: Ticket
  alias Object.Channel, as: Channel
  import TestHelper
  import Ticket
  import Channel
  import Edge2Client
  import While

  @ticket_grace 8196
  @port Rlpx.num2bin(3000)

  setup do
    TicketStore.clear()
    Model.KademliaSql.clear()
    :persistent_term.put(:no_tickets, false)
    ensure_clients()
  end

  setup_all do
    spawn(Edge2Test, :tick, [])

    IO.puts("Starting clients")
    Diode.ticket_grace(@ticket_grace)
    :persistent_term.put(:no_tickets, false)
    Process.put(:req_id, 0)
    ensure_clients()

    on_exit(fn ->
      IO.puts("Killing clients")
      ensure_clients()
      {:ok, _} = call(:client_1, :quit)
      {:ok, _} = call(:client_2, :quit)
    end)
  end

  def tick() do
    # IO.inspect(Wallet.printable(Diode.wallet()))
    Process.sleep(500)
    tick()
  end

  test "connect" do
    # Test that clients are connected
    assert call(:client_1, :ping) == {:ok, :pong}
    assert call(:client_2, :ping) == {:ok, :pong}
    conns = Server.get_connections(EdgeHandler)
    assert map_size(conns) == 2

    # Test that clients are connected to this node
    {:ok, peer_1} = call(:client_1, :peerid)
    {:ok, peer_2} = call(:client_2, :peerid)
    assert Wallet.equal?(Diode.wallet(), peer_1)
    assert Wallet.equal?(Diode.wallet(), peer_2)

    # Test that clients connected match the test file identities
    [id1, id2] = Map.keys(conns)

    if Wallet.equal?(id1, clientid(1)) do
      assert Wallet.equal?(id2, clientid(2))
    else
      assert Wallet.equal?(id1, clientid(2))
      assert Wallet.equal?(id2, clientid(1))
    end

    # Test byte counter matches
    assert call(:client_1, :bytes) == {:ok, 75}
    assert call(:client_2, :bytes) == {:ok, 75}
    assert rpc(:client_1, ["bytes"]) == [75 |> to_sbin()]
    assert rpc(:client_2, ["bytes"]) == [75 |> to_sbin()]
  end

  test "getblock" do
    assert rpc(:client_1, ["av:getblockpeak"]) == [peaknumber() |> to_bin()]
  end

  test "getaccount" do
    %{"balance" => <<0>>, "storage_root" => "", "nonce" => <<0>>} =
      hd(rpc(:client_1, ["av:getaccount", peaknumber(), "01234567890123456789"]))
      |> Rlpx.list2map()

    %{"balance" => <<0>>, "storage_root" => "", "nonce" => <<0>>} =
      hd(rpc(:client_1, ["av:getaccount", peaknumber(), Wallet.address!(Wallet.new())]))
      |> Rlpx.list2map()

    "not implemented" =
      hd(rpc(:client_1, ["av:getaccountroots", peaknumber(), Wallet.address!(Wallet.new())]))

    addr = hd(genesis_accounts())
    [ret | _proof] = rpc(:client_1, ["av:getaccount", peaknumber(), addr])

    %{"balance" => _, "storage_root" => "", "nonce" => <<_nonce>>} = Rlpx.list2map(ret)
  end

  defp genesis_accounts() do
    System.get_env("WALLETS")
    |> String.split(" ")
    |> Enum.map(fn w -> Wallet.address!(Wallet.from_privkey(Base16.decode(w))) end)
  end

  test "getaccountvalue" do
    # ["account does not exist"] =
    [
      <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0>>
    ] = rpc(:client_1, ["av:getaccountvalue", peaknumber(), "01234567890123456789", 0])

    addr = hd(genesis_accounts())

    [
      <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0>>
    ] = rpc(:client_1, ["av:getaccountvalue", peaknumber(), addr, 0])
  end

  test "ticket" do
    :persistent_term.put(:no_tickets, true)
    {:ok, _} = call(:client_1, :quit)
    {:ok, _} = call(:client_2, :quit)
    TicketStore.clear()
    ensure_clients()

    tck =
      ticketv2(
        chain_id: chain().chain_id(),
        server_id: Wallet.address!(Diode.wallet()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        epoch: epoch(),
        fleet_contract: developer_fleet_address()
      )
      |> Ticket.device_sign(clientkey(1))

    assert Ticket.device_address(tck) == Wallet.address!(clientid(1))

    # The first ticket submission should work
    ret =
      rpc(:client_1, [
        "ticketv2",
        Ticket.chain_id(tck) |> to_bin(),
        Ticket.epoch(tck) |> to_bin(),
        Ticket.fleet_contract(tck),
        Ticket.total_connections(tck) |> to_bin(),
        Ticket.total_bytes(tck) |> to_bin(),
        Ticket.local_address(tck),
        Ticket.device_signature(tck)
      ])

    assert ret == ["thanks!", ""]

    # Submitting a second ticket with the same count should fail
    assert rpc(:client_1, [
             "ticketv2",
             Ticket.chain_id(tck) |> to_bin(),
             Ticket.epoch(tck) |> to_bin(),
             Ticket.fleet_contract(tck),
             Ticket.total_connections(tck),
             Ticket.total_bytes(tck),
             Ticket.local_address(tck),
             Ticket.device_signature(tck)
           ]) ==
             [
               "too_low",
               Ticket.chain_id(tck) |> to_bin(),
               Ticket.epoch(tck) |> to_bin(),
               Ticket.total_connections(tck) |> to_bin(),
               Ticket.total_bytes(tck) |> to_bin(),
               Ticket.local_address(tck),
               Ticket.device_signature(tck)
             ]

    # Waiting for Kademlia Debouncer to write the object to the file
    Process.sleep(1000)

    [ticket] = rpc(:client_1, ["getobject", Wallet.address!(clientid(1))])

    loc2 = Object.decode_rlp_list!(ticket)
    assert Ticket.device_blob(tck) == Ticket.device_blob(loc2)

    assert Secp256k1.verify(
             Diode.wallet(),
             Ticket.server_blob(loc2),
             Ticket.server_signature(loc2),
             :kec
           ) == true

    public = Secp256k1.recover!(Ticket.server_signature(loc2), Ticket.server_blob(loc2), :kec)
    id = Wallet.from_pubkey(public) |> Wallet.address!()

    assert Wallet.address!(Diode.wallet()) == Wallet.address!(Wallet.from_pubkey(public))
    assert id == Wallet.address!(Diode.wallet())

    obj = Diode.self()
    assert(Object.key(obj) == id)
    enc = Rlp.encode!(Object.encode_list!(obj))
    assert obj == Object.decode_rlp_list!(Rlp.decode!(enc))

    # Getnode
    [node] = rpc(:client_1, ["getnode", id])
    node = Object.decode_rlp_list!(node)
    assert(Object.key(node) == id)

    # Testing ticket integrity
    Model.TicketSql.tickets_raw()
    |> Enum.each(fn {dev, fleet, epoch, tck} ->
      assert Object.TicketV1.device_address(tck) == dev
      assert Object.TicketV1.epoch(tck) == epoch
      assert Object.TicketV1.fleet_contract(tck) == fleet
    end)

    # Testing disconnect
    [_req, "bad input"] = rpc(:client_1, ["garbage", String.pad_leading("", 1024 * 8)])

    csend(:client_1, "garbage", String.pad_leading("", 1024))
    {:ok, [_req, ["goodbye", "ticket expected", "you might get blocked"]]} = crecv(:client_1)
    {:error, :timeout} = crecv(:client_1)
  end

  test "ticket_submission_reward" do
    :persistent_term.put(:no_tickets, true)
    {:ok, _} = call(:client_1, :quit)
    {:ok, _} = call(:client_2, :quit)
    TicketStore.clear()
    ensure_clients()

    fleet = Contract.Registry.fleet(chain().chain_id(), developer_fleet_address())
    assert fleet.currentBalance > 100_000

    old = peaknumber()
    RemoteChain.RPC.rpc!(chain(), "evm_mine")

    while old == peaknumber() do
      # The websocket conn should auto-refresh
      Process.sleep(100)
    end

    tck =
      ticketv2(
        chain_id: chain().chain_id(),
        server_id: Diode.address(),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        epoch: epoch(),
        fleet_contract: developer_fleet_address()
      )
      |> Ticket.device_sign(clientkey(1))

    # The first ticket submission should work
    assert rpc(:client_1, [
             "ticketv2",
             Ticket.chain_id(tck) |> to_bin(),
             Ticket.epoch(tck) |> to_bin(),
             Ticket.fleet_contract(tck),
             Ticket.total_connections(tck) |> to_bin(),
             Ticket.total_bytes(tck) |> to_bin(),
             Ticket.local_address(tck),
             Ticket.device_signature(tck)
           ]) ==
             [
               "thanks!",
               ""
             ]

    initial_epoch = epoch()
    epoch = initial_epoch
    r_epoch = Contract.Registry.current_epoch(chain())
    assert epoch == r_epoch
    assert [_tck2] = TicketStore.tickets(epoch())

    while epoch == epoch() do
      RemoteChain.RPC.rpc!(chain(), "evm_increaseTime", [div(chain().epoch_duration(), 3)])
      RemoteChain.RPC.rpc!(chain(), "evm_mine")
    end

    assert epoch + 1 == epoch()

    # 'currentEpoch' hasn't increased yet will only increase once a ticket is submitted or EndEpoch is called
    r_epoch2 = Contract.Registry.current_epoch(chain())
    assert epoch == r_epoch2

    tx = Ticket.raw(tck) |> Contract.Registry.submit_ticket_raw_tx()
    assert "0x" = Shell.call_tx!(tx, "latest")
    Shell.await_tx(tx)

    # 'currentEpoch' must have increased
    r_epoch3 = Contract.Registry.current_epoch(chain())
    assert r_epoch3 == epoch()

    # 'fleet.score' must have increased
    fleet2 = Contract.Registry.fleet(chain().chain_id(), developer_fleet_address())

    assert fleet2.score > fleet.score

    # Finish next epoch to claim rewards
    epoch = epoch()

    while epoch == epoch() do
      RemoteChain.RPC.rpc!(chain(), "evm_increaseTime", [div(chain().epoch_duration(), 3)])
      RemoteChain.RPC.rpc!(chain(), "evm_mine")
    end

    assert Ticket.server_id(tck) == Diode.address()

    Shell.transaction(Diode.wallet(), chain().registry_address(), "EndEpochForAllFleets", [], [],
      chainId: chain().chain_id()
    )
    |> Shell.await_tx()

    assert Contract.Registry.current_epoch(chain()) == initial_epoch + 2

    fleet3 = Contract.Registry.fleet(chain().chain_id(), developer_fleet_address())

    assert fleet3.currentEpoch > fleet2.currentEpoch
    assert fleet3.score == 0

    assert Contract.Registry.relay_rewards(chain(), Diode.address()) > 0
  end

  test "port" do
    check_counters()
    # Checking wrong port_id usage
    assert rpc(:client_1, ["portopen", "wrongid", @port]) == ["invalid device id"]
    assert rpc(:client_1, ["portopen", "12345678901234567890", @port]) == ["not found"]

    assert rpc(:client_1, ["portopen", Wallet.address!(clientid(1)), @port]) == [
             "can't connect to yourself"
           ]

    check_counters()
    # Connecting to "right" port id
    client2id = Wallet.address!(clientid(2))
    req1 = req_id()
    assert csend(:client_1, ["portopen", client2id, @port], req1) == {:ok, :ok}
    {:ok, [req2, ["portopen", @port, ref1, access_id]]} = crecv(:client_2)
    assert access_id == Wallet.address!(clientid(1))

    assert csend(:client_2, ["response", ref1, "ok"], req2) == {:ok, :ok}
    {:ok, [_req, ["response", "ok", ref2]]} = crecv(:client_1, req1)
    assert ref1 == ref2

    for n <- 1..50 do
      check_counters()

      # Sending traffic
      msg = String.duplicate("ping from 2!", n * n)
      assert rpc(:client_2, ["portsend", ref1, msg]) == ["ok"]
      assert {:ok, [_req, ["portsend", ^ref1, ^msg]]} = crecv(:client_1)

      check_counters()

      # Both ways
      msg = String.duplicate("ping from 1!", n * n)
      assert rpc(:client_1, ["portsend", ref1, msg]) == ["ok"]
      assert {:ok, [_req, ["portsend", ^ref1, ^msg]]} = crecv(:client_2)
    end

    check_counters()
    # Closing port
    assert rpc(:client_1, ["portclose", ref1]) == ["ok"]
    assert {:ok, [_req, ["portclose", ^ref1]]} = crecv(:client_2)

    # Sending to closed port
    assert rpc(:client_2, ["portsend", ref1, "ping from 2!"]) == [
             "port does not exist"
           ]

    assert rpc(:client_1, ["portsend", ref1, "ping from 1!"]) == [
             "port does not exist"
           ]
  end

  test "channel" do
    # Checking non existing channel
    assert rpc(:client_1, ["portopen", "12345678901234567890123456789012", @port]) == [
             "not found"
           ]

    ch =
      channel(
        chain_id: chain().chain_id(),
        server_id: Wallet.address!(Diode.wallet()),
        block_number: peaknumber(),
        fleet_contract: developer_fleet_address(),
        type: "broadcast",
        name: "testchannel"
      )
      |> Channel.sign(clientkey(1))

    port = Object.Channel.key(ch)

    [channel] =
      rpc(:client_1, [
        "channel",
        Channel.chain_id(ch),
        Channel.block_number(ch),
        Channel.fleet_contract(ch),
        Channel.type(ch),
        Channel.name(ch),
        Channel.params(ch),
        Channel.signature(ch)
      ])

    assert Object.decode_rlp_list!(channel) == ch
    assert ["ok", ref1] = rpc(:client_1, ["portopen", port, @port])
    ch2 = Channel.sign(ch, clientkey(2))

    [channel2] =
      rpc(:client_2, [
        "channel",
        Channel.chain_id(ch),
        Channel.block_number(ch2),
        Channel.fleet_contract(ch2),
        Channel.type(ch2),
        Channel.name(ch2),
        Channel.params(ch2),
        Channel.signature(ch2)
      ])

    # Asserting that the retrieved channel is actually the one openend by client1
    assert Object.decode_rlp_list!(channel2) == ch

    assert ["ok", ref2] = rpc(:client_2, ["portopen", port, @port])

    for n <- 1..50 do
      # Sending traffic
      msg = String.duplicate("ping from 2!", n * n)
      assert rpc(:client_2, ["portsend", ref2, msg]) == ["ok"]
      assert {:ok, [_req, ["portsend", ^ref1, ^msg]]} = crecv(:client_1)

      # Both ways
      msg = String.duplicate("ping from 1!", n * n)
      assert rpc(:client_1, ["portsend", ref1, msg]) == ["ok"]
      assert {:ok, [_req, ["portsend", ^ref2, ^msg]]} = crecv(:client_2)
    end

    # Closing port
    # Channels always stay open for all other participants
    # So client_1 closing does leave the port open for client_2
    assert rpc(:client_1, ["portclose", ref1]) == ["ok"]

    # Sending to closed port
    assert rpc(:client_1, ["portsend", ref1, "ping from 1!"]) == ["port does not exist"]
    assert rpc(:client_2, ["portsend", ref2, "ping from 2!"]) == ["ok"]
  end

  # test "channel-mailbox" do
  #   ch =
  #     channel(
  #       server_id: Wallet.address!(Diode.wallet()),
  #       block_number: peaknumber(),
  #       fleet_contract: developer_fleet_address(),
  #       type: "mailbox",
  #       name: "testchannel"
  #     )
  #     |> Channel.sign(clientkey(1))

  #   port = Object.Channel.key(ch)

  #   [channel] =
  #     rpc(:client_1, [
  #       "channel",
  #       Channel.block_number(ch),
  #       Channel.fleet_contract(ch),
  #       Channel.type(ch),
  #       Channel.name(ch),
  #       Channel.params(ch),
  #       Channel.signature(ch)
  #     ])

  #   assert Object.decode_rlp_list!(channel) == ch
  #   assert ["ok", ref1] = rpc(:client_1, ["portopen", port, @port])

  #   for n <- 1..50 do
  #     assert rpc(:client_1, ["portsend", ref1, "ping #{n}"]) == ["ok"]
  #   end

  #   assert rpc(:client_1, ["portclose", ref1]) == ["ok"]
  #   assert ["ok", ref2] = rpc(:client_2, ["portopen", port, @port])

  #   for n <- 1..50 do
  #     msg = "ping #{n}"
  #     assert {:ok, [_req, ["portsend", ^ref2, ^msg]]} = crecv(:client_2)
  #   end

  #   assert rpc(:client_2, ["portclose", ref2]) == ["ok"]
  # end

  test "porthalfopen_a" do
    # Connecting to "right" port id
    client2id = Wallet.address!(clientid(2))
    assert csend(:client_1, ["portopen", client2id, @port]) == {:ok, :ok}
    {:ok, [req, ["portopen", @port, ref1, access_id]]} = crecv(:client_2)
    assert access_id == Wallet.address!(clientid(1))

    kill(:client_1)

    assert csend(:client_2, ["response", ref1, "ok"], req) == {:ok, :ok}
    {:ok, [_req, ["portclose", ref2]]} = crecv(:client_2)
    assert ref1 == ref2
  end

  test "porthalfopen_b" do
    # Connecting to "right" port id
    client2id = Wallet.address!(clientid(2))
    assert csend(:client_1, ["portopen", client2id, @port]) == {:ok, :ok}
    {:ok, [_req, ["portopen", @port, ref1, access_id]]} = crecv(:client_2)
    assert access_id == Wallet.address!(clientid(1))

    kill(:client_2)

    {:ok, [_req, [_reason, ref2]]} = crecv(:client_1)
    assert ref1 == ref2
  end

  test "port2x" do
    # First connection
    # Process.sleep(1000)
    client2id = Wallet.address!(clientid(2))
    assert csend(:client_1, ["portopen", client2id, @port]) == {:ok, :ok}
    Process.sleep(1000)
    assert call(:client_1, :peek) == {:ok, []}

    {:ok, [req, ["portopen", @port, ref1, access_id]]} = crecv(:client_2)
    assert access_id == Wallet.address!(clientid(1))

    assert csend(:client_2, ["response", ref1, "ok"], req) == {:ok, :ok}
    {:ok, [_req, ["response", "ok", ref2]]} = crecv(:client_1)
    assert ref1 == ref2

    # Second connection
    assert csend(:client_1, ["portopen", client2id, @port]) == {:ok, :ok}
    {:ok, [req, ["portopen", @port, ref3, access_id]]} = crecv(:client_2)
    assert access_id == Wallet.address!(clientid(1))

    assert csend(:client_2, ["response", ref3, "ok"], req) == {:ok, :ok}
    {:ok, [_req, ["response", "ok", ref4]]} = crecv(:client_1)
    assert ref3 == ref4
    assert ref1 != ref3

    for _ <- 1..10 do
      # Sending traffic
      assert rpc(:client_2, ["portsend", ref1, "ping from 2 on 1!"]) == ["ok"]

      assert {:ok, [_req, ["portsend", ^ref1, "ping from 2 on 1!"]]} = crecv(:client_1)

      assert rpc(:client_2, ["portsend", ref4, "ping from 2 on 2!"]) == ["ok"]

      assert {:ok, [_req, ["portsend", ^ref4, "ping from 2 on 2!"]]} = crecv(:client_1)
    end

    # Closing port1
    assert rpc(:client_1, ["portclose", ref1]) == ["ok"]
    assert {:ok, [_req, ["portclose", ^ref1]]} = crecv(:client_2)
    # Closing port2
    assert rpc(:client_1, ["portclose", ref4]) == ["ok"]
    assert {:ok, [_req, ["portclose", ^ref4]]} = crecv(:client_2)
  end

  test "sharedport flags" do
    # Connecting with wrong flags
    client2id = Wallet.address!(clientid(2))
    ["invalid flags"] = rpc(:client_1, ["portopen", client2id, @port, "s"])
  end

  test "sharedport" do
    # Connecting to port id
    client2id = Wallet.address!(clientid(2))
    assert csend(:client_1, ["portopen", client2id, @port, "rws"]) == {:ok, :ok}
    {:ok, [req, ["portopen", @port, ref1, access_id]]} = crecv(:client_2)
    assert access_id == Wallet.address!(clientid(1))

    # 'Device' accepts connection
    assert csend(:client_2, ["response", ref1, "ok"], req) == {:ok, :ok}
    {:ok, [_req, ["response", "ok", ref2]]} = crecv(:client_1)
    assert ref1 == ref2

    # Connecting same client to same port again
    ["ok", ref3] = rpc(:client_1, ["portopen", client2id, @port, "rws"])
    assert ref3 != ref2

    # Client1 owns ref2 and ref3
    # Client2 owns ref1

    for _ <- 1..10 do
      # Sending traffic
      assert rpc(:client_2, ["portsend", ref1, "ping from 2!"]) == ["ok"]
      {:ok, [_req, ["portsend", ret1, "ping from 2!"]]} = crecv(:client_1)
      {:ok, [_req, ["portsend", ret2, "ping from 2!"]]} = crecv(:client_1)

      assert Enum.sort([ref2, ref3]) == Enum.sort([ret1, ret2])
    end

    # Closing port ref2 (same value as ref1)
    assert rpc(:client_1, ["portclose", ref2]) == ["ok"]

    # Other port ref3 still working
    assert rpc(:client_1, ["portsend", ref3, "ping from 3!"]) == ["ok"]
    Process.sleep(100)
    {:ok, [_req, ["portsend", ^ref1, "ping from 3!"]]} = crecv(:client_2)

    # Sending to closed port
    assert rpc(:client_1, ["portsend", ref1, "ping from 1!"]) == [
             "port does not exist"
           ]

    # Closing port ref3
    assert rpc(:client_1, ["portclose", ref3]) == ["ok"]
    assert {:ok, [_req, ["portclose", ^ref1]]} = crecv(:client_2)
  end

  test "transaction" do
    [from, to] = wallets() |> Enum.reverse() |> Enum.take(2)

    to = Wallet.address!(to)

    tx =
      Shell.create_transaction(from, <<"">>, %{
        "value" => 0,
        "to" => to,
        "chainId" => chain().chain_id()
      })

    ["ok"] = rpc(:client_1, ["av:sendtransaction", to_rlp(tx)])
    RemoteChain.RPC.rpc!(chain(), "evm_mine")
    tx
  end

  defp to_rlp(tx) do
    tx |> DiodeClient.Transaction.to_rlp() |> Rlp.encode!()
  end

  defp check_counters() do
    # Checking counters
    rpc(:client_2, ["bytes"])
    {:ok, bytes} = call(:client_2, :bytes)
    assert rpc(:client_2, ["bytes"]) == [bytes |> to_sbin()]

    rpc(:client_1, ["bytes"])
    {:ok, bytes} = call(:client_1, :bytes)
    assert rpc(:client_1, ["bytes"]) == [bytes |> to_sbin()]
  end

  defp kill(atom) do
    # :io.format("Killing ~p~n", [atom])

    case Process.whereis(atom) do
      nil ->
        :ok

      pid ->
        Process.exit(pid, :kill)
        wait_for_process(atom)
    end
  end

  defp wait_for_process(atom) do
    case Process.whereis(atom) do
      nil ->
        :ok

      _pid ->
        Process.sleep(100)
        wait_for_process(atom)
    end
  end
end
