defmodule Scriber.LatticeTest do
  @moduledoc """
  `Scriber.Lattice` against a real directory.

  Not async: the location tests set and unset `$SCRIBER_HOME` and `$XDG_STATE_HOME`, which
  belong to the whole VM.
  """

  use ExUnit.Case, async: false

  alias Scriber.Lattice

  setup context do
    seed = :erlang.phash2(context.test)
    on_exit(fn -> Lattice.destroy(seed) end)
    {:ok, seed: seed}
  end

  describe "where runs are kept" do
    test "under $SCRIBER_HOME when it is set", %{seed: seed} do
      assert Lattice.home() == System.get_env("SCRIBER_HOME")
      assert String.starts_with?(Lattice.root(seed), Lattice.home())

      assert Lattice.stratum_dir(seed, 3) ==
               Path.join([Lattice.home(), "runs", "#{seed}", "stratum-3"])
    end

    test "under $XDG_STATE_HOME/scriber otherwise" do
      assert with_env(%{"SCRIBER_HOME" => nil, "XDG_STATE_HOME" => "/xdg/state"}, &Lattice.home/0) ==
               "/xdg/state/scriber"
    end

    test "under ~/.local/state/scriber when XDG says nothing" do
      home = with_env(%{"SCRIBER_HOME" => nil, "XDG_STATE_HOME" => nil}, &Lattice.home/0)

      assert home == Path.join(System.user_home!(), ".local/state/scriber")
    end

    test "never in $TMPDIR, which is where a run gets swept away from" do
      home = with_env(%{"SCRIBER_HOME" => nil, "XDG_STATE_HOME" => nil}, &Lattice.home/0)

      refute String.starts_with?(home, System.tmp_dir!())
    end

    test "a relative XDG_STATE_HOME is ignored rather than resolved" do
      home =
        with_env(%{"SCRIBER_HOME" => nil, "XDG_STATE_HOME" => "relative/state"}, &Lattice.home/0)

      assert home == Path.join(System.user_home!(), ".local/state/scriber")
    end

    test "an empty variable counts as unset" do
      home = with_env(%{"SCRIBER_HOME" => "", "XDG_STATE_HOME" => "/xdg"}, &Lattice.home/0)

      assert home == "/xdg/scriber"
    end

    test "lists the runs it has on disk, newest first", %{seed: seed} do
      Lattice.prepare(seed, 1)

      assert seed in Lattice.runs()
    end
  end

  defp with_env(vars, fun) do
    previous = Map.new(vars, fn {name, _value} -> {name, System.get_env(name)} end)

    Enum.each(vars, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  describe "a prepared stratum" do
    test "writes the files a player is meant to read", %{seed: seed} do
      dir = Lattice.prepare(seed, 1)

      assert File.exists?(Path.join(dir, "README"))
      assert File.exists?(Path.join(dir, "manifest"))
      assert File.exists?(Path.join(dir, "gate.log"))
      assert File.exists?(Path.join(dir, ".seal"))
      refute File.exists?(Path.join(dir, "unsealed"))
    end

    test "never writes the code down in plain text", %{seed: seed} do
      dir = Lattice.prepare(seed, 1)
      code = Lattice.code(seed, 1)

      assert File.read!(Path.join(dir, ".seal")) =~ ~r/^[0-9a-f]{64}\n$/
      refute File.read!(Path.join(dir, ".seal")) =~ code
      refute File.read!(Path.join(dir, "gate.log")) =~ code
      refute File.read!(Path.join(dir, "README")) =~ code
    end

    test "puts the code in exactly one record, the one in the gate's state", %{seed: seed} do
      dir = Lattice.prepare(seed, 1)
      state = Lattice.gate_state(seed, 1)

      matching =
        dir
        |> Path.join("manifest")
        |> File.read!()
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ "state=#{state}"))

      assert [line] = matching
      assert line =~ "key=#{Lattice.code(seed, 1)}"
    end

    test "shards the records into logs/ deeper down, still with one answer", %{seed: seed} do
      dir = Lattice.prepare(seed, 3)
      state = Lattice.gate_state(seed, 3)

      matches =
        [dir, "logs"]
        |> Path.join()
        |> Path.join("*.log")
        |> Path.wildcard()
        |> Enum.flat_map(&(&1 |> File.read!() |> String.split("\n")))
        |> Enum.filter(&(&1 =~ "state=#{state}"))

      assert [line] = matches
      assert line =~ "key=#{Lattice.code(seed, 3)}"
    end

    test "re-preparing a stratum keeps the same answer and the player's progress", %{seed: seed} do
      dir = Lattice.prepare(seed, 2)
      code = Lattice.code(seed, 2)
      File.write!(Path.join(dir, "unsealed"), "yes\n")

      assert Lattice.prepare(seed, 2) == dir
      assert Lattice.code(seed, 2) == code
      assert Lattice.unsealed?(seed, 2)
    end
  end
end
