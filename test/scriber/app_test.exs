defmodule Scriber.AppTest do
  @moduledoc """
  `Scriber.App` as drafter runs it, headless.

  Assertions about what the player sees go through `shows?/2`, which polls the rendered
  screen text — the application paints some milliseconds after it handles a key, so a single
  read straight after `Drafter.Test.send_key/2` races the paint. Assertions about state go
  through `Drafter.Test.get_state/1` and need no polling.

  Tests that need no running application call `Scriber.App.render/1` or
  `Scriber.App.handle_event/2` directly with a hand-built state map.
  """

  use ExUnit.Case, async: false

  alias Cauldron2D.{Player, World}
  alias Drafter.Test, as: TUI
  alias Scriber.{Game, Lattice}

  setup do
    Application.put_env(:scriber, :mode, :text)
    Scriber.register_widgets()

    ctx =
      TUI.start_headless(Scriber.App, %{seed: 7, sink: TuningFork.Sink.Silent}, size: {120, 40})

    on_exit(fn ->
      TUI.stop(ctx)
      Lattice.destroy(7)
      Application.delete_env(:scriber, :mode)
    end)

    {:ok, ctx: ctx}
  end

  test "draws the stratum, the status panel and the log", %{ctx: ctx} do
    assert shows?(ctx, "SCRIBER")
    assert shows?(ctx, "stratum 1/#{Game.final_depth()}")
    assert shows?(ctx, "hp")
    assert shows?(ctx, "patches")
    assert shows?(ctx, "sealed")
    assert shows?(ctx, "The Lattice is failing around you.")
  end

  test "draws the map itself, not an empty pane", %{ctx: ctx} do
    assert shows?(ctx, "@")
  end

  test "a movement key advances the turn and redraws", %{ctx: ctx} do
    assert shows?(ctx, "turn 0")

    TUI.send_key(ctx, :l)
    TUI.send_key(ctx, :h)

    assert eventually(fn -> TUI.get_state(ctx).game.turn > 0 end)
    state = TUI.get_state(ctx)
    assert shows?(ctx, "turn #{state.game.turn}")
  end

  test "waiting spends a turn without moving", %{ctx: ctx} do
    before = TUI.get_state(ctx).game

    TUI.send_key(ctx, :.)

    assert eventually(fn -> TUI.get_state(ctx).game.turn == before.turn + 1 end)
    assert TUI.get_state(ctx).game.player.pos == before.player.pos
  end

  test "pressing enter away from a console says so rather than doing nothing", %{ctx: ctx} do
    TUI.send_key(ctx, :enter)

    refute TUI.get_state(ctx).console?
    assert shows?(ctx, "Nothing to use here.")
  end

  test "the diagonals move, so nothing can flank you that you cannot answer", %{ctx: ctx} do
    start = TUI.get_state(ctx).game.player.pos

    TUI.send_key(ctx, :e)

    assert eventually(fn -> TUI.get_state(ctx).game.turn > 0 end),
           "a diagonal key should spend a turn like any other move"

    after_one = TUI.get_state(ctx).game
    assert after_one.player.pos != start or after_one.messages != []
  end

  test "descending without an open gate is refused", %{ctx: ctx} do
    TUI.send_key(ctx, :>)

    assert shows?(ctx, "Nothing to descend here.")
    assert TUI.get_state(ctx).game.depth == 1
  end

  test "the gate opens when the marker appears, wherever it came from", %{ctx: ctx} do
    refute Game.unsealed?(TUI.get_state(ctx).game)

    File.write!(Path.join(Lattice.stratum_dir(7, 1), "unsealed"), "by hand\n")

    assert eventually(fn -> Game.unsealed?(TUI.get_state(ctx).game) end)
    assert shows?(ctx, "gate grinds open")
  end

  test "the run's files are on disk before the player can reach them", %{ctx: ctx} do
    game = TUI.get_state(ctx).game
    dir = Lattice.stratum_dir(game.seed, game.depth)

    assert File.exists?(Path.join(dir, "manifest"))
    assert File.exists?(Path.join(dir, "README"))
  end

  test "the run is a world of the player's own, stopped with the application", %{ctx: ctx} do
    world = TUI.get_state(ctx).world
    assert Process.alive?(world)
    assert World.snapshot(world).seed == 7
    TUI.stop(ctx)
    refute Process.alive?(world)
  end

  test "a forge purchase at the console reaches the world", %{ctx: ctx} do
    %{game: game, world: world} = TUI.get_state(ctx)
    console = Scriber.Console.new(Lattice.stratum_dir(7, 1), 1)
    rich = %{game | shards: 50}
    {console, _bought} = Scriber.Console.submit(%{console | input: "forge patch"}, rich)
    assert {[:buy_patch], _console} = Scriber.Console.take_pending(console)

    :ok = Player.input(world, :me, %{held: MapSet.new([:buy_patch]), aim: nil})
    assert eventually(fn -> TUI.get_state(ctx).game.messages |> hd() |> elem(0) =~ "shards" end)
  end

  describe "the console, from the application's side" do
    test "escape closes the console" do
      open = %{game: Game.new(seed: 7), console?: true, root: "/tmp/scriber-7"}

      assert {:ok, closed} = Scriber.App.handle_event({:key, :escape}, open)
      refute closed.console?
    end

    test "escape carrying modifiers closes it too" do
      open = %{game: Game.new(seed: 7), console?: true, root: "/tmp/scriber-7"}

      assert {:ok, closed} = Scriber.App.handle_event({:key, :escape, []}, open)
      refute closed.console?
    end

    test "keys type at the prompt rather than moving or quitting" do
      game = Game.new(seed: 7)

      open = %{
        game: game,
        console?: true,
        console: Scriber.Console.new("/tmp/scriber-7", 1),
        root: "/tmp/scriber-7"
      }

      {:ok, typed} = Scriber.App.handle_event({:key, :l}, open)
      {:ok, typed} = Scriber.App.handle_event({:key, :q}, typed)

      assert typed.console.input == "lq"
      assert typed.game.player.pos == game.player.pos
      assert typed.game.turn == game.turn
    end

    test "escape with no console open does not quit or move" do
      shut = %{game: Game.new(seed: 7), console?: false, root: "/tmp/scriber-7"}

      assert {:noreply, ^shut} = Scriber.App.handle_event({:key, :escape}, shut)
    end
  end

  describe "a finished run" do
    test "replaces the map with an epitaph and how to start again" do
      dead = %{Game.new(seed: 7) | status: :dead, turn: 88, shards: 13}
      text = rendered_text(%{game: dead, console?: false, root: "/tmp/scriber-7"})

      assert text =~ "absorbed"
      assert text =~ "turns     88"
      assert text =~ "shards    13"
      assert text =~ "seed      7"
      assert text =~ "[r] begin another run"
      refute text =~ "descend"
    end

    test "says so differently when the player got out" do
      escaped = %{Game.new(seed: 7) | status: :escaped}
      text = rendered_text(%{game: escaped, console?: false, root: "/tmp/scriber-7"})

      assert text =~ "You are out of the Lattice."
    end
  end

  describe "what the footer offers" do
    defp footer(game) do
      %{game: game, console?: false, console: nil, root: "/tmp/scriber-7"}
      |> Scriber.App.render()
      |> find_footer()
      |> Enum.map_join(" ", fn {key, what} -> "#{key} #{what}" end)
    end

    defp find_footer({:footer, opts}) when is_list(opts), do: Keyword.fetch!(opts, :bindings)
    defp find_footer({:layout, _direction, children, _opts}), do: find_footer(children)
    defp find_footer(list) when is_list(list), do: Enum.find_value(list, &find_footer/1)
    defp find_footer(_other), do: nil

    defp standing_on(game, tile) do
      spot = Enum.find_value(game.level.tiles, fn {at, kind} -> if kind == tile, do: at end)
      %{game | player: %{game.player | pos: spot}}
    end

    test "descend is offered only on a stair" do
      game = Game.new(seed: 21)

      refute footer(game) =~ "descend"
      assert game |> Game.unseal() |> standing_on(:stair) |> footer() =~ "descend"
    end

    test "the console is offered only on a console" do
      game = Game.new(seed: 21)

      refute footer(game) =~ "console"
      assert game |> standing_on(:console) |> footer() =~ "console"
    end

    test "patching is offered only while you carry one" do
      game = Game.new(seed: 21)

      assert footer(%{game | patches: 2}) =~ "patch"
      refute footer(%{game | patches: 0}) =~ "patch"
    end

    test "weapons are offered only once you own some, and not with something adjacent" do
      game = Game.new(seed: 21)
      refute footer(game) =~ "weapon"

      armed = %{game | owned: [:mace]}
      assert footer(armed) =~ "weapon"

      {x, y} = armed.player.pos
      beside = %{Scriber.Entity.spawn(:husk, 90, {x + 1, y}, 1) | awake?: true}
      refute footer(%{armed | entities: [beside]}) =~ "weapon"
    end

    test "moving and quitting are always offered" do
      for game <- [Game.new(seed: 21), %{Game.new(seed: 3) | patches: 0}] do
        assert footer(game) =~ "move"
        assert footer(game) =~ "quit"
      end
    end

    test "the diagonal keys are advertised, because daemons use the diagonal" do
      assert footer(Game.new(seed: 21)) =~ "qezc"
    end
  end

  defp rendered_text(state) do
    state |> Scriber.App.render() |> flatten() |> Enum.join("\n")
  end

  defp flatten(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> flatten()
  defp flatten(list) when is_list(list), do: Enum.flat_map(list, &flatten/1)
  defp flatten(binary) when is_binary(binary), do: [binary]
  defp flatten({key, value}) when is_atom(key), do: flatten(value)
  defp flatten(_other), do: []

  defp shows?(ctx, text), do: eventually(fn -> TUI.screen_text(ctx) =~ text end)

  defp eventually(check, attempts \\ 40) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if check.() do
        {:halt, true}
      else
        Process.sleep(25)
        {:cont, false}
      end
    end)
  end
end
