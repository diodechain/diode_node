# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule BinaryLRUTest do
  use ExUnit.Case

  test "base" do
    lru = BinaryLRU.new(:test_base, 10)
    assert BinaryLRU.size(lru) == 0

    BinaryLRU.insert(lru, "key", "value")
    assert BinaryLRU.size(lru) == 1

    assert BinaryLRU.get(lru, "key") == "value"

    assert BinaryLRU.fetch(lru, "nothing", fn -> "zzzz" end) == "zzzz"
    assert BinaryLRU.get(lru, "nothing") == "zzzz"
  end

  test "limit #1" do
    lru = BinaryLRU.new(:test_limit1, 3)
    assert BinaryLRU.size(lru) == 0

    BinaryLRU.insert(lru, "a", "avalue")
    BinaryLRU.insert(lru, "b", "bvalue")
    BinaryLRU.insert(lru, "c", "cvalue")

    assert BinaryLRU.memory_size(lru) == 0
    assert BinaryLRU.size(lru) == 0
  end

  test "limit #2" do
    lru = BinaryLRU.new(:test_limit2, 20)
    assert BinaryLRU.size(lru) == 0

    BinaryLRU.insert(lru, "a", "avalue")
    BinaryLRU.insert(lru, "b", "bvalue")
    BinaryLRU.insert(lru, "c", "cvalue")

    assert BinaryLRU.memory_size(lru) == 18
    assert BinaryLRU.size(lru) == 2
    assert BinaryLRU.get(lru, "a") == nil
    assert BinaryLRU.get(lru, "b") == "bvalue"
    assert BinaryLRU.get(lru, "c") == "cvalue"

    BinaryLRU.insert(lru, "d", "dvalue")

    assert BinaryLRU.size(lru) == 2
    assert BinaryLRU.get(lru, "a") == nil
    assert BinaryLRU.get(lru, "b") == nil
    assert BinaryLRU.get(lru, "c") == "cvalue"
    assert BinaryLRU.get(lru, "d") == "dvalue"
  end

  test "repeat" do
    lru = BinaryLRU.new(:test_repeat, 50)
    assert BinaryLRU.size(lru) == 0

    BinaryLRU.insert(lru, "a", "avalue")
    BinaryLRU.insert(lru, "b", "bvalue")
    BinaryLRU.insert(lru, "c", "cvalue")

    assert BinaryLRU.size(lru) == 3
    assert BinaryLRU.get(lru, "a") == "avalue"
    assert BinaryLRU.get(lru, "b") == "bvalue"
    assert BinaryLRU.get(lru, "c") == "cvalue"

    BinaryLRU.insert(lru, "a", "avalue2")

    assert BinaryLRU.size(lru) == 3
    assert BinaryLRU.get(lru, "a") == "avalue"
    assert BinaryLRU.get(lru, "b") == "bvalue"
    assert BinaryLRU.get(lru, "c") == "cvalue"

    BinaryLRU.delete(lru, "a")
    assert BinaryLRU.size(lru) == 2
    assert BinaryLRU.get(lru, "a") == nil

    BinaryLRU.insert(lru, "a", "avalue2")
    assert BinaryLRU.size(lru) == 3
    assert BinaryLRU.get(lru, "a") == "avalue2"
  end
end
