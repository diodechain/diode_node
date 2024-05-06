# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Contract.Registry do
  @moduledoc """
    Wrapper for the DiodeRegistry contract functions
    as needed by the inner workings of the chain
  """

  def miner_value(chain_id, type, address, blockRef) when type >= 0 and type <= 3 do
    call(chain_id, "MinerValue", ["uint8", "address"], [type, address], blockRef)
    |> :binary.decode_unsigned()
  end

  def fleet_value(chain_id, type, address, blockRef) when type >= 0 and type <= 3 do
    call(chain_id, "ContractValue", ["uint8", "address"], [type, address], blockRef)
    |> :binary.decode_unsigned()
  end

  def min_transaction_fee(chain_id, blockRef) do
    call(chain_id, "MinTransactionFee", [], [], blockRef)
    |> :binary.decode_unsigned()
  end

  def epoch(chain_id, blockRef) do
    call(chain_id, "Epoch", [], [], blockRef)
    |> :binary.decode_unsigned()
  end

  def fee(chain_id, blockRef) do
    call(chain_id, "Fee", [], [], blockRef)
    |> :binary.decode_unsigned()
  end

  def fee_pool(chain_id, blockRef) do
    call(chain_id, "FeePool", [], [], blockRef)
    |> :binary.decode_unsigned()
  end

  def submit_ticket_raw_tx(ticket = [chain_id | _]) do
    Shell.transaction(
      Diode.wallet(),
      RemoteChain.registry_address(chain_id),
      "SubmitTicketRaw",
      ["bytes32[]"],
      [ticket]
    )
  end

  defp call(chain_id, name, types, values, blockRef) do
    {ret, _gas} =
      Shell.call(RemoteChain.registry_address(chain_id), name, types, values, blockRef: blockRef)

    ret
  end

  # This is the code for the test/dev variant of the registry contract
  # Imported on 31rd July 2020 from build/contracts/DiodeRegistry.json
  def registry_light() do
    "0x60c060405260006007556000600d553480156200001b57600080fd5b5060405162001e3738038062001e378339810160408190526200003e916200005d565b6001600160601b0319606092831b8116608052911b1660a052620000b4565b6000806040838503121562000070578182fd5b82516200007d816200009b565b602084015190925062000090816200009b565b809150509250929050565b6001600160a01b0381168114620000b157600080fd5b50565b60805160601c60a05160601c611d63620000d46000395050611d636000f3fe6080604052600436106100f35760003560e01c80638da085641161008a578063c76a117311610059578063c76a11731461028b578063cb106cf8146102ab578063f4b74016146102c0578063f595416f146102e0576100f3565b80638da08564146102145780638e0383a41461022957806399ab110d14610256578063c4a9e11614610276576100f3565b806365c68de5116100c657806365c68de5146101855780636f9874a4146101b25780637b4a927a146101c75780637fca4a29146101f4576100f3565b80630a938dff146100f85780631b3b98c81461012e57806345780f5f14610150578063534a242214610172575b600080fd5b34801561010457600080fd5b50610118610113366004611a07565b6102f5565b6040516101259190611cc6565b60405180910390f35b34801561013a57600080fd5b5061014e610149366004611939565b6103b6565b005b34801561015c57600080fd5b506101656105d1565b6040516101259190611a3d565b61014e610180366004611813565b610633565b34801561019157600080fd5b506101a56101a03660046118be565b6107d5565b6040516101259190611c2f565b3480156101be57600080fd5b5061011861094f565b3480156101d357600080fd5b506101e76101e2366004611921565b610962565b6040516101259190611a29565b34801561020057600080fd5b5061014e61020f366004611813565b61098c565b34801561022057600080fd5b50610118610c2e565b34801561023557600080fd5b50610249610244366004611813565b610c34565b6040516101259190611bb4565b34801561026257600080fd5b5061014e61027136600461182f565b610cdf565b34801561028257600080fd5b50610118610e1c565b34801561029757600080fd5b5061014e6102a63660046118f6565b610e22565b3480156102b757600080fd5b50610118610fc5565b3480156102cc57600080fd5b506101e76102db366004611813565b610fcb565b3480156102ec57600080fd5b50610118610fe6565b600060ff83166103175761031061030b83610fec565b611066565b90506103b0565b8260ff16600114156103345761031061032f83610fec565b611075565b8260ff16600214156103515761031061034c83610fec565b611084565b8260ff166003141561036e5761031061036983610fec565b611093565b6040805162461bcd60e51b8152602060048201526012602482015271155b9a185b991b195908185c99dd5b595b9d60721b604482015290519081900360640190fd5b92915050565b864381106103df5760405162461bcd60e51b81526004016103d690611b7d565b60405180910390fd5b600754600019016103f282619d806110a2565b1461040f5760405162461bcd60e51b81526004016103d690611b2a565b84841761042e5760405162461bcd60e51b81526004016103d690611b4f565b60408051600680825260e082019092526000916020820160c08036833701905050905088408160008151811061046057fe5b602002602001018181525050610475886110eb565b8160018151811061048257fe5b602002602001018181525050610497876110eb565b816002815181106104a457fe5b6020026020010181815250508560001b816003815181106104c157fe5b6020026020010181815250508460001b816004815181106104de57fe5b60200260200101818152505083816005815181106104f857fe5b60200260200101818152505060006001610511836110ee565b60408087015187516020808a0151845160008152909101938490526105369493611a8a565b6020604051602081039080840390855afa158015610558573d6000803e3d6000fd5b50505060206040510351905061056e8982611148565b61057b8989838a8a6111fc565b806001600160a01b0316886001600160a01b03168a6001600160a01b03167fc21a4132cfb2e72d1dd6f45bcb2dabb1722a19b036c895975db93175b1c5c06f60405160405180910390a450505050505050505050565b6060600a80548060200260200160405190810160405280929190818152602001828054801561062957602002820191906000526020600020905b81546001600160a01b0316815260019091019060200180831161060b575b5050505050905090565b8061063d816113bf565b61068e576040805162461bcd60e51b815260206004820152601e60248201527f496e76616c696420666c65657420636f6e747261637420616464726573730000604482015290519081900360640190fd5b6000816001600160a01b031663bcea317f6040518163ffffffff1660e01b815260040160206040518083038186803b1580156106c957600080fd5b505afa1580156106dd573d6000803e3d6000fd5b505050506040513d60208110156106f357600080fd5b505190506001600160a01b038116331461073e5760405162461bcd60e51b8152600401808060200182810382526025815260200180611ce86025913960400191505060405180910390fd5b6107513461074b85610fec565b906113fb565b6001600160a01b038416600081815260066020908152604080832085518051825580840151600180840191909155908301516002830155958301518051600383015592830151600482015591810151600590920191909155513493917fd859864511fd3f512da77fc95a8c013b3a0e49bdface8f574b2df8527cecea7191a4505050565b6107dd611772565b60006107e884611418565b6001600160a01b038416600081815260048301602090815260408083206003810154825160808101845295865260018201549386019390935260028101549185019190915293945091606081018367ffffffffffffffff8111801561084c57600080fd5b5060405190808252806020026020018201604052801561088657816020015b6108736117a3565b81526020019060019003908161086b5790505b509052905060005b828110156109445760008460030182815481106108a757fe5b60009182526020808320909101546001600160a01b03168083526004880182526040928390208351608081018552815460ff161515815260018201548185015260028201548186019081526003909201546060808301918252865180820188528581529351958401959095525194820194909452918601518051919450908590811061092f57fe5b6020908102919091010152505060010161088e565b509695505050505050565b600061095d43619d806110a2565b905090565b6008818154811061097257600080fd5b6000918252602090912001546001600160a01b0316905081565b80610996816113bf565b6109e7576040805162461bcd60e51b815260206004820152601e60248201527f496e76616c696420666c65657420636f6e747261637420616464726573730000604482015290519081900360640190fd5b6000816001600160a01b031663bcea317f6040518163ffffffff1660e01b815260040160206040518083038186803b158015610a2257600080fd5b505afa158015610a36573d6000803e3d6000fd5b505050506040513d6020811015610a4c57600080fd5b505190506001600160a01b0381163314610a975760405162461bcd60e51b8152600401808060200182810382526025815260200180611ce86025913960400191505060405180910390fd5b6000836001600160a01b031663bcea317f6040518163ffffffff1660e01b815260040160206040518083038186803b158015610ad257600080fd5b505afa158015610ae6573d6000803e3d6000fd5b505050506040513d6020811015610afc57600080fd5b505190506000610b0b85610fec565b90506000610b1882611093565b905060008111610b62576040805162461bcd60e51b815260206004820152601060248201526f043616e277420776974686472617720360841b604482015290519081900360640190fd5b610b6c8282611432565b6001600160a01b038088166000908152600660209081526040808320855180518255808401516001830155820151600282015594820151805160038701559182015160048601559081015160059094019390935591519085169183156108fc02918491818181858888f19350505050158015610bec573d6000803e3d6000fd5b5060405181906001600160a01b038816906001907f7f22ec7a37a3fa31352373081b22bb38e1e0abd2a05b181ee7138a360edd3e1a90600090a4505050505050565b60075490565b610c3c611772565b6000610c4783611418565b90506040518060800160405280846001600160a01b03168152602001826001015481526020018260020154815260200182600301805480602002602001604051908101604052809291908181526020018280548015610ccf57602002820191906000526020600020905b81546001600160a01b03168152600190910190602001808311610cb1575b5050505050815250915050919050565b801580610cee57506009810615155b15610d0b5760405162461bcd60e51b81526004016103d690611afb565b60005b81811015610e175760006040518060600160405280858585600601818110610d3257fe5b905060200201358152602001858585600701818110610d4d57fe5b905060200201358152602001858585600801818110610d6857fe5b905060200201358152509050610e0e848484600001818110610d8657fe5b9050602002013560001c610dae868686600101818110610da257fe5b905060200201356110eb565b610dc0878787600201818110610da257fe5b878787600301818110610dcf57fe5b9050602002013560001c888888600401818110610de857fe5b9050602002013560001c898989600501818110610e0157fe5b90506020020135876103b6565b50600901610d0e565b505050565b60025481565b81610e2c816113bf565b610e7d576040805162461bcd60e51b815260206004820152601e60248201527f496e76616c696420666c65657420636f6e747261637420616464726573730000604482015290519081900360640190fd5b6000816001600160a01b031663bcea317f6040518163ffffffff1660e01b815260040160206040518083038186803b158015610eb857600080fd5b505afa158015610ecc573d6000803e3d6000fd5b505050506040513d6020811015610ee257600080fd5b505190506001600160a01b0381163314610f2d5760405162461bcd60e51b8152600401808060200182810382526025815260200180611ce86025913960400191505060405180910390fd5b610f4083610f3a86610fec565b906114af565b6001600160a01b038516600081815260066020908152604080832085518051825580840151600180840191909155908301516002830155958301518051600383015592830151600482015591810151600590920191909155518693917f81149c79fef0028ec92e02ee17f72b9bba024dce75220cba8d62f7bbcd0922b691a450505050565b60035481565b6004602052600090815260409020546001600160a01b031681565b600c5490565b610ff46117cd565b506001600160a01b0316600090815260066020908152604091829020825160a08101845281548185019081526001830154606080840191909152600284015460808401529082528451908101855260038301548152600483015481850152600590920154938201939093529082015290565b60006103b0826000015161151f565b60006103b08260000151611536565b60006103b08260200151611536565b60006103b0826020015161151f565b60006110e483836040518060400160405280601a81526020017f536166654d6174683a206469766973696f6e206279207a65726f00000000000081525061154a565b9392505050565b90565b60008160405160200180828051906020019060200280838360005b83811015611121578181015183820152602001611109565b50505050905001915050604051602081830303815290604052805190602001209050919050565b60405163d90bd65160e01b81528290610e17906001600160a01b0383169063d90bd6519061117a908690600401611a29565b60206040518083038186803b15801561119257600080fd5b505afa1580156111a6573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906111ca919061189e565b60405180604001604052806013815260200172556e726567697374657265642064657669636560681b815250846115ec565b600061120786611418565b805490915060ff16611269578054600160ff1990911681178255600a805491820181556000527fc65a7bb8d6351c1cf70c95a316cc6a92839c986682d98bc35f958f4883f9d2a80180546001600160a01b0319166001600160a01b0388161790555b6001600160a01b03851660009081526004820160205260409020805460ff166112c9578054600160ff199091168117825560038301805491820181556000908152602090200180546001600160a01b0319166001600160a01b0388161790555b6001600160a01b03851660009081526004820160205260409020805460ff16611329578054600160ff199091168117825560038301805491820181556000908152602090200180546001600160a01b0319166001600160a01b0388161790555b806002015485111561136f57600281018054908690556001830154908603906113529082611611565b6001808501919091558401546113689082611611565b6001850155505b80600301548411156113b557600381018054908590556002830154908503906113989082611611565b6002808501919091558401546113ae9082611611565b6002850155505b5050505050505050565b6000813f7fc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a4708181148015906113f357508115155b949350505050565b6114036117cd565b825161140f908361166b565b83525090919050565b6001600160a01b03166000908152600b6020526040902090565b61143a6117cd565b81611448846020015161151f565b1015611494576040805162461bcd60e51b8152602060048201526016602482015275496e737566666963656e742066726565207374616b6560501b604482015290519081900360640190fd5b60208301516114a390836116e1565b60208401525090919050565b6114b76117cd565b816114c5846000015161151f565b10156115025760405162461bcd60e51b8152600401808060200182810382526021815260200180611d0d6021913960400191505060405180910390fd5b825161150e90836116e1565b835260208301516114a3908361166b565b600061152c82600061166b565b6040015192915050565b600061154382600061166b565b5192915050565b600081836115d65760405162461bcd60e51b81526004018080602001828103825283818151815260200191508051906020019080838360005b8381101561159b578181015183820152602001611583565b50505050905090810190601f1680156115c85780820380516001836020036101000a031916815260200191505b509250505060405180910390fd5b5060008385816115e257fe5b0495945050505050565b818361160b5760405162461bcd60e51b81526004016103d69190611aa8565b50505050565b6000828201838110156110e4576040805162461bcd60e51b815260206004820152601b60248201527f536166654d6174683a206164646974696f6e206f766572666c6f770000000000604482015290519081900360640190fd5b6116736117f2565b61167c83611761565b6116b0576040805160608101825283815243602082015284518583015191928301916116a791611611565b905290506103b0565b6040805160608101909152835181906116c99085611611565b815243602082015260408581015191015290506103b0565b6116e96117f2565b6116f483600061166b565b9050818160400151101561174f576040805162461bcd60e51b815260206004820152601b60248201527f496e737566666963656e742066756e647320746f206465647563740000000000604482015290519081900360640190fd5b60408101805192909203909152919050565b602001516202ac6043919091031090565b604051806080016040528060006001600160a01b031681526020016000815260200160008152602001606081525090565b604051806060016040528060006001600160a01b0316815260200160008152602001600081525090565b60405180604001604052806117e06117f2565b81526020016117ed6117f2565b905290565b60405180606001604052806000815260200160008152602001600081525090565b600060208284031215611824578081fd5b81356110e481611ccf565b60008060208385031215611841578081fd5b823567ffffffffffffffff80821115611858578283fd5b818501915085601f83011261186b578283fd5b813581811115611879578384fd5b866020808302850101111561188c578384fd5b60209290920196919550909350505050565b6000602082840312156118af578081fd5b815180151581146110e4578182fd5b600080604083850312156118d0578182fd5b82356118db81611ccf565b915060208301356118eb81611ccf565b809150509250929050565b60008060408385031215611908578182fd5b823561191381611ccf565b946020939093013593505050565b600060208284031215611932578081fd5b5035919050565b600080600080600080600061012080898b031215611955578384fd5b883597506020808a013561196881611ccf565b975060408a013561197881611ccf565b965060608a0135955060808a0135945060a08a0135935060df8a018b1361199d578283fd5b6040516060810181811067ffffffffffffffff821117156119ba57fe5b6040528060c08c01848d018e10156119d0578586fd5b8594505b60038510156119f35780358252600194909401939083019083016119d4565b505080935050505092959891949750929550565b60008060408385031215611a19578182fd5b823560ff811681146118db578283fd5b6001600160a01b0391909116815260200190565b6020808252825182820181905260009190848201906040850190845b81811015611a7e5783516001600160a01b031683529284019291840191600101611a59565b50909695505050505050565b93845260ff9290921660208401526040830152606082015260800190565b6000602080835283518082850152825b81811015611ad457858101830151858201604001528201611ab8565b81811115611ae55783604083870101525b50601f01601f1916929092016040019392505050565b602080825260159082015274092dcecc2d8d2c840e8d2c6d6cae840d8cadccee8d605b1b604082015260600190565b6020808252600b908201526a0aee4dedcce40cae0dec6d60ab1b604082015260600190565b602080825260149082015273496e76616c6964207469636b65742076616c756560601b604082015260600190565b60208082526017908201527f5469636b65742066726f6d20746865206675747572653f000000000000000000604082015260600190565b6000602080835260a0830160018060a01b03808651168386015282860151604086015260408601516060860152606086015160808087015282815180855260c08801915085830194508692505b80831015611c2357845184168252938501936001929092019190850190611c01565b50979650505050505050565b602080825282516001600160a01b0390811683830152838201516040808501919091528085015160608086019190915280860151608080870152805160a087018190526000959491850193919286929160c08901905b80851015611cb8578651805187168352888101518984015284015184830152958701956001949094019390820190611c85565b509998505050505050505050565b90815260200190565b6001600160a01b0381168114611ce457600080fd5b5056fe4f6e6c792074686520666c656574206163636f756e74616e742063616e20646f207468697343616e277420756e7374616b65206d6f7265207468616e206973207374616b6564a26469706673582212205aca52acd73c820fb524f7ca0c1e70cd49b18ed79d44eaab6bce5b191757d34e64736f6c63430007060033"
    |> Base16.decode()
  end
end
