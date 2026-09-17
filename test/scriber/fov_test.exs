defmodule Scriber.FovTest do
  @moduledoc """
  `Cauldron2D.Grid.Fov.compute/3`, through `Scriber.Level.transparent?/2`, against hand-drawn maps.

  A map is a list of equal-length row strings: `.` is floor, `#` is wall, and `@` marks the
  observer's tile, which is also floor. `see/2` builds the level, finds the `@`, and returns
  the visible set.
  """

  use ExUnit.Case, async: true

  alias Cauldron2D.Grid.Fov
  alias Scriber.Level

  defp level(rows) do
    tiles =
      for {row, y} <- Enum.with_index(rows),
          {char, x} <- Enum.with_index(String.graphemes(row)),
          into: %{} do
        {{x, y}, if(char == "#", do: :wall, else: :floor)}
      end

    %Level{
      width: rows |> hd() |> String.length(),
      height: length(rows),
      tiles: tiles,
      depth: 1,
      spawn: {0, 0}
    }
  end

  defp origin(rows) do
    for {row, y} <- Enum.with_index(rows),
        {"@", x} <- Enum.with_index(String.graphemes(row)),
        do: {x, y}
  end

  defp see(rows, radius \\ 10) do
    level = level(rows)
    [origin] = origin(rows)
    Fov.compute(&Level.transparent?(level, &1), origin, radius)
  end

  test "an observer always sees its own tile" do
    visible = see(["@"])

    assert MapSet.member?(visible, {0, 0})
  end

  test "an open room is visible to its corners" do
    visible =
      see([
        ".....",
        ".....",
        "..@..",
        ".....",
        "....."
      ])

    for x <- 0..4, y <- 0..4 do
      assert MapSet.member?(visible, {x, y}), "expected #{inspect({x, y})} to be visible"
    end
  end

  test "the walls around a room are lit, not just its floor" do
    visible =
      see([
        "#####",
        "#...#",
        "#.@.#",
        "#...#",
        "#####"
      ])

    assert MapSet.member?(visible, {0, 0})
    assert MapSet.member?(visible, {2, 0})
    assert MapSet.member?(visible, {4, 4})
  end

  test "a pillar casts a shadow directly behind itself" do
    visible =
      see([
        ".......",
        ".......",
        "@.#....",
        ".......",
        "......."
      ])

    assert MapSet.member?(visible, {2, 2}), "the pillar itself is seen"
    refute MapSet.member?(visible, {3, 2}), "the tile behind it is not"
    refute MapSet.member?(visible, {6, 2}), "nor anything further along that line"
    assert MapSet.member?(visible, {6, 0}), "but the rest of the room is"
  end

  test "a wall with a gap lets light through the gap only" do
    visible =
      see([
        "..#..",
        "..#..",
        "@.#..",
        ".....",
        "..#.."
      ])

    refute MapSet.member?(visible, {4, 0})
    assert MapSet.member?(visible, {4, 3}), "through the gap in the wall"
  end

  test "nothing beyond the radius is visible" do
    room = List.duplicate(String.duplicate(".", 21), 21)
    rows = List.update_at(room, 10, fn row -> String.replace(row, ~r/^(.{10})./, "\\1@") end)

    visible = see(rows, 4)

    assert MapSet.member?(visible, {13, 10})
    refute MapSet.member?(visible, {15, 10})
    assert Enum.all?(visible, fn {x, y} -> (x - 10) ** 2 + (y - 10) ** 2 <= 16 end)
  end

  test "sight is mutual: what the player can see can see the player" do
    rows = [
      "#########",
      "#...#...#",
      "#.@.#...#",
      "#...#...#",
      "#...#####",
      "#.......#",
      "#########"
    ]

    level = level(rows)
    [player] = origin(rows)
    visible = Fov.compute(&Level.transparent?(level, &1), player, 10)

    for spot <- visible, Level.walkable?(level, spot) do
      assert MapSet.member?(Fov.compute(&Level.transparent?(level, &1), spot, 10), player),
             "#{inspect(spot)} is visible from #{inspect(player)} but cannot see back"
    end
  end
end
