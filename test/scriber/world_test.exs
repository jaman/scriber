defmodule Scriber.WorldTest do
  use ExUnit.Case, async: true

  alias Cauldron2D.Test, as: World
  alias Scriber.{Forge, Game, Level}

  defp driver do
    {:ok, driver} = Game |> World.new(game_opts: [seed: 7], hz: 1) |> World.join(:me, %{})
    driver
  end

  defp standing_on(driver, tile) do
    game = World.state(driver)
    spot = Enum.find_value(game.level.tiles, fn {at, kind} -> if kind == tile, do: at end)
    %{driver | state: %{game | player: %{game.player | pos: spot}}}
  end

  test "every action stands for a command, is handled by the game, or is the forge's" do
    for action <- Game.actions() do
      assert Game.command_for(action) != nil or action in [:use, :unseal] or
               action in Forge.actions()
    end

    assert Game.command_for(:move_ne) == {:move, 1, -1}
    assert Game.command_for(:equip_0) == {:equip, :unarmed}
    assert Game.command_for(:equip_4) == {:equip, :mace}
  end

  test "a pressed action is one command on the next step and no more" do
    driver = driver() |> World.hold(:me, [:wait]) |> World.tick(1)
    assert World.view(driver, :me).turn == 1

    driver = World.tick(driver, 3)
    assert World.view(driver, :me).turn == 1

    driver =
      driver |> World.hold(:me, []) |> World.tick(1) |> World.hold(:me, [:wait]) |> World.tick(1)

    assert World.view(driver, :me).turn == 2
  end

  test "use descends on a stair once the gate is unsealed, and says so elsewhere" do
    driver = driver() |> World.hold(:me, [:use]) |> World.tick(1)
    assert {"Nothing to use here.", :warning} = hd(World.view(driver, :me).messages)

    driver = driver |> World.hold(:me, [:unseal]) |> World.tick(1)
    assert Game.unsealed?(World.view(driver, :me))
    assert :unsealed in World.events(driver)

    driver =
      driver
      |> standing_on(:stair)
      |> World.hold(:me, [])
      |> World.tick(1)
      |> World.hold(:me, [:use])
      |> World.tick(1)

    assert World.view(driver, :me).depth == 2
    assert {:descended, 2} in World.events(driver)
  end

  test "a forge action buys or sells, and a refused one costs nothing but a message" do
    driver = driver()
    poor = World.view(driver, :me)
    driver = driver |> World.hold(:me, [:buy_patch]) |> World.tick(1)
    assert World.view(driver, :me).patches == poor.patches
    assert {_why, :warning} = hd(World.view(driver, :me).messages)

    rich = %{driver | state: %{World.state(driver) | shards: 50}}

    driver =
      rich
      |> World.hold(:me, [])
      |> World.tick(1)
      |> World.hold(:me, [:buy_patch])
      |> World.tick(1)

    assert World.view(driver, :me).patches == poor.patches + 1
    assert World.view(driver, :me).shards < 50
  end

  test "only the first player to join acts; the level stays transparent where the engine's field of view says so" do
    {:ok, driver} = World.join(driver(), :other, %{})
    driver = driver |> World.hold(:other, [:wait]) |> World.tick(1)
    assert World.view(driver, :other).turn == 0

    game = World.view(driver, :me)
    assert MapSet.member?(game.visible, game.player.pos)
    assert Level.transparent?(game.level, game.player.pos)
  end
end
