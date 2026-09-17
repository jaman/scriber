defmodule Mix.Tasks.Scriber do
  @moduledoc """
  Play Scriber.

      mix scriber
      mix scriber --seed 1234
      mix scriber --mode text
      mix scriber --record

  ## Switches

    * `--seed` — integer; replays the run with that seed. Drawn from system entropy when
      omitted.
    * `--mode` — string; stored as `config :scriber, :mode` before the run starts and read by
      `Scriber.Renderer`. `text` forces glyphs even where the terminal has pixels; `pixel`
      or a protocol name forces the image path.
    * `--record` — keep a `Cauldron2D.Replay` of the run in its world.
  """
  @shortdoc "Play Scriber"

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv, strict: [seed: :integer, mode: :string, record: :boolean])

    if mode = opts[:mode], do: Application.put_env(:scriber, :mode, String.to_atom(mode))

    Mix.Task.run("app.start")
    Scriber.play(Keyword.take(opts, [:seed, :record]))
  end
end
