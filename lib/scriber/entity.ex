defmodule Scriber.Entity do
  @moduledoc """
  Anything that occupies a tile and can be hit: the player and every monster.

  One struct covers both. The player has `kind: :scriber` and is built by `scriber/1`;
  monsters have one of the other kinds and are built by `spawn/4` from a fixed archetype
  table. Combat, death and drawing treat the two alike — only who chooses the next action
  differs, and that is `Scriber.Game`'s concern.

  Fields:

    * `id` — unique within a run; the player is always `0`
    * `kind` — one of `t:kind/0`
    * `pos` — `{x, y}` on the current level
    * `hp` / `max_hp` — current and maximum integrity; `hp` never goes below 0
    * `power` — base damage before the weapon and bonuses in `Scriber.Game`
    * `defense` — damage subtracted per incoming hit
    * `speed` — tiles moved per turn; an entity strikes at most once a turn however fast
    * `pace` — a turn every `pace` turns is one the entity acts on; `2` is slow
    * `art` — sprite name in `Scriber.Art`
    * `glyph` — the same thing for terminals without graphics; kept separately because
      several kinds may share a glyph while having distinct sprites
    * `color` — `{r, g, b}` the glyph is drawn in
    * `shards` — paid to the killer when this entity dies
    * `awake?` — whether the entity acts; monsters start asleep, and one that has not
      seen the player for a while sleeps again
    * `seen_at` — the turn the entity last saw the player, or `nil`
    * `goal` — where the entity last knew the player, or a noise, to be walked to
    * `carries` — `{:fragment, n}` when the entity holds a piece of the gate's code,
      dropped where it dies

  ## Example

      monster = Scriber.Entity.spawn(:sentry, 4, {12, 9}, 3)
      monster.hp
      #=> 24
  """

  @type kind :: :scriber | :mite | :sentry | :daemon | :husk

  @type t :: %__MODULE__{
          id: pos_integer(),
          kind: kind(),
          name: String.t(),
          pos: {integer(), integer()},
          hp: integer(),
          max_hp: pos_integer(),
          power: pos_integer(),
          defense: non_neg_integer(),
          speed: pos_integer(),
          art: atom(),
          glyph: String.t(),
          color: {0..255, 0..255, 0..255},
          shards: non_neg_integer(),
          awake?: boolean(),
          pace: pos_integer(),
          seen_at: non_neg_integer() | nil,
          goal: {integer(), integer()} | nil,
          carries: {:fragment, non_neg_integer()} | nil
        }

  @enforce_keys [:id, :kind, :name, :pos, :hp, :max_hp, :power, :art, :glyph, :color]
  defstruct [
    :id,
    :kind,
    :name,
    :pos,
    :hp,
    :max_hp,
    :power,
    :art,
    :glyph,
    :color,
    defense: 0,
    speed: 1,
    shards: 0,
    awake?: false,
    pace: 1,
    seen_at: nil,
    goal: nil,
    carries: nil
  ]

  @archetypes %{
    mite: %{
      name: "cache mite",
      hp: 6,
      power: 3,
      defense: 0,
      speed: 1,
      pace: 1,
      glyph: "m",
      color: {150, 200, 120},
      shards: 4,
      blurb: "quick and brittle; it runs when hurt, and comes back"
    },
    husk: %{
      name: "husk process",
      hp: 14,
      power: 5,
      defense: 1,
      speed: 1,
      pace: 2,
      glyph: "h",
      color: {190, 160, 110},
      shards: 8,
      blurb: "slow and heavy; it moves every other turn, so it can be walked around"
    },
    sentry: %{
      name: "page sentry",
      hp: 20,
      power: 6,
      defense: 2,
      speed: 0,
      pace: 1,
      glyph: "S",
      color: {120, 180, 235},
      shards: 15,
      blurb: "it does not move; it strikes what comes within reach"
    },
    daemon: %{
      name: "orphaned daemon",
      hp: 30,
      power: 7,
      defense: 3,
      speed: 2,
      pace: 1,
      glyph: "D",
      color: {235, 110, 130},
      shards: 30,
      blurb: "fast, and it hunts by sound; waiting is silent, walking is not"
    }
  }

  @doc "A line on what a kind is and how it behaves, for the moment it is first noticed."
  @spec blurb(kind()) :: String.t()
  def blurb(kind) when is_map_key(@archetypes, kind), do: @archetypes[kind].blurb
  def blurb(:scriber), do: "you"

  @doc "Whether the kind moves at all."
  @spec mobile?(t()) :: boolean()
  def mobile?(%__MODULE__{speed: speed}), do: speed > 0

  @doc """
  Build a monster of `kind` with `id`, standing at `pos`, scaled for `depth`.

  `kind` must be one of `:mite`, `:husk`, `:sentry` or `:daemon`; `:scriber` and any other
  value raise a `FunctionClauseError`. Use `scriber/1` for the player.

  `depth` scales the archetype: `hp` and `max_hp` gain `(depth - 1) * 2`, and `power` gains
  `div(depth - 1, 2)`. `defense`, `speed`, `pace` and `shards` do not change with depth.

  The entity starts asleep (`awake?: false`) and at full health.
  """
  @spec spawn(kind(), pos_integer(), {integer(), integer()}, pos_integer()) :: t()
  def spawn(kind, id, pos, depth) when is_map_key(@archetypes, kind) do
    archetype = Map.fetch!(@archetypes, kind)
    hp = archetype.hp + (depth - 1) * 2

    %__MODULE__{
      id: id,
      kind: kind,
      name: archetype.name,
      pos: pos,
      hp: hp,
      max_hp: hp,
      power: archetype.power + div(depth - 1, 2),
      defense: archetype.defense,
      speed: archetype.speed,
      pace: archetype.pace,
      art: kind,
      glyph: archetype.glyph,
      color: archetype.color,
      shards: archetype.shards
    }
  end

  @doc "The player at the start of a run, standing at `pos` with id `0` and 50 integrity."
  @spec scriber({integer(), integer()}) :: t()
  def scriber(pos) do
    %__MODULE__{
      id: 0,
      kind: :scriber,
      name: "you",
      pos: pos,
      hp: 50,
      max_hp: 50,
      power: 5,
      defense: 1,
      art: :scriber,
      glyph: "@",
      color: {245, 235, 200}
    }
  end

  @doc "Whether the entity has any integrity left, and so still acts."
  @spec alive?(t()) :: boolean()
  def alive?(%__MODULE__{hp: hp}), do: hp > 0

  @doc "The entity with `amount` subtracted from `hp`, floored at 0."
  @spec damage(t(), non_neg_integer()) :: t()
  def damage(%__MODULE__{} = entity, amount) do
    %{entity | hp: max(entity.hp - amount, 0)}
  end

  @doc "The entity with `max_hp` raised by `amount`, and `hp` with it."
  @spec harden(t(), non_neg_integer()) :: t()
  def harden(%__MODULE__{} = entity, amount),
    do: %{entity | max_hp: entity.max_hp + amount, hp: entity.hp + amount}

  @doc "The entity with `amount` added to `hp`, capped at `max_hp`."
  @spec heal(t(), non_neg_integer()) :: t()
  def heal(%__MODULE__{} = entity, amount) do
    %{entity | hp: min(entity.hp + amount, entity.max_hp)}
  end
end
