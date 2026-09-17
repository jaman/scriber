defmodule Scriber.GearTest do
  @moduledoc """
  Weapons, the forge, and probes.

  The weapon tests measure outcomes rather than formulas: `duel/3` plays a fight to the death
  in an empty room against a single awake foe and returns how many turns it took, and
  `median/2` is the median over 40 seeds. Fewer turns is a better weapon.
  """

  use ExUnit.Case, async: true

  alias Cauldron2D.Rng
  alias Scriber.{Entity, Forge, Game, Gear, Level}

  defp duel(weapon, kind, seed) do
    level = %Level{tiles: %{}, spawn: {5, 5}, gate: {0, 0}, console: {0, 0}, unsealed?: false}
    foe = %{Entity.spawn(kind, 1, {6, 5}, 5) | awake?: true}

    game = %Game{
      rng: Rng.new(seed),
      seed: seed,
      status: :playing,
      weapon: weapon,
      owned: [weapon],
      player: %{Entity.scriber({5, 5}) | hp: 999, max_hp: 999},
      entities: [foe],
      level: level,
      visible: MapSet.new([{6, 5}]),
      seen: MapSet.new()
    }

    Enum.reduce_while(1..200, {game, 0}, fn _turn, {acc, turns} ->
      played = Game.command(acc, {:move, 1, 0})
      if played.entities == [], do: {:halt, turns + 1}, else: {:cont, {played, turns + 1}}
    end)
  end

  defp median(weapon, kind) do
    turns = for seed <- 1..40, do: duel(weapon, kind, seed * 7)
    turns |> Enum.sort() |> Enum.at(20)
  end

  describe "what each weapon is for" do
    test "anything bought beats bare hands against everything" do
      for weapon <- Gear.purchasable(), kind <- [:mite, :husk, :sentry, :daemon] do
        assert median(weapon, kind) <= median(:unarmed, kind),
               "#{weapon} is worse than bare hands against a #{kind}"
      end
    end

    test "the two-hander is the answer to armour" do
      assert median(:two_hand, :daemon) < median(:daggers, :daemon)
      assert median(:two_hand, :daemon) < median(:shield, :daemon)
      assert median(:two_hand, :daemon) < median(:mace, :daemon)
    end

    test "the daggers are the answer to numbers, not to armour" do
      assert median(:daggers, :husk) <= median(:two_hand, :husk)
      assert median(:daggers, :daemon) > median(:two_hand, :daemon)
    end

    test "armour is subtracted per hit, so two small hits suffer where one big one does not" do
      soft = Gear.fetch(:daggers)
      assert soft.hits == 2
      assert soft.pierce == 1, "without piercing the daggers are strictly worse than a sword"
    end

    test "the shield trades damage for staying alive" do
      assert Gear.fetch(:shield).defence > Gear.fetch(:two_hand).defence
      assert Gear.fetch(:shield).power < Gear.fetch(:two_hand).power
      assert Gear.fetch(:two_hand).defence == 0, "a two-hander leaves no hand for a shield"
    end
  end

  describe "swapping" do
    defp armed(opts \\ []) do
      game = Game.new(seed: 4)
      %{game | owned: Keyword.get(opts, :owned, [:mace, :two_hand])}
    end

    test "you can take up something you own" do
      swapped = Game.command(armed(), {:equip, :mace})

      assert swapped.weapon == :mace
      assert swapped.turn > 0, "swapping costs a turn"
    end

    test "you cannot take up what you have not bought" do
      refused = Game.command(armed(owned: []), {:equip, :mace})

      assert refused.weapon == :unarmed
      assert {"You do not have that.", :warning} = hd(refused.messages)
    end

    test "you can always go back to your hands" do
      assert Game.command(%{armed() | weapon: :mace}, {:equip, :unarmed}).weapon == :unarmed
    end

    test "not with something at arm's reach" do
      game = armed()
      foe = %{Entity.spawn(:husk, 99, next_to(game.player.pos), 1) | awake?: true}
      cornered = %{game | entities: [foe | game.entities]}

      refused = Game.command(cornered, {:equip, :mace})

      assert refused.weapon == :unarmed
      assert {"Not with something at arm's reach.", :warning} = hd(refused.messages)
    end

    test "a sleeping daemon is not a threat" do
      game = armed()
      asleep = %{Entity.spawn(:husk, 99, next_to(game.player.pos), 1) | awake?: false}

      assert Game.command(%{game | entities: [asleep]}, {:equip, :mace}).weapon == :mace
    end

    defp next_to({x, y}), do: {x + 1, y}
  end

  describe "the forge" do
    defp rich(shards), do: %{Game.new(seed: 4) | shards: shards}

    test "a weapon costs what it costs, and you keep it" do
      {:ok, bought, message} = Forge.buy(rich(100), "daggers")

      assert bought.shards == 100 - Gear.cost(:daggers)
      assert :daggers in bought.owned
      assert message =~ "daggers"
    end

    test "buying is refused rather than allowed to go negative" do
      assert {:error, message} = Forge.buy(rich(5), "mace")
      assert message =~ "You have 5"
    end

    test "you cannot buy the same weapon twice" do
      {:ok, once, _} = Forge.buy(rich(200), "mace")
      assert {:error, message} = Forge.buy(once, "mace")
      assert message =~ "already"
    end

    test "upgrades cost more each time" do
      {:ok, one, _} = Forge.buy(rich(500), "power")
      {:ok, two, _} = Forge.buy(one, "power")

      assert one.power_bonus == 1
      assert two.power_bonus == 2
      assert 500 - one.shards < one.shards - two.shards, "the second should cost more"
    end

    test "patches are bought one at a time" do
      before = rich(100)
      {:ok, after_buy, _} = Forge.buy(before, "patch")

      assert after_buy.patches == before.patches + 1
      assert after_buy.shards == 100 - Gear.patch_cost()
    end

    test "selling returns half and takes the weapon away" do
      {:ok, owned, _} = Forge.buy(rich(100), "mace")
      {:ok, sold, message} = Forge.sell(owned, "mace")

      refute :mace in sold.owned
      assert sold.shards == owned.shards + Gear.resale(:mace)
      assert Gear.resale(:mace) < Gear.cost(:mace), "selling back should be a loss"
      assert message =~ "Sold"
    end

    test "you cannot sell what is in your hands" do
      {:ok, owned, _} = Forge.buy(rich(100), "mace")
      held = %{owned | weapon: :mace}

      assert {:error, message} = Forge.sell(held, "mace")
      assert message =~ "in your hands"
    end

    test "upgrades cannot be sold back, so the wallet is not a respec button" do
      {:ok, upgraded, _} = Forge.buy(rich(200), "power")

      assert {:error, _} = Forge.sell(upgraded, "power")
      assert Forge.sell(upgraded, "power") |> elem(0) == :error
    end

    test "the listing shows everything, priced for right now" do
      listing = Forge.listing(rich(0))
      keys = Enum.map(listing, & &1.key)

      assert "two_hand" in keys and "daggers" in keys
      assert "power" in keys and "defence" in keys and "patch" in keys
      assert Enum.all?(listing, &(&1.cost > 0))
    end

    test "the listing prices the next upgrade, not the first" do
      {:ok, upgraded, _} = Forge.buy(rich(500), "power")

      first = Forge.listing(rich(500)) |> Enum.find(&(&1.key == "power"))
      second = Forge.listing(upgraded) |> Enum.find(&(&1.key == "power"))

      assert second.cost > first.cost
    end

    test "a name the forge does not know is refused politely" do
      assert {:error, message} = Forge.buy(rich(500), "trebuchet")
      assert message =~ "no trebuchet"
    end
  end

  describe "a probe picked up off the floor" do
    defp with_probe_underfoot(game) do
      {x, y} = game.player.pos
      %{game | items: Map.put(game.items, {x + 1, y}, :probe)}
    end

    test "raises the damage the game reports" do
      game = Game.new(seed: 12)
      before = Game.stats(game).power

      walked = game |> with_probe_underfoot() |> Game.command({:move, 1, 0})

      assert Game.stats(walked).power == before + 1
    end

    test "raises the damage actually dealt, not just a number somewhere" do
      game = Game.new(seed: 12)

      picked = game |> with_probe_underfoot() |> Game.command({:move, 1, 0})

      assert median_with(picked, :husk) < median_with(game, :husk),
             "a probe should make fights shorter"
    end

    test "counts towards what the forge charges for the next upgrade" do
      game = Game.new(seed: 12)
      picked = game |> with_probe_underfoot() |> Game.command({:move, 1, 0})

      plain = Forge.listing(game) |> Enum.find(&(&1.key == "power"))
      after_probe = Forge.listing(picked) |> Enum.find(&(&1.key == "power"))

      assert after_probe.cost > plain.cost
      assert after_probe.blurb =~ "+1"
    end

    test "says a number the player can check against the sidebar" do
      game = Game.new(seed: 12)
      picked = game |> with_probe_underfoot() |> Game.command({:move, 1, 0})

      {said, _tone} = Enum.find(picked.messages, fn {text, _} -> text =~ "sharper probe" end)

      assert said =~ "#{Game.stats(picked).power}"
    end

    defp median_with(source, kind) do
      turns =
        for seed <- 1..20 do
          level = %Level{
            tiles: %{},
            spawn: {5, 5},
            gate: {0, 0},
            console: {0, 0},
            unsealed?: false
          }

          foe = %{Entity.spawn(kind, 1, {6, 5}, 5) | awake?: true}

          game = %{
            source
            | rng: Rng.new(seed * 13),
              status: :playing,
              level: level,
              entities: [foe],
              items: %{},
              player: %{Entity.scriber({5, 5}) | hp: 9999, max_hp: 9999},
              visible: MapSet.new([{6, 5}]),
              seen: MapSet.new()
          }

          Enum.reduce_while(1..300, {game, 0}, &turn_until_slain/2)
        end

      turns |> Enum.sort() |> Enum.at(10)
    end
  end

  defp turn_until_slain(_turn, {game, n}) do
    played = Game.command(game, {:move, 1, 0})
    if played.entities == [], do: {:halt, n + 1}, else: {:cont, {played, n + 1}}
  end

  describe "what you are holding shows up in your numbers" do
    test "stats combine the weapon with what has been bought" do
      {:ok, game, _} = Forge.buy(%{Game.new(seed: 4) | shards: 500}, "two_hand")
      {:ok, game, _} = Forge.buy(game, "power")
      armed = %{game | weapon: :two_hand}

      assert Game.stats(armed).power == Gear.fetch(:two_hand).power + 1
      assert Game.stats(armed).defence == Gear.fetch(:two_hand).defence
    end
  end
end
