defmodule Scriber.Gear do
  @moduledoc """
  The weapon table: what the scriber can fight with, and what each costs.

  A weapon is a plain map with the fields in `t:t/0`. `Scriber.Game` reads them like this:

    * `hits` — swings per attack; a later swing is skipped if an earlier one killed the target
    * `power` — replaces the attacker's own power for the roll
    * `defence` — the player's mitigation while holding it
    * `pierce` — armour the swing ignores
    * `parry` — probability in `0.0..1.0` of turning an incoming hit aside entirely
    * `stun` — probability in `0.0..1.0` that a hit costs the target its next action

  Damage per swing is `max(1, power + d4 - max(target_defence - pierce, 0) - 1)`, and armour
  applies to each swing separately, so a multi-hit weapon loses more to a heavily armoured
  target than a single-hit one of equal total power.

  Every weapon costs the same; the choice is which, not how much. Upgrades to power and
  defence cost more the more of them have been bought.

  ## Example

      Scriber.Gear.fetch(:daggers).hits
      #=> 2
      Scriber.Gear.power_cost(2)
      #=> 75

  `GEAR_DESIGN.md` at the repository root records the modelling behind these numbers.
  """

  @type name :: :unarmed | :two_hand | :shield | :daggers | :mace

  @type t :: %{
          name: name(),
          label: String.t(),
          hits: pos_integer(),
          power: pos_integer(),
          defence: non_neg_integer(),
          pierce: non_neg_integer(),
          parry: float(),
          stun: float(),
          blurb: String.t()
        }

  @gear %{
    unarmed: %{
      label: "bare hands",
      hits: 1,
      power: 5,
      defence: 1,
      pierce: 0,
      parry: 0.0,
      stun: 0.0,
      blurb: "what you woke with"
    },
    two_hand: %{
      label: "two-hand",
      hits: 1,
      power: 9,
      defence: 0,
      pierce: 0,
      parry: 0.0,
      stun: 0.0,
      blurb: "power 9, no shield"
    },
    shield: %{
      label: "sword+shield",
      hits: 1,
      power: 6,
      defence: 3,
      pierce: 0,
      parry: 0.0,
      stun: 0.0,
      blurb: "power 6, defence 3"
    },
    daggers: %{
      label: "daggers",
      hits: 2,
      power: 4,
      defence: 1,
      pierce: 1,
      parry: 0.25,
      stun: 0.0,
      blurb: "two hits, each ignoring 1 armour"
    },
    mace: %{
      label: "mace",
      hits: 1,
      power: 7,
      defence: 1,
      pierce: 0,
      parry: 0.0,
      stun: 0.2,
      blurb: "power 7, one hit in five stuns"
    }
  }

  @weapon_cost 45
  @patch_cost 12
  @power_step 25
  @defence_step 30

  @doc "Every equippable name, including `:unarmed`. Order is unspecified."
  @spec all() :: [name()]
  def all, do: Map.keys(@gear)

  @doc "The four buyable weapons, in the order the forge lists them. Excludes `:unarmed`."
  @spec purchasable() :: [name()]
  def purchasable, do: [:two_hand, :shield, :daggers, :mace]

  @doc """
  The weapon entry for `name`, with `:name` set on it.

  `name` must be one of `all/0`; anything else raises a `FunctionClauseError`.
  """
  @spec fetch(name()) :: t()
  def fetch(name) when is_map_key(@gear, name), do: Map.put(@gear[name], :name, name)

  @doc """
  The weapon name matching a string a player typed, or `nil` if none does.

  The string is trimmed, downcased, and has `-` replaced with `_` before it is matched
  against both the atom names and the labels, so `"Sword+Shield"` and `"shield"` both give
  `:shield`, and `"two-hand"` gives `:two_hand`.
  """
  @spec parse(String.t()) :: name() | nil
  def parse(text) do
    wanted = text |> String.trim() |> String.downcase() |> String.replace("-", "_")

    Enum.find(all(), fn name ->
      to_string(name) == wanted or String.downcase(@gear[name].label) == wanted
    end)
  end

  @doc "The shard price of a weapon. The same #{@weapon_cost} for every weapon."
  @spec cost(name()) :: pos_integer()
  def cost(_weapon), do: @weapon_cost

  @doc "What selling a weapon back pays: half its `cost/1`, rounded down."
  @spec resale(name()) :: pos_integer()
  def resale(weapon), do: div(cost(weapon), 2)

  @doc "The shard price of one patch."
  @spec patch_cost() :: pos_integer()
  def patch_cost, do: @patch_cost

  @doc """
  The shard price of the next point of power, given `owned` points already bought.

  Rises linearly: `#{@power_step} * (owned + 1)`.
  """
  @spec power_cost(non_neg_integer()) :: pos_integer()
  def power_cost(owned), do: @power_step * (owned + 1)

  @doc """
  The shard price of the next point of defence, given `owned` points already bought.

  Rises linearly: `#{@defence_step} * (owned + 1)`.
  """
  @spec defence_cost(non_neg_integer()) :: pos_integer()
  def defence_cost(owned), do: @defence_step * (owned + 1)
end
