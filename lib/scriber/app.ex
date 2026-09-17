defmodule Scriber.App do
  @moduledoc """
  The drafter application: layout, key handling, and where the game and the console meet.

  The run is a `Scriber.Game` in a `Cauldron2D.World` of this player's own, started with
  `tick: :on_input`: every key becomes an action sent as input, the world steps once on it,
  and the frame it sends back is what is drawn. This module translates a keystroke into an
  action and a game into a component tree, and owns the two side effects a turn can have —
  writing the next stratum's files and switching the ambience — from the events the world
  sends with each frame.

  ## Modes

  The console is a mode of this application, not a component. While `:console?` is true every
  key goes to the prompt, including the ones that would otherwise move or quit, and only
  `Esc` closes it. `Scriber.Console` can spend shards and shards live in the world, so a
  purchase or a sale is an action the console leaves pending and this module sends the
  world, which applies it.

  ## Keys

  In the Lattice:

      h j k l / arrows   move orthogonally
      q e z c            move diagonally (y u b n also work)
      . or s             wait
      a                  apply a patch
      Enter              use the tile underfoot: a console, or a stair
      >                  descend
      0                  take up bare hands
      1-4                take up a bought weapon, in the order the forge lists them
      m                  toggle mute
      r                  begin another run, once the current one has ended
      Q or Shift-q       quit
      Ctrl-c             quit

  At the console, every printable key types; `Enter` submits, `Backspace` rubs out, `Esc`
  returns to the Lattice.

  ## Gate polling

  A timer checks periodically whether `Scriber.Lattice` has recorded this stratum's gate as
  open, and sends the world `:unseal` when it has. The console is therefore not the only
  thing that can open a gate — anything that writes the marker will do.

  ## Mount props

    * `:seed` — the run's seed. Default: drawn from system entropy
    * `:record` — keep a `Cauldron2D.Replay` of the run in the world. Default `false`
    * `:sink` — the `TuningFork.Sink` the ambience plays through, as `Scriber.Sound.start/2`
      takes it. Default: the speaker
  """

  use Drafter.App, mouse_hover: false

  alias Cauldron2D.{Player, World}
  alias Scriber.{Art, Console, Game, Gear, Lattice, Renderer, Sound}

  @sidebar 28
  @log_height 7
  @poll_ms 400
  @me :me

  @impl true
  def mount(props) do
    Art.install()

    {world, game} = start_world(props)
    Lattice.prepare(game.seed, game.depth)

    %{
      game: game,
      world: world,
      audio: Sound.start(game.depth, Keyword.take(Map.to_list(props), [:sink])),
      record?: Map.get(props, :record, false),
      console?: false,
      console: nil,
      muted?: false,
      root: Lattice.root(game.seed)
    }
  end

  defp start_world(props) do
    {:ok, world} =
      World.start_link(
        game: Game,
        game_opts: Keyword.take(Map.to_list(props), [:seed]),
        tick: :on_input,
        hz: 1,
        record: Map.get(props, :record, false)
      )

    :ok = Player.join(world, @me, %{})
    {world, World.snapshot(world)}
  end

  @impl true
  def unmount(%{world: world, audio: audio}) do
    Sound.stop(audio)
    stop_world(world)
  end

  defp stop_world(world) do
    GenServer.stop(world)
  catch
    :exit, _already_down -> :ok
  end

  @doc """
  Take the world's frame: its view is the game drawn from now on, and its events are the
  turn's side effects — `{:descended, depth}` prepares the stratum's files and switches the
  ambience.
  """
  @impl true
  def on_message({:cauldron_frame, %{view: game, events: events}}, state) do
    Enum.reduce(events, %{state | game: game}, &happened(&2, &1))
  end

  def on_message(_message, state), do: state

  defp happened(state, {:descended, depth}) do
    Lattice.prepare(state.game.seed, depth)
    Sound.descend(state.audio, depth)
    state
  end

  defp happened(state, _event), do: state

  defp act(state, action) do
    Player.input(state.world, @me, %{held: MapSet.new([action]), aim: nil})
    Player.input(state.world, @me, %{held: MapSet.new(), aim: nil})
    state
  end

  @impl true
  def on_ready(state) do
    Drafter.set_interval(@poll_ms, :seal)
    state
  end

  @doc """
  Open the game's gate when `Scriber.Lattice` reports this stratum unsealed on disk.

  Fires on every tick of the `:seal` interval and returns the state unchanged unless the gate
  is recorded open on disk but still shut in the game. Any other timer is ignored.
  """
  @impl true
  def on_timer(:seal, %{game: game} = state) do
    if Game.unsealed?(game) or not Lattice.unsealed?(game.seed, game.depth) do
      state
    else
      act(state, :unseal)
    end
  end

  def on_timer(_timer, state), do: state

  @impl true
  def handle_event({:key, key}, state), do: key |> normalize() |> press([], state)

  def handle_event({:key, key, modifiers}, state),
    do: key |> normalize() |> press(modifiers, state)

  def handle_event(_event, state), do: {:noreply, state}

  defp normalize(key) when is_integer(key), do: List.to_atom([key])
  defp normalize(key), do: key

  defp press(:c, [:ctrl], _state), do: {:stop, :normal}

  defp press(:escape, _mods, %{console?: true} = state) do
    {:ok, %{state | console?: false}}
  end

  defp press(key, mods, %{console?: true} = state), do: {:ok, console_key(state, key, mods)}

  defp press(:Q, _mods, _state), do: {:stop, :normal}
  defp press(:q, [:shift], _state), do: {:stop, :normal}

  defp press(:enter, _mods, %{game: game} = state) do
    if Game.at_console?(game) do
      dir = Lattice.stratum_dir(game.seed, game.depth)
      {:ok, %{state | console?: true, console: Console.new(dir, game.depth)}}
    else
      {:ok, act(state, :use)}
    end
  end

  defp press(:r, _mods, %{game: %{status: status}} = state) when status != :playing do
    {:ok, restart(state)}
  end

  defp press(:m, _mods, state) do
    muted? = not state.muted?
    Sound.mute(state.audio, muted?)
    {:ok, %{state | muted?: muted?}}
  end

  defp press(key, _mods, state) do
    case action(key) do
      nil -> {:noreply, state}
      action -> {:ok, act(state, action)}
    end
  end

  defp restart(state) do
    stop_world(state.world)
    {world, game} = start_world(%{record: state.record?})
    Lattice.prepare(game.seed, game.depth)

    %{
      state
      | game: game,
        world: world,
        console?: false,
        console: nil,
        root: Lattice.root(game.seed)
    }
  end

  defp console_key(state, :enter, _mods) do
    {console, _game} = Console.submit(state.console, state.game, seed: state.game.seed)
    {actions, console} = Console.take_pending(console)
    state = Enum.reduce(actions, %{state | console: console}, &act(&2, &1))

    if Lattice.unsealed?(state.game.seed, state.game.depth) and not Game.unsealed?(state.game),
      do: act(state, :unseal),
      else: state
  end

  defp console_key(state, :backspace, _mods) do
    %{state | console: Console.backspace(state.console)}
  end

  defp console_key(state, :" ", _mods), do: %{state | console: Console.type(state.console, " ")}
  defp console_key(state, :space, _mods), do: %{state | console: Console.type(state.console, " ")}

  defp console_key(state, key, _mods) do
    text = to_string(key)

    if String.length(text) == 1 do
      %{state | console: Console.type(state.console, text)}
    else
      state
    end
  end

  @movement %{
    h: :move_w,
    j: :move_s,
    k: :move_n,
    l: :move_e,
    left: :move_w,
    down: :move_s,
    up: :move_n,
    right: :move_e,
    q: :move_nw,
    e: :move_ne,
    z: :move_sw,
    c: :move_se,
    y: :move_nw,
    u: :move_ne,
    b: :move_sw,
    n: :move_se
  }

  defp action(key) when is_map_key(@movement, key), do: Map.fetch!(@movement, key)
  defp action(:.), do: :wait
  defp action(:s), do: :wait
  defp action(:a), do: :apply_patch
  defp action(:>), do: :descend

  for index <- 0..length(Scriber.Gear.purchasable())//1 do
    defp action(unquote(:"#{index}")), do: unquote(:"equip_#{index}")
  end

  defp action(_key), do: nil

  @impl true
  def render(%{game: game} = state) do
    vertical([
      header(title(game)),
      horizontal([main_pane(state), sidebar(game)], flex: 1),
      log_pane(game),
      footer(bindings: bindings(state))
    ])
  end

  defp title(game) do
    "SCRIBER   stratum #{game.depth}/#{Game.final_depth()}   turn #{game.turn}   [#{Renderer.describe()}]"
  end

  defp main_pane(%{console?: true, console: console}) do
    vertical(
      [
        vertical(Enum.map(Console.transcript(console), &console_line/1), flex: 1),
        label("$ #{console.input}▌", style: %{fg: {158, 250, 224}})
      ],
      flex: 1
    )
  end

  defp main_pane(%{game: %{status: :playing} = game}) do
    {:cauldron_surface,
     [
       id: :map,
       atlas: Art.name(),
       focus: game.player.pos,
       bounds: Game.bounds(game),
       cell: Game.cell_fun(game),
       mode: Renderer.override(),
       flex: 1
     ]}
  end

  defp main_pane(%{game: game}) do
    vertical(
      [
        panel(
          epitaph_title(game),
          Enum.map(epitaph(game), &label(&1, style: %{fg: {220, 220, 235}}))
        )
      ],
      flex: 1
    )
  end

  @tones %{
    system: {245, 235, 200},
    prompt: {158, 250, 224},
    good: {150, 230, 160},
    bad: {236, 108, 128},
    dim: {130, 130, 155},
    plain: {205, 205, 225}
  }

  defp console_line({text, tone}) do
    label(text, style: %{fg: Map.get(@tones, tone, @tones.plain)})
  end

  defp epitaph_title(%{status: :escaped}), do: "out"
  defp epitaph_title(_game), do: "absorbed"

  defp epitaph(game) do
    [
      "",
      outcome(game),
      "",
      "stratum   #{game.depth} of #{Game.final_depth()}",
      "turns     #{game.turn}",
      "shards    #{game.shards}",
      "seed      #{game.seed}",
      "",
      "the run's files are still at",
      "  #{Lattice.root(game.seed)}",
      "",
      "[r] begin another run     [q] quit"
    ]
  end

  defp outcome(%{status: :escaped}), do: "You are out of the Lattice."
  defp outcome(_game), do: "The Lattice absorbed what was left of you."

  defp sidebar(game) do
    vertical(
      [
        panel("you", [
          label(status_line(game), style: %{fg: {245, 235, 200}}),
          meter(value: integrity(game), label: "integrity")
        ]),
        panel("carried", Enum.map(inventory(game), &label/1)),
        panel("in hand", loadout(game)),
        panel("in view", Enum.map(nearby(game), &label(&1, style: %{fg: {200, 200, 235}})))
      ],
      width: @sidebar
    )
  end

  defp panel(title, children), do: box(children, title: title, padding: 0)

  defp status_line(%{player: player} = game) do
    stats = Game.stats(game)
    "#{player.hp}/#{player.max_hp} hp   dmg #{stats.power}   def #{stats.defence}"
  end

  defp integrity(%{player: player}), do: player.hp / player.max_hp

  defp inventory(game) do
    [
      "patches   #{game.patches}",
      "shards    #{game.shards}",
      "gate      #{if Game.unsealed?(game), do: "open", else: "sealed"}"
    ]
  end

  defp loadout(game) do
    held = game.weapon

    [{:unarmed, "0"} | Enum.with_index(Gear.purchasable(), 1)]
    |> Enum.map(fn
      {weapon, key} when is_binary(key) -> {weapon, key}
      {weapon, index} -> {weapon, to_string(index)}
    end)
    |> Enum.filter(fn {weapon, _key} -> weapon == :unarmed or weapon in game.owned end)
    |> Enum.map(fn {weapon, key} ->
      mark = if weapon == held, do: "»", else: " "
      label(" #{mark} [#{key}] #{Gear.fetch(weapon).label}", style: %{fg: colour(weapon, held)})
    end)
  end

  defp colour(weapon, held) when weapon == held, do: {245, 235, 200}
  defp colour(_weapon, _held), do: {140, 140, 165}

  defp nearby(%{entities: entities, visible: visible}) do
    entities
    |> Enum.filter(&MapSet.member?(visible, &1.pos))
    |> Enum.sort_by(& &1.name)
    |> Enum.take(6)
    |> Enum.map(fn entity -> "#{entity.name}  #{entity.hp}hp" end)
    |> case do
      [] -> ["nothing"]
      list -> list
    end
  end

  defp log_pane(game) do
    lines =
      game.messages
      |> Enum.take(@log_height - 2)
      |> Enum.reverse()
      |> Enum.map(fn {text, tone} -> label(text, style: %{fg: tone_color(tone)}) end)

    box(lines, title: "log", padding: 0, height: @log_height)
  end

  defp tone_color(:good), do: {120, 220, 150}
  defp tone_color(:hurt), do: {235, 110, 130}
  defp tone_color(:warning), do: {230, 200, 120}
  defp tone_color(:combat), do: {200, 200, 235}
  defp tone_color(_system), do: {150, 160, 190}

  defp bindings(%{console?: true}) do
    [
      {"Esc", "back to the Lattice"},
      {"probe gate", "start here"},
      {"unseal <code>", "open the gate"}
    ]
  end

  defp bindings(%{game: %{status: :playing} = game}) do
    [{"hjkl/arrows", "move"}, {"qezc", "diagonal"}] ++
      here(game) ++
      swaps(game) ++
      [{".", "wait"}, {"Q", "quit"}]
  end

  defp bindings(_state), do: [{"r", "new run"}, {"Q", "quit"}]

  defp here(game) do
    use_here =
      cond do
        Game.at_console?(game) -> [{"Enter", "console"}]
        Game.at_stair?(game) -> [{"Enter", "descend"}]
        true -> []
      end

    patch = if game.patches > 0, do: [{"a", "patch (#{game.patches})"}], else: []

    use_here ++ patch
  end

  defp swaps(%{owned: []}), do: []

  defp swaps(game) do
    if Game.threatened?(game), do: [], else: [{"0-#{length(game.owned)}", "weapon"}]
  end
end
