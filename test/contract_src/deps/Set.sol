// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.7.6;

library Set {
  struct Data {
    mapping(address => uint256) indexes;
    address[] items;
  }

  function Add(Data storage self, address _item) internal {
      if (IsMember(self, _item)) {
          return;
      }
      self.items.push(_item);
      self.indexes[_item] = self.items.length;
  }

  function Remove(Data storage self, address _item) internal {
      uint256 idx = self.indexes[_item];
      if (idx == 0) {
          return;
      }
      // Backuping the current last item
      uint256 last = self.items.length;
      if (last != idx) {
        address lastItem = self.items[last - 1];
        self.items[idx - 1] = lastItem;
        self.indexes[lastItem] = idx;
      }
      self.items.pop();
      delete self.indexes[_item];
  }

  function IsMember(Data storage self, address _item) internal view returns (bool) {
      uint256 idx = self.indexes[_item];
      if (idx == 0 || idx > self.items.length) {
        return false;
      }
      return self.items[idx - 1] == _item;
  }

  function Members(Data storage self) internal view returns (address[] storage) {
    return self.items;
  }

  function Size(Data storage self) internal view returns (uint256) {
    return self.items.length;
  }

  function Clear(Data storage self) internal {
    for (uint i = self.items.length; i > 0; i--) {
      address item = self.items[i-1];
      self.items.pop();
      delete self.indexes[item];
    }
  }
}
