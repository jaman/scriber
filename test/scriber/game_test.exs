defmodule Scriber.GameTest do
  use ExUnit.Case, async: true

  alias Scriber.{Entity, Game, Level}

  describe "a new run" do
    test "is fully determined by its seed" do
      a = Game.new(seed: 99)
      b = Game.new(seed: 99)

      assert a.level.tiles == b.level.tiles
      assert Enum.map(a.entities, & &1.pos) == Enum.map(b.entities, & &1.pos)
      assert a.items == b.items
    end

    test "different seeds produce different maps" do
      assert Game.new(seed: 1).level.tiles != Game.new(seed: 2).level.tiles
    end

    test "puts the player somewhere walkable, with a console and a sealed gate" do
      game = Game.new(seed: 7)

      assert Level.walkable?(game.level, game.player.pos)
      assert Level.at(game.level, game.level.console) == :console
      assert Level.at(game.level, game.level.gate) == :gate
      refute Game.unsealed?(game)
    end

    test "sees its own tile and nothing it has not looked at" do
      game = Game.new(seed: 7)

      assert MapSet.member?(game.visible, game.player.pos)
      assert MapSet.subset?(game.visible, game.seen)
      refute MapSet.member?(game.visible, {0, 0})
    end
  end

  describe "movement" do
    test "walking onto floor moves the player and spends a turn" do
      game = Game.new(seed: 7)
      {from, to} = open_step(game)
      game = %{game | player: %{game.player | pos: from}}

      moved = Game.command(game, step_between(from, to))

      assert moved.player.pos == to
      assert moved.turn == game.turn + 1
    end

    test "walking into rock is refused and costs no turn" do
      game = Game.new(seed: 7)
      blocked = Game.command(%{game | player: %{game.player | pos: {0, 0}}}, {:move, -1, 0})

      assert blocked.player.pos == {0, 0}
      assert blocked.turn == game.turn
      assert {"Solid.", :warning} = hd(blocked.messages)
    end

    test "a sealed gate is solid, and reports its state to whoever walks into it" do
      game = Game.new(seed: 7)
      {gx, gy} = game.level.gate
      beside = beside_gate(game, {gx, gy})
      game = %{game | player: %{game.player | pos: beside}}

      blocked = Game.command(game, step_between(beside, {gx, gy}))
      said = Enum.map_join(blocked.messages, "\n", &elem(&1, 0))

      assert blocked.player.pos == beside, "a sealed gate is still not walked through"
      assert said =~ "sealed"
      assert said =~ Scriber.Lattice.gate_state(game.seed, game.depth)
    end

    test "an unsealed gate becomes a stair the player can stand on" do
      game = Game.new(seed: 7) |> Game.unseal()
      {gx, gy} = game.level.gate
      beside = beside_gate(game, {gx, gy})
      game = %{game | player: %{game.player | pos: beside}}

      moved = Game.command(game, step_between(beside, {gx, gy}))

      assert moved.player.pos == {gx, gy}
      assert Level.at(moved.level, {gx, gy}) == :stair
    end
  end

  describe "combat" do
    test "bumping a daemon damages it instead of moving into it" do
      game = seeded_with_neighbour()
      target = hd(game.entities)
      {px, py} = game.player.pos
      {tx, ty} = target.pos

      fought = Game.command(game, {:move, tx - px, ty - py})

      assert fought.player.pos == {px, py}
      assert hd(fought.entities).hp < target.hp
    end

    test "a kill removes the entity and pays out its shards" do
      game = seeded_with_neighbour()
      target = %{hd(game.entities) | hp: 1}
      game = %{game | entities: [target]}
      {px, py} = game.player.pos
      {tx, ty} = target.pos

      fought = Game.command(game, {:move, tx - px, ty - py})

      assert fought.entities == []
      assert fought.shards == game.shards + target.shards
    end

    test "a player reduced to zero ends the run" do
      game = Game.new(seed: 7)
      dying = %{game | player: %{game.player | hp: 0}}

      assert Game.command(dying, :wait).status == :dead
    end

    test "commands after death do nothing" do
      dead = %{Game.new(seed: 7) | status: :dead}

      assert Game.command(dead, {:move, 1, 0}) == dead
    end
  end

  describe "items" do
    test "walking over a patch carries it, and applying one heals" do
      game = Game.new(seed: 7)
      {from, to} = open_step(game)

      game = %{
        game
        | player: %{game.player | pos: from, hp: 10},
          items: Map.put(game.items, to, :patch),
          patches: 0
      }

      picked = Game.command(game, step_between(from, to))
      assert picked.patches == 1

      healed = Game.command(picked, :apply_patch)
      assert healed.player.hp > 10
      assert healed.patches == 0
    end

    test "applying a patch you do not have is refused" do
      game = %{Game.new(seed: 7) | patches: 0}
      refused = Game.command(game, :apply_patch)

      assert refused.turn == game.turn
      assert {"No patches left.", :warning} = hd(refused.messages)
    end
  end

  describe "descending" do
    test "needs an open gate underfoot" do
      game = Game.new(seed: 7)
      refused = Game.command(game, :descend)

      assert refused.depth == 1
      assert {"Nothing to descend here.", :warning} = hd(refused.messages)
    end

    test "generates the next stratum and keeps the player's condition" do
      game = Game.new(seed: 7) |> Game.unseal()
      game = %{game | player: %{game.player | pos: game.level.gate, hp: 12, power: 9}}

      deeper = Game.command(game, :descend)

      assert deeper.depth == 2
      assert deeper.player.hp == 12
      assert deeper.player.power == 9
      refute Game.unsealed?(deeper)
      assert deeper.level.tiles != game.level.tiles
    end

    test "descending from the last stratum ends the run" do
      game = Game.new(seed: 7)
      game = %{game | depth: Game.final_depth()} |> Game.unseal()
      game = %{game | player: %{game.player | pos: game.level.gate}}

      assert Game.command(game, :descend).status == :escaped
    end

    test "a new stratum is unexplored, however much of the last one was walked" do
      walked =
        Enum.reduce(1..40, Game.new(seed: 3), fn _turn, game ->
          Enum.reduce(
            [{:move, 1, 0}, {:move, 0, 1}, {:move, -1, 0}, {:move, 0, -1}],
            game,
            &Game.command(&2, &1)
          )
        end)

      deeper = Game.enter_stratum(walked, 2)

      assert MapSet.equal?(deeper.seen, deeper.visible)
      assert MapSet.size(deeper.seen) < MapSet.size(walked.seen) + MapSet.size(deeper.visible)
    end
  end

  describe "what a stratum is given to survive itself" do
    test "every stratum carries at least the promised patches" do
      for depth <- [1, 2, 3, 5, 8], seed <- 1..40 do
        game = Game.new(seed: seed * 31) |> Game.enter_stratum(depth)
        patches = game.items |> Map.values() |> Enum.count(&(&1 == :patch))

        assert patches >= Game.patch_floor(depth),
               "stratum #{depth} seed #{seed} carried #{patches} patches"
      end
    end

    test "no stratum is ever without healing" do
      for depth <- 1..8, seed <- 1..30 do
        game = Game.new(seed: seed * 17) |> Game.enter_stratum(depth)

        assert game.items |> Map.values() |> Enum.any?(&(&1 == :patch)),
               "stratum #{depth} seed #{seed} had no patch anywhere"
      end
    end

    test "the promised patches are spread about rather than piled by the door" do
      game = Game.new(seed: 5) |> Game.enter_stratum(6)

      spots = for {spot, :patch} <- game.items, do: spot
      spread = spots |> Enum.map(fn {x, y} -> x + y end) |> Enum.uniq() |> length()

      assert spread > 1, "every patch landed in the same place"
    end

    test "deeper strata carry more of everything" do
      assert Game.item_count(8) > Game.item_count(1)
      assert Game.patch_floor(8) > Game.patch_floor(1)
    end
  end

  describe "daemons" do
    test "act on a turn once they have been seen" do
      game = seeded_with_neighbour()
      before = hd(game.entities)

      after_turn = Game.command(game, :wait)

      assert hd(after_turn.entities).awake?
      assert after_turn.player.hp < game.player.hp or hd(after_turn.entities).pos != before.pos
    end

    test "stay asleep while out of sight" do
      game = Game.new(seed: 7)

      hidden_ids =
        game.entities
        |> Enum.reject(&MapSet.member?(game.visible, &1.pos))
        |> Enum.map(& &1.id)

      after_turn = Game.command(game, :wait)
      still_asleep = Enum.filter(after_turn.entities, &(&1.id in hidden_ids))

      assert Enum.all?(still_asleep, &(not &1.awake?))
    end
  end

  test "a long random run never crashes and always ends somewhere valid" do
    commands = [{:move, 1, 0}, {:move, -1, 0}, {:move, 0, 1}, {:move, 0, -1}, :wait, :apply_patch]

    final =
      Enum.reduce(1..500, Game.new(seed: 31), fn index, game ->
        Game.command(game, Enum.at(commands, rem(index * 7, length(commands))))
      end)

    assert final.status in [:playing, :dead, :escaped]
    assert Level.walkable?(final.level, final.player.pos)
    assert final.player.hp >= 0
  end

  defp open_step(game) do
    from = game.player.pos

    to =
      [{1, 0}, {-1, 0}, {0, 1}, {0, -1}]
      |> Enum.map(fn {dx, dy} -> {elem(from, 0) + dx, elem(from, 1) + dy} end)
      |> Enum.find(&Level.walkable?(game.level, &1))

    {from, to}
  end

  defp step_between({fx, fy}, {tx, ty}), do: {:move, tx - fx, ty - fy}

  defp beside_gate(game, {gx, gy}) do
    [{1, 0}, {-1, 0}, {0, 1}, {0, -1}]
    |> Enum.map(fn {dx, dy} -> {gx + dx, gy + dy} end)
    |> Enum.find(&Level.walkable?(game.level, &1))
  end

  defp seeded_with_neighbour do
    game = Game.new(seed: 7)
    {from, to} = open_step(game)
    monster = Entity.spawn(:sentry, 1, to, 1)

    %{game | player: %{game.player | pos: from}, entities: [monster]}
    |> Game.refresh_vision()
  end
end
