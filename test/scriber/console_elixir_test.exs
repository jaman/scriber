defmodule Scriber.ConsoleElixirTest do
  use ExUnit.Case, async: false

  alias Scriber.{Console, Game, Lattice}

  setup do
    home = Path.join(System.tmp_dir!(), "scriber_console_#{System.unique_integer([:positive])}")
    previous = System.get_env("SCRIBER_HOME")
    System.put_env("SCRIBER_HOME", home)

    on_exit(fn ->
      File.rm_rf(home)

      if previous,
        do: System.put_env("SCRIBER_HOME", previous),
        else: System.delete_env("SCRIBER_HOME")
    end)

    game = %{Game.new(seed: 777) | shards: 200}
    dir = Lattice.prepare(game.seed, game.depth)

    %{game: game, console: Console.new(dir, game.depth), dir: dir}
  end

  defp run(console, game, line) do
    Console.submit(%{console | input: line}, game, seed: game.seed)
  end

  defp said(console) do
    console |> Console.transcript() |> Enum.map_join("\n", &elem(&1, 0))
  end

  defp last(console, count) do
    console
    |> Console.transcript()
    |> Enum.take(-count)
    |> Enum.map_join("\n", &elem(&1, 0))
  end

  describe "typing" do
    test "characters accumulate and backspace rubs them out", %{console: console} do
      typed = console |> Console.type("f") |> Console.type("o") |> Console.type("o")

      assert typed.input == "foo"
      assert Console.backspace(typed).input == "fo"
    end

    test "backspace on an empty prompt does nothing", %{console: console} do
      assert Console.backspace(console).input == ""
    end

    test "submitting clears the prompt and echoes what was run", %{console: console, game: game} do
      {after_run, _game} = run(console, game, "help")

      assert after_run.input == ""
      assert said(after_run) =~ "$ help"
    end

    test "an empty line does nothing but echo", %{console: console, game: game} do
      {after_run, ^game} = run(console, game, "   ")
      refute last(after_run, 1) =~ "not a command"
    end
  end

  describe "reading the stratum" do
    test "ls lists the directory", %{console: console, game: game} do
      {listed, _} = run(console, game, "ls")

      assert said(listed) =~ "manifest"
      assert said(listed) =~ "README"
      assert said(listed) =~ "logs/", "directories should be marked"
    end

    test "cat reads a file and says so when it cannot", %{console: console, game: game} do
      {read, _} = run(console, game, "cat README")
      assert said(read) =~ "LATTICE"

      {missing, _} = run(console, game, "cat nothing-here")
      assert last(missing, 1) =~ "cat: nothing-here"
    end

    test "grep finds lines and reports when it finds none", %{console: console, game: game} do
      state = Lattice.gate_state(game.seed, game.depth)

      {found, _} = run(console, game, "grep #{state} manifest")
      assert said(found) =~ "key="

      {empty, _} = run(console, game, "grep zzzznope manifest")
      assert last(empty, 1) =~ "no match"
    end

    test "grep needs something to search", %{console: console, game: game} do
      {refused, _} = run(console, game, "grep")
      assert last(refused, 1) =~ "usage: grep"
    end
  end

  describe "the puzzle" do
    test "the console cannot read the gate's state, and says where it can be", %{
      console: console,
      game: game
    } do
      {probed, _} = run(console, game, "probe gate")

      refute said(probed) =~ Lattice.gate_state(game.seed, game.depth)
      assert said(probed) =~ "walk into the gate"
    end

    test "the gate's log no longer says which state is the gate's", %{
      console: console,
      game: game
    } do
      state = Lattice.gate_state(game.seed, game.depth)
      {read, _} = run(console, game, "cat gate.log")

      refute said(read) =~ state
    end

    test "the manifest names every state, so reading it does not say which is the gate's", %{
      console: console,
      game: game
    } do
      state = Lattice.gate_state(game.seed, game.depth)
      {read, _} = run(console, game, "cat manifest")
      text = said(read)

      states = Regex.scan(~r/state=(\w+)/, text) |> Enum.map(&List.last/1) |> Enum.uniq()

      assert state in states
      assert length(states) > 3, "one state and no decoys would give it away"
    end

    test "the state, once carried here, leads to the code and the code opens the gate", %{
      console: console,
      game: game
    } do
      state = Lattice.gate_state(game.seed, game.depth)
      {found, game} = run(console, game, "grep #{state} manifest")

      code = Regex.run(~r/key=(\w+)/, said(found), capture: :all_but_first) |> hd()

      refute Lattice.unsealed?(game.seed, game.depth)
      {opened, _game} = run(found, game, "unseal #{code}")

      assert said(opened) =~ "accepted"
      assert Lattice.unsealed?(game.seed, game.depth)
    end

    test "a wrong code is rejected and leaves the gate shut", %{console: console, game: game} do
      {refused, _} = run(console, game, "unseal deadbeef")

      assert last(refused, 1) =~ "rejects"
      refute Lattice.unsealed?(game.seed, game.depth)
    end

    test "reading the seal does not give the code away", %{console: console, game: game, dir: dir} do
      seal = dir |> Path.join(".seal") |> File.read!() |> String.trim()

      {refused, _} = run(console, game, "unseal #{seal}")

      assert last(refused, 1) =~ "rejects"
      refute Lattice.unsealed?(game.seed, game.depth)
      refute seal == Lattice.code(game.seed, game.depth)
    end

    test "the manifest holds the code among decoys, so reading it is not solving it", %{
      console: console,
      game: game
    } do
      code = Lattice.code(game.seed, game.depth)
      {read, _} = run(console, game, "cat manifest")
      text = said(read)

      assert text =~ code
      keys = Regex.scan(~r/key=(\w+)/, text) |> Enum.map(&List.last/1) |> Enum.uniq()

      assert length(keys) > 3, "one record and no decoys is not a puzzle"
      assert code in keys
    end
  end

  describe "the forge" do
    test "lists everything with prices and what is in the wallet", %{console: console, game: game} do
      {listed, _} = run(console, game, "forge")
      text = said(listed)

      for weapon <- ~w(two_hand shield daggers mace power defence patch) do
        assert text =~ weapon
      end

      assert text =~ "200 shards"
    end

    test "buying takes the shards and gives the weapon", %{console: console, game: game} do
      {bought, after_buy} = run(console, game, "forge daggers")

      assert :daggers in after_buy.owned
      assert after_buy.shards == game.shards - Scriber.Gear.cost(:daggers)
      assert last(bought, 1) =~ "Fitted"
    end

    test "buying what you cannot afford changes nothing", %{console: console} do
      poor = %{Game.new(seed: 777) | shards: 3}
      {refused, unchanged} = run(console, poor, "forge mace")

      assert unchanged.shards == 3
      assert unchanged.owned == []
      assert last(refused, 1) =~ "You have 3"
    end

    test "selling returns half and takes the weapon back", %{console: console, game: game} do
      {console, game} = run(console, game, "forge mace")
      {sold, after_sell} = run(console, game, "forge sell mace")

      refute :mace in after_sell.owned
      assert after_sell.shards == game.shards + Scriber.Gear.resale(:mace)
      assert last(sold, 1) =~ "Sold"
    end

    test "patches add to what you carry", %{console: console, game: game} do
      {_console, after_buy} = run(console, game, "forge patch")

      assert after_buy.patches == game.patches + 1
    end

    test "an unknown thing is refused without spending", %{console: console, game: game} do
      {refused, unchanged} = run(console, game, "forge trebuchet")

      assert unchanged.shards == game.shards
      assert last(refused, 1) =~ "no trebuchet"
    end
  end

  describe "the console itself" do
    test "help lists what can be typed", %{console: console, game: game} do
      {helped, _} = run(console, game, "help")
      text = said(helped)

      for command <- ~w(ls cat grep probe unseal forge clear), do: assert(text =~ command)
    end

    test "an unknown command says so rather than failing", %{console: console, game: game} do
      {puzzled, _} = run(console, game, "sudo rm -rf /")

      assert last(puzzled, 1) =~ "not a command here"
    end

    test "clear empties the transcript", %{console: console, game: game} do
      {cleared, _} = run(console, game, "clear")

      assert Console.transcript(cleared) == []
    end
  end
end
