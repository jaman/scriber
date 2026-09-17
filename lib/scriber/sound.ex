defmodule Scriber.Sound do
  @moduledoc """
  The game's audio: a `Cauldron2D.Audio` instance of the application's own, and the
  ambience bed switched as the player descends.

  Playback, mixing and caching are `Cauldron2D.Audio`'s; the beds themselves are
  `Scriber.Ambience`'s. What lives here is which bed belongs to which stratum.

  Setting `SCRIBER_QUIET` to any non-empty value makes `start/2` answer `nil`, and every
  other function is a no-op on `nil`, so the game runs silent without checking.

  ## Example

      audio = Scriber.Sound.start(1)
      Scriber.Sound.descend(audio, 2)
      Scriber.Sound.mute(audio, true)
      Scriber.Sound.stop(audio)
  """

  alias Cauldron2D.Audio
  alias Scriber.Ambience
  alias TuningFork.Cache

  @type t :: pid() | nil

  @doc """
  Start an audio instance linked to the caller and begin `depth`'s ambience.

  `opts` are `Cauldron2D.Audio.start_link/1`'s, `:sink` above all; the stage's settings are
  set here. Returns the instance, or `nil` when `SCRIBER_QUIET` is set.
  """
  @spec start(pos_integer(), keyword()) :: t()
  def start(depth \\ 1, opts \\ []) do
    if enabled?() do
      {:ok, audio} =
        Audio.start_link(
          [
            name: nil,
            sounds: &voice/1,
            chunk: 256,
            voices: 8,
            lead: 1_024,
            music: 1.0,
            fx: [reverb: [room: 0.92, damp: 0.7, mix: 0.45]]
          ] ++ opts
        )

      descend(audio, depth)
      audio
    end
  end

  @doc """
  Switch the ambience to `depth`'s bed, replacing whatever is playing.

  The score starts immediately while the rendered bed is built off to the side and cached on
  disk, so only the first visit to a depth pays the rendering cost.
  """
  @spec descend(t(), pos_integer()) :: :ok
  def descend(nil, _depth), do: :ok

  def descend(audio, depth) do
    Audio.play_piece(audio, "scriber/stratum-#{depth}", Ambience.score(depth),
      render: fn -> Ambience.loop(depth) end,
      fingerprint: Cache.fingerprint(Ambience)
    )

    :ok
  end

  @doc "Silence all audio when `muted?` is true, restore it when false."
  @spec mute(t(), boolean()) :: :ok
  def mute(nil, _muted?), do: :ok
  def mute(audio, muted?), do: Audio.mute(audio, muted?)

  @doc "Set the ambience volume. `gain` runs from 0.0 (silent) to 1.0 (full)."
  @spec level(t(), number()) :: :ok
  def level(nil, _gain), do: :ok
  def level(audio, gain), do: Audio.levels(audio, 0.0, gain)

  @doc "Whether the instance has a stage with somewhere to play."
  @spec on?(t()) :: boolean()
  def on?(nil), do: false
  def on?(audio), do: Audio.on?(audio)

  @doc "Stop the instance and its stage."
  @spec stop(t()) :: :ok
  def stop(nil), do: :ok
  def stop(audio), do: if(Process.alive?(audio), do: GenServer.stop(audio), else: :ok)

  defp voice(_event), do: nil

  defp enabled?, do: System.get_env("SCRIBER_QUIET") in [nil, ""]
end
