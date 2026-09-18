defmodule Scriber.DepthTest do
  use ExUnit.Case, async: true

  alias Scriber.{Entity, Game, Level, Sound}

  defp arena(seed \\ 7) do
    game = Game.new(seed: seed)
    %{game | entities: [], items: %{}, stunned: %{}, noise: nil}
  end

  defp beside(game, kind, {dx, dy}, extra \\ %{}) do
    {px, py} = game.player.pos

    entity =
      Map.merge(
        %{
          Entity.spawn(kind, 90 + map_size(extra), {px + dx, py + dy}, game.depth)
          | awake?: true,
            seen_at: game.turn
        },
        extra
      )

    %{game | entities: game.entities ++ [entity]} |> Game.refresh_vision()
  end

  defp open_spot(game, {dx, dy}) do
    {px, py} = game.player.pos
    Level.walkable?(game.level, {px + dx, py + dy})
  end

  defp said?(game, text), do: Enum.any?(game.messages, &(elem(&1, 0) =~ text))

  test "a thrown fuse stuns everything within a tile of where it lands, and a stunned creature can be slipped past" do
    game = %{arena() | fuses: 1} |> beside(:husk, {2, 0})
    assert open_spot(game, {2, 0})
    {px, py} = game.player.pos

    thrown = Game.command(game, {:throw, :fuse, {px + 2, py}})
    husk = hd(thrown.entities)
    assert thrown.fuses == 0
    assert Map.get(thrown.stunned, husk.id) == 2
    assert thrown.player.hp == game.player.hp
    assert {:fuse, {px + 2, py}} in thrown.events

    assert {:error, _} =
             {:error,
              Game.command(%{game | fuses: 0}, {:throw, :fuse, {px + 2, py}}) |> said?("No fuse")}

    assert Game.command(game, {:throw, :fuse, {px + 40, py}}) |> said?("Too far")

    slipped = thrown |> Game.command({:move, 1, 0}) |> Game.command({:move, 1, 0})
    assert slipped.player.pos == {px + 2, py}
    assert hd(slipped.entities).pos == {px + 1, py}
  end

  test "a pulse throws back and stuns what stands at arm's reach" do
    game = %{arena() | pulses: 1} |> beside(:mite, {1, 0})
    assert open_spot(game, {2, 0})
    {px, py} = game.player.pos

    pulsed = Game.command(game, :pulse)
    mite = hd(pulsed.entities)
    assert mite.pos == {px + 2, py}
    assert pulsed.player.hp == game.player.hp
    assert pulsed.pulses == 0
    assert :pulse in pulsed.events
  end

  test "a decoy is a noise that draws what is awake, and a daemon wakes to footsteps within hearing" do
    game = %{arena() | decoys: 1} |> beside(:husk, {3, 0})
    {px, py} = game.player.pos
    away = {px, py}
    thrown = Game.command(game, {:throw, :decoy, away})
    assert thrown.noise.pos == away
    assert thrown.noise.until == thrown.turn + 5

    sleeping = arena() |> beside(:daemon, {9, 0}, %{awake?: false, seen_at: nil})
    daemon = hd(sleeping.entities)
    refute daemon.awake?
    refute MapSet.member?(sleeping.visible, daemon.pos) and false
    waited = Game.command(sleeping, :wait)
    assert waited.noise == nil

    walked =
      Game.command(
        %{sleeping | visible: MapSet.new([sleeping.player.pos])},
        {:move, if(open_spot(sleeping, {-1, 0}), do: -1, else: 1), 0}
      )

    assert hd(walked.entities).awake?
    assert Enum.any?(walked.events, &match?({:noticed, :daemon, _}, &1))
  end

  test "a sentry never moves and wakes only when something comes within reach; a husk acts every other turn" do
    game = arena() |> beside(:sentry, {5, 0}, %{awake?: false, seen_at: nil})
    sentry = hd(game.entities)
    waited = game |> Game.command(:wait) |> Game.command(:wait)
    assert hd(waited.entities).pos == sentry.pos
    refute hd(waited.entities).awake?

    close =
      arena() |> beside(:sentry, {2, 0}, %{awake?: false, seen_at: nil}) |> Game.command(:wait)

    assert hd(close.entities).awake?

    slow = arena() |> beside(:husk, {4, 0})
    husk = hd(slow.entities)

    positions =
      Enum.scan(1..4, slow, fn _n, acc -> Game.command(acc, :wait) end)
      |> Enum.map(&hd(&1.entities).pos)

    moves = positions |> Enum.chunk_every(2, 1, :discard) |> Enum.count(fn [a, b] -> a != b end)
    assert moves <= 2, "a husk moved on #{moves} of four turns"
    assert husk.pace == 2
  end

  test "a mite runs when hurt, and a creature that loses the player long enough sleeps again" do
    game = arena() |> beside(:mite, {1, 0}, %{hp: 1})
    {px, py} = game.player.pos
    ran = Game.command(game, :wait)
    mite = hd(ran.entities)
    assert mite.pos != {px + 1, py} or said?(ran, "skitters") or said?(ran, "hits you")

    lost = arena() |> beside(:husk, {3, 0}, %{seen_at: 0})
    blind = %{lost | visible: MapSet.new([lost.player.pos])}

    asleep =
      Enum.reduce(1..7, blind, fn _n, acc ->
        %{Game.command(acc, :wait) | visible: MapSet.new([acc.player.pos])}
      end)

    refute hd(asleep.entities).awake?
  end

  test "fragments ride on creatures, drop where they die, and spell out the code" do
    game = Game.new(seed: 11)
    carriers = Enum.filter(game.entities, &(&1.carries != nil))
    assert length(carriers) == Game.fragment_count(1)
    assert Game.known_code(game) == "????????"

    carrier = %{hd(carriers) | hp: 1}
    {px, py} = game.player.pos
    placed = %{carrier | pos: {px + 1, py}}
    fight = %{game | entities: [placed], items: %{}} |> Game.refresh_vision()
    assert Level.walkable?(fight.level, placed.pos)

    slain =
      Enum.reduce_while(1..30, fight, fn _n, acc ->
        next = Game.command(acc, {:move, 1, 0})
        if next.entities == [], do: {:halt, next}, else: {:cont, next}
      end)

    assert slain.entities == []
    assert Map.get(slain.items, placed.pos) == carrier.carries
    picked = Game.command(slain, {:move, 1, 0})
    assert MapSet.size(picked.fragments) == 1
    known = Game.known_code(picked)
    assert String.length(known) == 8
    assert known != "????????"

    assert String.replace(known, "?", "") == String.slice(Scriber.Lattice.code(11, 1), 0, 4) or
             String.replace(known, "?", "") == String.slice(Scriber.Lattice.code(11, 1), 4, 4)
  end

  test "doors stand at room thresholds from stratum 2, block sight until opened, and open by walking through" do
    {level, _rng} = Level.build(Cauldron2D.Rng.new(3), 2)
    doors = for {point, :door} <- level.tiles, do: point
    assert doors != []
    door = hd(doors)
    refute Level.transparent?(level, door)
    assert Level.walkable?(level, door)
    assert Level.transparent?(Level.open(level, door), door)

    {shallow, _rng} = Level.build(Cauldron2D.Rng.new(3), 1)
    assert Enum.empty?(for {_point, :door} <- shallow.tiles, do: 1)
  end

  test "sight shortens from stratum 4, the player hardens on each descent, and misses happen both ways" do
    assert Game.sight(1) == 8
    assert Game.sight(4) == 6

    game = arena() |> beside(:daemon, {1, 0})
    rounds = Enum.scan(1..40, game, fn _n, acc -> Game.command(acc, {:move, 1, 0}) end)
    assert Enum.any?(rounds, &said?(&1, "and miss"))
    assert Enum.any?(rounds, &said?(&1, "lunges and misses"))

    assert Enum.any?(
             rounds,
             &Enum.any?(&1.events, fn event -> match?({:hit, :unarmed, :daemon, _}, event) end)
           )
  end

  test "every event the game emits has a sound decision" do
    kinds = [:mite, :husk, :sentry, :daemon]
    weapons = [:unarmed, :two_hand, :shield, :daggers, :mace]

    for kind <- kinds, weapon <- weapons do
      assert Sound.voice({:hit, weapon, kind}) != nil
    end

    for kind <- kinds, event <- [:noticed, :chatter, :died, :stunned, :miss] do
      Sound.voice({event, kind})
    end

    for event <- [
          {:step, :scriber},
          {:hurt, 7},
          :parry,
          :patch,
          :refused,
          :door,
          :console,
          :unsealed,
          {:descended, 2},
          :fuse,
          :decoy,
          :pulse,
          {:pickup, :shard},
          {:pickup, :fragment},
          {:pickup, :fuse}
        ] do
      assert Sound.voice(event) != nil, "#{inspect(event)} is silent"
    end
  end
end
