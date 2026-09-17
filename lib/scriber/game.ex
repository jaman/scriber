defmodule Scriber.Game do
  @moduledoc """
  A whole run as one value, and one turn as one function over it.

  `command/2` is the only way the world changes. It takes the state and what the player asked
  for and returns the state after everything that follows. Nothing in this module touches the
  terminal, spawns a process or reads a file, so a run can be played out by folding a list of
  commands over `new/1`.

  ## Turn order

  A turn that is accepted runs, in order: the player's action, then one action for every
  living monster in id order (twice for a monster with `speed: 2`), then a recomputed field
  of view, then the death check. A command the world refuses — walking into a wall,
  descending off a stair, equipping what is not owned — costs no turn, leaves the state
  otherwise unchanged, and adds a message rather than raising.

  ## Vision

  `:visible` is what the player can see this instant; `:seen` is the union of everything ever
  visible on the current stratum. Both are cleared on descending. Callers drawing the map
  should treat a tile in `:seen` but not `:visible` as remembered terrain with no occupants.

  ## The gate

  This module does not open gates. `Scriber.Console` accepts an access code and writes a
  marker, and the caller then invokes `unseal/1`, which turns the `:gate` tile into a
  `:stair`.

  ## As a `Cauldron2D.Game`

  A `Cauldron2D.World` started with `tick: :on_input` runs a game of this module one step
  per input: `handle_input/3` keeps the actions newly pressed by the one player who joined
  first, and `step/2` turns each into a `command/2` — `actions/0` lists them, `command_for/1`
  says which command each is. `:use` descends on a stair and says so elsewhere; `:unseal`
  is `unseal/1`, held by the application when the gate's marker appears on disk; the forge
  actions of `Scriber.Forge.actions/0` buy and sell. `view/2` is the game; `drain_events/1`
  gives `{:descended, depth}` and `:unsealed`.

  ## Example

      Scriber.Game.new(seed: 99)
      |> Scriber.Game.command({:move, 1, 0})
      |> Scriber.Game.command(:wait)
  """

  @behaviour Cauldron2D.Game

  alias Cauldron2D.Grid.Fov
  alias Cauldron2D.Rng
  alias Scriber.{Entity, Forge, Gear, Lattice, Level}

  @type status :: :playing | :dead | :escaped
  @type item :: :shard | :patch | :probe
  @type command ::
          {:move, integer(), integer()}
          | :wait
          | :descend
          | :apply_patch
          | {:equip, Gear.name()}

  @type t :: %__MODULE__{
          level: Level.t(),
          player: Entity.t(),
          entities: [Entity.t()],
          items: %{{integer(), integer()} => item()},
          messages: [{String.t(), atom()}],
          visible: MapSet.t(),
          seen: MapSet.t(),
          rng: Rng.t(),
          seed: integer(),
          depth: pos_integer(),
          turn: non_neg_integer(),
          status: status(),
          patches: non_neg_integer(),
          shards: non_neg_integer(),
          next_id: pos_integer(),
          player_id: term() | nil,
          held: MapSet.t(atom()),
          pressed: [atom()],
          events: [term()]
        }

  defstruct [
    :level,
    :player,
    :rng,
    :seed,
    entities: [],
    items: %{},
    messages: [],
    visible: nil,
    seen: nil,
    depth: 1,
    turn: 0,
    status: :playing,
    patches: 1,
    shards: 0,
    next_id: 1,
    weapon: :unarmed,
    owned: [],
    power_bonus: 0,
    defence_bonus: 0,
    stunned: [],
    player_id: nil,
    held: MapSet.new(),
    pressed: [],
    events: []
  ]

  @sight 8
  @max_messages 200
  @final_depth 5

  @moves %{
    move_w: {-1, 0},
    move_s: {0, 1},
    move_n: {0, -1},
    move_e: {1, 0},
    move_nw: {-1, -1},
    move_ne: {1, -1},
    move_sw: {-1, 1},
    move_se: {1, 1}
  }
  @equips [
    {:equip_0, :unarmed}
    | Enum.map(Enum.with_index(Gear.purchasable(), 1), fn {weapon, index} ->
        {:"equip_#{index}", weapon}
      end)
  ]

  @doc "The actions `handle_input/3` reads: the moves, `:wait`, `:apply_patch`, `:descend`, `:use`, the equips, `:unseal` and the forge's."
  @spec actions() :: [atom()]
  def actions,
    do:
      Map.keys(@moves) ++
        [:wait, :apply_patch, :descend, :use] ++
        Keyword.keys(@equips) ++ [:unseal] ++ Forge.actions()

  @doc "The `command/2` an action stands for, or `nil` for one `step/2` handles itself."
  @spec command_for(atom()) :: command() | nil
  def command_for(action) when is_map_key(@moves, action) do
    {dx, dy} = Map.fetch!(@moves, action)
    {:move, dx, dy}
  end

  def command_for(action) when action in [:wait, :apply_patch, :descend], do: action

  def command_for(action) do
    case List.keyfind(@equips, action, 0) do
      {_action, weapon} -> {:equip, weapon}
      nil -> nil
    end
  end

  @impl Cauldron2D.Game
  def init(opts), do: new(opts)

  @impl Cauldron2D.Game
  def join(%__MODULE__{player_id: nil} = game, id, _props), do: {:ok, %{game | player_id: id}}
  def join(%__MODULE__{} = game, _id, _props), do: {:ok, game}

  @impl Cauldron2D.Game
  def leave(%__MODULE__{player_id: id} = game, id),
    do: %{game | player_id: nil, held: MapSet.new(), pressed: []}

  def leave(%__MODULE__{} = game, _id), do: game

  @impl Cauldron2D.Game
  def handle_input(%__MODULE__{player_id: id} = game, id, %{held: held}) do
    fresh = held |> MapSet.difference(game.held) |> Enum.sort()
    %{game | held: held, pressed: game.pressed ++ fresh}
  end

  def handle_input(%__MODULE__{} = game, _id, _input), do: game

  @impl Cauldron2D.Game
  def step(%__MODULE__{pressed: pressed} = game, _dt) do
    Enum.reduce(pressed, %{game | pressed: []}, &press(&2, &1))
  end

  defp press(game, :unseal), do: unseal(game)

  defp press(%__MODULE__{} = game, :use) do
    if at_stair?(game),
      do: command(game, :descend),
      else: announce(game, "Nothing to use here.", :warning)
  end

  defp press(game, action) do
    case command_for(action) do
      nil -> forge(game, action)
      command -> command(game, command)
    end
  end

  defp forge(%__MODULE__{status: :playing} = game, action) do
    case Forge.apply(game, action) do
      {:ok, changed, message} -> announce(changed, message, :good)
      {:error, why} -> announce(game, why, :warning)
      :unknown -> game
    end
  end

  defp forge(game, _action), do: game

  @impl Cauldron2D.Game
  def view(%__MODULE__{} = game, _id), do: game

  @impl Cauldron2D.Game
  def drain_events(%__MODULE__{events: events} = game),
    do: {Enum.reverse(events), %{game | events: []}}

  defp emit(%__MODULE__{} = game, event), do: %{game | events: [event | game.events]}

  @doc """
  Start a run on stratum 1, with the player placed, monsters and items scattered, and the
  opening messages logged.

  ## Options

    * `:seed` — integer the run derives from. The same seed gives the same map, spawns and
      rolls. Drawn from system entropy when omitted, and always readable afterwards as
      `game.seed`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    {rng, seed} =
      case Keyword.get(opts, :seed) do
        nil -> Rng.random()
        seed -> {Rng.new(seed), seed}
      end

    %__MODULE__{rng: rng, seed: seed}
    |> enter_stratum(1)
    |> announce("You wake on stratum 1. The Lattice is failing around you.", :system)
    |> announce("Find the console. The gate below will not open without its code.", :system)
  end

  @doc """
  Generate the stratum at `depth`, put the player at its spawn, and populate it.

  Returns a game whose level is fully built: monsters spawned, items scattered, and the field
  of view computed. The player keeps hit points, weapon, shards, patches and bonuses; the
  previous stratum's entities, items, `:visible` and `:seen` are all discarded, so a new
  stratum always arrives unexplored.

  Does not check that `depth` follows the current one, and does not log a message. Use
  `command(game, :descend)` for an ordinary descent.
  """
  @spec enter_stratum(t(), pos_integer()) :: t()
  def enter_stratum(%__MODULE__{} = game, depth) do
    {level, rng} = Level.build(game.rng, depth)
    player = keep_player(game, level.spawn)

    %{
      game
      | level: level,
        rng: rng,
        depth: depth,
        player: player,
        entities: [],
        items: %{},
        visible: MapSet.new(),
        seen: MapSet.new()
    }
    |> populate()
    |> refresh_vision()
  end

  defp keep_player(%__MODULE__{player: nil}, spawn), do: Entity.scriber(spawn)
  defp keep_player(%__MODULE__{player: player}, spawn), do: %{player | pos: spawn}

  defp populate(%__MODULE__{level: level} = game) do
    open = level |> Level.open_tiles() |> Enum.reject(&(&1 == level.spawn))
    {spots, rng} = Rng.shuffle(game.rng, open)
    {far, near} = Enum.split_with(spots, &beyond_sight?(&1, level.spawn))
    {monsters, spare} = Enum.split(far, monster_count(game.depth))

    game
    |> Map.put(:rng, rng)
    |> spawn_monsters(monsters)
    |> scatter_items(near ++ spare)
  end

  defp beyond_sight?({x, y}, {sx, sy}) do
    dx = x - sx
    dy = y - sy
    dx * dx + dy * dy > @sight * @sight
  end

  defp monster_count(depth), do: 4 + depth * 2

  defp spawn_monsters(game, spots) do
    Enum.reduce(spots, game, fn spot, acc ->
      {kind, rng} = Rng.weighted(acc.rng, spawn_table(acc.depth))
      entity = Entity.spawn(kind, acc.next_id, spot, acc.depth)
      %{acc | entities: [entity | acc.entities], next_id: acc.next_id + 1, rng: rng}
    end)
  end

  defp spawn_table(depth) do
    [
      {max(1, 12 - depth * 2), :mite},
      {4 + depth, :husk},
      {max(1, depth * 2), :sentry},
      {max(0, depth - 2) * 2, :daemon}
    ]
    |> Enum.reject(fn {weight, _kind} -> weight == 0 end)
  end

  defp scatter_items(game, spots) do
    count = item_count(game.depth)
    promised = patch_floor(game.depth)
    chosen = Enum.take(spots, count)
    stride = max(div(count, max(promised, 1)), 1)

    chosen
    |> Enum.with_index()
    |> Enum.reduce(game, fn {spot, index}, acc ->
      if rem(index, stride) == 0 and div(index, stride) < promised do
        %{acc | items: Map.put(acc.items, spot, :patch)}
      else
        {item, rng} = Rng.weighted(acc.rng, [{6, :shard}, {3, :patch}, {1, :probe}])
        %{acc | items: Map.put(acc.items, spot, item), rng: rng}
      end
    end)
  end

  @doc """
  How many items a stratum at `depth` carries in total.

  Items land only on walkable tiles that no monster took, so a very cramped level may carry
  fewer than this.
  """
  @spec item_count(pos_integer()) :: pos_integer()
  def item_count(depth), do: 4 + div(depth, 2)

  @doc """
  The least number of a stratum's items that are guaranteed to be patches.

  Every stratum places at least this many patches, spread evenly through the item positions
  rather than clustered. The remaining items are rolled from a weighted table of shards,
  patches and probes, so the actual patch count is never lower than this and is often higher.
  """
  @spec patch_floor(pos_integer()) :: pos_integer()
  def patch_floor(depth), do: max(1, div(depth + 1, 2))

  @doc """
  Resolve one turn from the player's `command`, returning the game after it.

  Accepted commands:

    * `{:move, dx, dy}` — step one tile, or attack whatever living entity is on the target
      tile. Walking into a sealed gate reports the gate's node state instead and costs no
      turn; walking into anything else solid is refused.
    * `:wait` — spend the turn doing nothing.
    * `:apply_patch` — spend one patch to heal 15, capped at `max_hp`. Refused with no
      patches or at full health.
    * `{:equip, weapon}` — take up a weapon. Refused unless the weapon is `:unarmed` or in
      `:owned`, refused if already held, and refused while an awake monster is adjacent.
    * `:descend` — take the stair underfoot to the next stratum, or end the run with
      `status: :escaped` when already at `final_depth/0`. Refused off a stair.

  A game whose `:status` is not `:playing` is returned unchanged for every command, so a
  caller need not check before dispatching.

  A refused command costs no turn and adds a `:warning` message. Turn resolution never
  raises for an unreachable target or an occupied tile.
  """
  @spec command(t(), command()) :: t()
  def command(%__MODULE__{status: status} = game, _command) when status != :playing, do: game

  def command(%__MODULE__{} = game, {:move, dx, dy}) do
    {x, y} = game.player.pos
    target = {x + dx, y + dy}

    case occupant(game, target) do
      nil -> walk(game, target)
      entity -> game |> player_attacks(entity) |> end_turn()
    end
  end

  def command(%__MODULE__{} = game, :wait) do
    game |> end_turn()
  end

  def command(%__MODULE__{} = game, {:equip, weapon}) do
    cond do
      weapon != :unarmed and weapon not in game.owned ->
        announce(game, "You do not have that.", :warning)

      game.weapon == weapon ->
        announce(game, "Already in hand.", :warning)

      threatened?(game) ->
        announce(game, "Not with something at arm's reach.", :warning)

      true ->
        %{game | weapon: weapon}
        |> announce("You take up the #{Gear.fetch(weapon).label}.", :system)
        |> end_turn()
    end
  end

  def command(%__MODULE__{} = game, :apply_patch) do
    cond do
      game.patches == 0 ->
        announce(game, "No patches left.", :warning)

      game.player.hp == game.player.max_hp ->
        announce(game, "Integrity is already whole.", :warning)

      true ->
        healed = Entity.heal(game.player, 15)
        gained = healed.hp - game.player.hp

        %{game | player: healed, patches: game.patches - 1}
        |> announce("You apply a patch. +#{gained} integrity.", :good)
        |> end_turn()
    end
  end

  def command(%__MODULE__{} = game, :descend) do
    if Level.at(game.level, game.player.pos) == :stair do
      descend(game)
    else
      announce(game, "Nothing to descend here.", :warning)
    end
  end

  defp descend(%__MODULE__{depth: depth} = game) when depth >= @final_depth do
    %{game | status: :escaped}
    |> announce("You drop through the last gate and out of the Lattice. You made it.", :good)
  end

  defp descend(%__MODULE__{} = game) do
    game
    |> enter_stratum(game.depth + 1)
    |> announce("You descend to stratum #{game.depth + 1}.", :system)
    |> emit({:descended, game.depth + 1})
  end

  @doc "Whether any awake monster stands on one of the eight tiles around the player."
  @spec threatened?(t()) :: boolean()
  def threatened?(%__MODULE__{} = game) do
    Enum.any?(game.entities, &(&1.awake? and adjacent?(&1.pos, game.player.pos)))
  end

  @doc "The weapon currently in hand, as a `Scriber.Gear` entry."
  @spec weapon(t()) :: Gear.t()
  def weapon(%__MODULE__{weapon: name}), do: Gear.fetch(name)

  @doc """
  The player's effective `:power` and `:defence`, as the sidebar shows them.

  Each is the value from the weapon in hand plus the matching purchased bonus. These are the
  numbers combat actually uses; `game.player.power` and `game.player.defense` are not.
  """
  @spec stats(t()) :: %{power: pos_integer(), defence: non_neg_integer()}
  def stats(%__MODULE__{} = game) do
    gear = Gear.fetch(game.weapon)
    %{power: gear.power + game.power_bonus, defence: gear.defence + game.defence_bonus}
  end

  defp walk(%__MODULE__{} = game, target) do
    cond do
      Level.walkable?(game.level, target) ->
        game
        |> Map.put(:player, %{game.player | pos: target})
        |> pick_up(target)
        |> arrival_notice(target)
        |> end_turn()

      Level.at(game.level, target) == :gate ->
        game
        |> announce("The gate is sealed. Its controller reports:", :system)
        |> announce("  state: #{Lattice.gate_state(game.seed, game.depth)}", :good)
        |> announce("Find that state in the records at the console.", :system)

      true ->
        announce(game, "Solid.", :warning)
    end
  end

  defp arrival_notice(%__MODULE__{} = game, target) do
    case Level.at(game.level, target) do
      :console -> announce(game, "A live console. Press [Enter] to use it.", :system)
      :stair -> announce(game, "The gate stands open. Press [Enter] to go down.", :good)
      _other -> game
    end
  end

  defp pick_up(%__MODULE__{} = game, target) do
    case Map.pop(game.items, target) do
      {nil, _items} -> game
      {item, items} -> collect(%{game | items: items}, item)
    end
  end

  defp collect(game, :shard) do
    %{game | shards: game.shards + 1}
    |> announce("You pocket a shard. (#{game.shards + 1})", :good)
  end

  defp collect(game, :patch) do
    %{game | patches: game.patches + 1}
    |> announce("You pick up a patch. (#{game.patches + 1})", :good)
  end

  defp collect(game, :probe) do
    raised = %{game | power_bonus: game.power_bonus + 1}

    announce(raised, "A sharper probe. Your damage rises to #{stats(raised).power}.", :good)
  end

  @doc """
  The living monster standing on `point`, or `nil` if none is.

  Only searches `:entities`, so it never returns the player even when `point` is the player's
  own tile.
  """
  @spec occupant(t(), {integer(), integer()}) :: Entity.t() | nil
  def occupant(%__MODULE__{entities: entities}, point) do
    Enum.find(entities, fn entity -> entity.pos == point and Entity.alive?(entity) end)
  end

  defp player_attacks(%__MODULE__{} = game, target) do
    weapon = Gear.fetch(game.weapon)
    attacker = %{game.player | power: weapon.power + game.power_bonus}

    {game, hurt} =
      Enum.reduce(1..weapon.hits//1, {game, target}, fn _swing, {acc, victim} ->
        if Entity.alive?(victim), do: swing(acc, attacker, victim, weapon), else: {acc, victim}
      end)

    game
    |> maybe_stun(hurt, weapon)
    |> resolve_death(hurt)
  end

  defp swing(game, attacker, victim, weapon) do
    {damage, rng} = damage_roll(game.rng, attacker, victim, weapon.pierce)
    hurt = Entity.damage(victim, damage)

    game = %{game | rng: rng, entities: replace(game.entities, hurt)}

    {announce(game, "You hit the #{victim.name} for #{damage}.", :combat), hurt}
  end

  defp maybe_stun(game, _target, %{stun: chance}) when chance <= 0.0, do: game

  defp maybe_stun(game, target, %{stun: chance}) do
    {roll, rng} = Rng.dice(game.rng, 1, 100)
    game = %{game | rng: rng}

    if Entity.alive?(target) and roll <= chance * 100 do
      %{game | stunned: [target.id | game.stunned]}
      |> announce("The #{target.name} reels, senseless.", :good)
    else
      game
    end
  end

  defp resolve_death(%__MODULE__{} = game, entity) do
    if Entity.alive?(entity) do
      game
    else
      %{
        game
        | entities: Enum.reject(game.entities, &(&1.id == entity.id)),
          shards: game.shards + entity.shards
      }
      |> announce("The #{entity.name} unravels. +#{entity.shards} shards.", :good)
    end
  end

  defp damage_roll(rng, attacker, defender, pierce \\ 0) do
    {bonus, rng} = Rng.dice(rng, 1, 4)
    armour = max(defender.defense - pierce, 0)

    {max(1, attacker.power + bonus - armour - 1), rng}
  end

  defp end_turn(%__MODULE__{} = game) do
    game
    |> Map.update!(:turn, &(&1 + 1))
    |> monsters_act()
    |> refresh_vision()
    |> check_player()
  end

  defp monsters_act(%__MODULE__{} = game) do
    game.entities
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce(game, fn entity, acc -> act_repeatedly(acc, entity.id, entity.speed) end)
  end

  defp act_repeatedly(game, _id, 0), do: game

  defp act_repeatedly(game, id, times) do
    case Enum.find(game.entities, &(&1.id == id)) do
      nil -> game
      entity -> game |> act(entity) |> act_repeatedly(id, times - 1)
    end
  end

  defp act(%__MODULE__{status: :playing} = game, entity) do
    entity = wake(game, entity)

    cond do
      not entity.awake? ->
        store(game, entity)

      entity.id in game.stunned ->
        %{store(game, entity) | stunned: List.delete(game.stunned, entity.id)}

      adjacent?(entity.pos, game.player.pos) ->
        game |> store(entity) |> monster_attacks(entity)

      true ->
        game |> store(entity) |> step_toward(entity, game.player.pos)
    end
  end

  defp act(game, _entity), do: game

  defp wake(%__MODULE__{} = game, %{awake?: false} = entity) do
    %{entity | awake?: MapSet.member?(game.visible, entity.pos)}
  end

  defp wake(_game, entity), do: entity

  defp store(%__MODULE__{} = game, entity) do
    %{game | entities: replace(game.entities, entity)}
  end

  defp monster_attacks(%__MODULE__{} = game, entity) do
    weapon = Gear.fetch(game.weapon)
    guard = %{game.player | defense: weapon.defence + game.defence_bonus}
    {parried?, rng} = parry(game.rng, weapon)

    if parried? do
      %{game | rng: rng} |> announce("You turn the #{entity.name}'s strike aside.", :good)
    else
      {damage, rng} = damage_roll(rng, entity, guard)

      %{game | rng: rng, player: Entity.damage(game.player, damage)}
      |> announce("The #{entity.name} hits you for #{damage}.", :hurt)
    end
  end

  defp parry(rng, %{parry: chance}) when chance <= 0.0, do: {false, rng}

  defp parry(rng, %{parry: chance}) do
    {roll, rng} = Rng.dice(rng, 1, 100)
    {roll <= chance * 100, rng}
  end

  defp step_toward(%__MODULE__{} = game, entity, {tx, ty}) do
    {ex, ey} = entity.pos
    step = {ex + sign(tx - ex), ey + sign(ty - ey)}

    case free_step(game, entity, [step | sidesteps(entity.pos, step)]) do
      nil -> game
      target -> store(game, %{entity | pos: target})
    end
  end

  defp sidesteps({ex, ey}, {sx, sy}), do: [{sx, ey}, {ex, sy}] -- [{ex, ey}]

  defp free_step(game, entity, candidates) do
    Enum.find(candidates, fn point ->
      point != entity.pos and Level.walkable?(game.level, point) and
        point != game.player.pos and occupant(game, point) == nil
    end)
  end

  defp sign(n) when n > 0, do: 1
  defp sign(n) when n < 0, do: -1
  defp sign(_n), do: 0

  defp adjacent?({ax, ay}, {bx, by}), do: abs(ax - bx) <= 1 and abs(ay - by) <= 1

  defp check_player(%__MODULE__{} = game) do
    if Entity.alive?(game.player) do
      game
    else
      %{game | status: :dead}
      |> announce("Your integrity reaches zero. The Lattice absorbs what is left of you.", :hurt)
    end
  end

  defp replace(entities, entity) do
    Enum.map(entities, fn candidate ->
      if candidate.id == entity.id, do: entity, else: candidate
    end)
  end

  @doc """
  Recompute `:visible` from the player's position and union it into `:seen`.

  Called at the end of every accepted turn and on entering a stratum; a caller that moves the
  player directly must call it before drawing. Tolerates a `nil` `:seen`.
  """
  @spec refresh_vision(t()) :: t()
  def refresh_vision(%__MODULE__{} = game) do
    visible = Fov.compute(&Level.transparent?(game.level, &1), game.player.pos, @sight)
    seen = MapSet.union(game.seen || MapSet.new(), visible)
    %{game | visible: visible, seen: seen}
  end

  @doc """
  Open this stratum's gate, turning its `:gate` tile into a walkable `:stair`.

  Call this once `Scriber.Console` has accepted the access code. Returns the game unchanged
  when the gate is already open, so it is safe to call on every poll.
  """
  @spec unseal(t()) :: t()
  def unseal(%__MODULE__{level: %{unsealed?: true}} = game), do: game

  def unseal(%__MODULE__{} = game) do
    %{game | level: Level.unseal(game.level)}
    |> announce("The gate grinds open. The way down is clear.", :good)
    |> emit(:unsealed)
  end

  @doc "Whether this stratum's gate has been opened in the game state."
  @spec unsealed?(t()) :: boolean()
  def unsealed?(%__MODULE__{level: level}), do: level.unsealed?

  @doc "Whether the player is standing on the stratum's console tile."
  @spec at_console?(t()) :: boolean()
  def at_console?(%__MODULE__{} = game) do
    Level.at(game.level, game.player.pos) == :console
  end

  @doc """
  Whether the player is standing on a stair.

  This is exactly the condition `command(game, :descend)` tests, so a caller can use it to
  decide whether to offer the descend key.
  """
  @spec at_stair?(t()) :: boolean()
  def at_stair?(%__MODULE__{} = game) do
    Level.at(game.level, game.player.pos) == :stair
  end

  @doc """
  A one-argument function telling `Cauldron2D.Surface` what to draw at a coordinate.

  The returned function answers, for a point:

    * `{tile, occupants, nil}` when the point is currently visible — `occupants` is a list of
      at most one art name, the player's taking precedence over a monster's, and a monster's
      over an item's
    * `{tile, [], :dim}` when the point has been seen but is not visible now — remembered
      terrain, drawn without whatever stands on it
    * `:void` when the point has never been seen, carrying no terrain at all

  Build it once per frame and reuse it across the whole surface: the occupant index is
  computed when this is called, and the returned closure does only map lookups. It captures
  the game as it is now, so a stale one draws a stale frame.
  """
  @spec cell_fun(t()) :: (Level.point() -> Cauldron2D.Surface.cell())
  def cell_fun(%__MODULE__{} = game) do
    occupants =
      game.entities
      |> Map.new(fn entity -> {entity.pos, entity.art} end)
      |> then(&Map.merge(game.items, &1))
      |> Map.put(game.player.pos, game.player.art)

    fn point ->
      cond do
        MapSet.member?(game.visible, point) ->
          {Level.at(game.level, point), List.wrap(Map.get(occupants, point)), nil}

        MapSet.member?(game.seen, point) ->
          {Level.at(game.level, point), [], :dim}

        true ->
          :void
      end
    end
  end

  @doc "The current stratum's `{width, height}` in tiles, for clamping the camera to it."
  @spec bounds(t()) :: {pos_integer(), pos_integer()}
  def bounds(%__MODULE__{level: level}), do: {level.width, level.height}

  @doc """
  Prepend `{text, tone}` to the message log.

  `:messages` is newest first and is capped at #{@max_messages} entries; older ones are
  dropped. `tone` is a hint for the caller's colouring — `:system`, `:good`, `:hurt`,
  `:warning` and `:combat` are the tones this module raises.
  """
  @spec announce(t(), String.t(), atom()) :: t()
  def announce(%__MODULE__{} = game, text, tone) do
    %{game | messages: Enum.take([{text, tone} | game.messages], @max_messages)}
  end

  @doc "The deepest stratum. Descending from it ends the run with `status: :escaped`."
  @spec final_depth() :: pos_integer()
  def final_depth, do: @final_depth
end
