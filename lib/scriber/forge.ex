defmodule Scriber.Forge do
  @moduledoc """
  Spending and recovering shards: the transactions behind the `forge` console command.

  Every transaction is a pure function of a `Scriber.Game`, returning `{:ok, game, message}`
  with the wallet already debited or credited, or `{:error, message}` with the game
  untouched. The message is player-facing text; callers print it and do no formatting of
  their own. Nothing here touches disk — shards live in the game state.

  ## Example

      case Scriber.Forge.buy(game, "daggers") do
        {:ok, game, message} -> {game, message}
        {:error, message} -> {game, message}
      end
  """

  alias Scriber.{Game, Gear}

  @type outcome :: {:ok, Game.t(), String.t()} | {:error, String.t()}

  @upgrades ["power", "defence", "patch"]

  @doc "Every transaction as an action a `Cauldron2D.World` takes as input: `:buy_power`, `:buy_mace`, `:sell_mace`, ..."
  @spec actions() :: [atom()]
  def actions do
    weapons = Enum.map(Gear.purchasable(), &to_string/1)
    Enum.map(@upgrades ++ weapons, &:"buy_#{&1}") ++ Enum.map(weapons, &:"sell_#{&1}")
  end

  @doc "The action for buying or selling `what` as the player typed it, or `nil` when the forge knows no such thing."
  @spec action(:buy | :sell, String.t()) :: atom() | nil
  def action(:buy, "defense"), do: :buy_defence
  def action(:buy, what) when what in @upgrades, do: :"buy_#{what}"

  def action(kind, what) do
    case Gear.parse(what) do
      nil -> nil
      :unarmed -> nil
      weapon -> :"#{kind}_#{weapon}"
    end
  end

  @doc "Run the transaction `action` stands for; `:unknown` for an action that is not one of `actions/0`."
  @spec apply(Game.t(), atom()) :: outcome() | :unknown
  def apply(%Game{} = game, action) do
    case Atom.to_string(action) do
      "buy_" <> what -> buy(game, what)
      "sell_" <> what -> sell(game, what)
      _other -> :unknown
    end
  end

  @doc """
  Everything the forge sells, priced for this game's current state.

  Returns one map per item, in listing order: the four weapons from `Scriber.Gear.purchasable/0`,
  then `"power"`, `"defence"` and `"patch"`. Each has `:key` (the string `buy/2` accepts),
  `:cost` in shards, and `:blurb` describing it. Upgrade costs reflect how many points the
  player has already bought, and a weapon already owned says so in its blurb but is still
  listed at full price.
  """
  @spec listing(Game.t()) :: [%{key: String.t(), cost: pos_integer(), blurb: String.t()}]
  def listing(%Game{} = game) do
    weapons =
      for name <- Gear.purchasable() do
        gear = Gear.fetch(name)
        owned? = name in game.owned

        %{
          key: to_string(name),
          cost: Gear.cost(name),
          blurb: if(owned?, do: "#{gear.blurb} — owned", else: gear.blurb)
        }
      end

    weapons ++
      [
        %{
          key: "power",
          cost: Gear.power_cost(game.power_bonus),
          blurb: "+1 damage (you are on +#{game.power_bonus}, probes included)"
        },
        %{
          key: "defence",
          cost: Gear.defence_cost(game.defence_bonus),
          blurb: "+1 mitigation (you are on +#{game.defence_bonus})"
        },
        %{key: "patch", cost: Gear.patch_cost(), blurb: "+integrity when applied"}
      ]
  end

  @doc """
  Buy one thing, named by the string the player typed.

  Accepts `"power"`, `"defence"` (or `"defense"`), `"patch"`, or anything
  `Scriber.Gear.parse/1` resolves to a weapon. On success the shards are debited and the
  purchase applied: a weapon is added to `:owned` but not equipped, `"power"` and
  `"defence"` raise `:power_bonus` / `:defence_bonus` by one, `"patch"` adds one to
  `:patches`.

  Returns `{:error, message}`, leaving the game unchanged, when the name is unknown, when the
  name resolves to `:unarmed`, when the weapon is already owned, or when there are not enough
  shards.
  """
  @spec buy(Game.t(), String.t()) :: outcome()
  def buy(%Game{} = game, "power"), do: upgrade(game, :power)
  def buy(%Game{} = game, "defence"), do: upgrade(game, :defence)
  def buy(%Game{} = game, "defense"), do: upgrade(game, :defence)
  def buy(%Game{} = game, "patch"), do: patch(game)

  def buy(%Game{} = game, what) do
    case Gear.parse(what) do
      nil -> {:error, "The forge has no #{what}."}
      :unarmed -> {:error, "You already have those."}
      weapon -> weapon(game, weapon)
    end
  end

  @doc """
  Sell a weapon back for `Scriber.Gear.resale/1` shards, removing it from `:owned`.

  `what` is resolved by `Scriber.Gear.parse/1`. Only weapons can be sold — power and defence
  upgrades and patches cannot.

  Returns `{:error, message}`, leaving the game unchanged, when the name is unknown, when it
  resolves to `:unarmed`, when the weapon is not owned, or when it is the weapon currently in
  hand.
  """
  @spec sell(Game.t(), String.t()) :: outcome()
  def sell(%Game{} = game, what) do
    case Gear.parse(what) do
      nil ->
        {:error, "The forge has no #{what}."}

      :unarmed ->
        {:error, "You cannot sell your hands."}

      name ->
        cond do
          name not in game.owned ->
            {:error, "You do not have the #{Gear.fetch(name).label}."}

          game.weapon == name ->
            {:error, "Not while it is in your hands."}

          true ->
            paid = Gear.resale(name)

            {:ok, %{game | owned: List.delete(game.owned, name), shards: game.shards + paid},
             "Sold the #{Gear.fetch(name).label}. +#{paid} shards."}
        end
    end
  end

  defp weapon(game, name) do
    cost = Gear.cost(name)

    cond do
      name in game.owned -> {:error, "You already have the #{Gear.fetch(name).label}."}
      game.shards < cost -> short(game, cost)
      true -> {:ok, spend(game, cost, owned: [name | game.owned]), fitted(name, game, cost)}
    end
  end

  defp fitted(name, game, cost) do
    "Fitted the #{Gear.fetch(name).label}. #{game.shards - cost} shards left."
  end

  defp upgrade(game, :power) do
    cost = Gear.power_cost(game.power_bonus)

    if game.shards < cost do
      short(game, cost)
    else
      {:ok, spend(game, cost, power_bonus: game.power_bonus + 1),
       "Power +1. #{game.shards - cost} shards left."}
    end
  end

  defp upgrade(game, :defence) do
    cost = Gear.defence_cost(game.defence_bonus)

    if game.shards < cost do
      short(game, cost)
    else
      {:ok, spend(game, cost, defence_bonus: game.defence_bonus + 1),
       "Defence +1. #{game.shards - cost} shards left."}
    end
  end

  defp patch(game) do
    cost = Gear.patch_cost()

    if game.shards < cost do
      short(game, cost)
    else
      {:ok, spend(game, cost, patches: game.patches + 1),
       "One patch. #{game.shards - cost} shards left."}
    end
  end

  defp short(game, cost) do
    {:error, "That is #{cost} shards. You have #{game.shards}."}
  end

  defp spend(game, cost, changes) do
    game |> Map.merge(Map.new(changes)) |> Map.put(:shards, game.shards - cost)
  end
end
