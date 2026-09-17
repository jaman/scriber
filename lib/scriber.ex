defmodule Scriber do
  @moduledoc """
  Entry point for the Scriber roguelike.

  A run is played in a terminal. The map is drawn either as sprites composited into one image
  per frame, or as characters, depending on what the terminal supports and what
  `Scriber.Renderer` has been told to do. Each stratum's gate opens for an access code written
  into real files on disk, read through `Scriber.Console`.

  ## Example

      Scriber.play(seed: 1234)

  Equivalently, from the shell:

      mix scriber --seed 1234
  """

  @doc """
  Register the game's widgets and start a run. Blocks until the run ends.

  ## Options

    * `:seed` — integer the whole run derives from. The same seed produces the same map and
      the same access codes, and names the run's directory on disk. Drawn from system entropy
      when omitted.
    * `:record` — keep a `Cauldron2D.Replay` of the run in its world. Default `false`

  ## Environment

    * `SCRIBER_MODE` — `pixel` or `text`, or a specific pixel protocol; see `Scriber.Renderer`
  """
  @spec play(keyword()) :: term()
  def play(opts \\ []) do
    register_widgets()
    Drafter.run(Scriber.App, props: opts |> Keyword.take([:seed, :record]) |> Map.new())
  end

  @doc "The widget modules the game adds to drafter's registry."
  @spec widgets() :: [module()]
  def widgets, do: [Cauldron2D.Drafter.Surface]

  @doc """
  Register every module in `widgets/0` with drafter's widget registry.

  Each module is loaded before it is registered. Registration tests
  `function_exported?(module, :component_tag, 0)`, which answers false for a module the VM
  has not loaded, so an unloaded widget registers nothing and its tag then renders as an
  empty pane rather than raising.

  Must be called before `Drafter.run/2` for the game's tags to resolve. Idempotent.
  """
  @spec register_widgets() :: :ok
  def register_widgets do
    for module <- widgets() do
      Code.ensure_loaded!(module)
      Drafter.Widget.Registry.register(module)
    end

    :ok
  end
end
