defmodule Scriber.Sound do
  @moduledoc """
  The game's audio: a `Cauldron2D.Audio` instance of the application's own, the ambience
  bed switched as the player descends, and the voice of every event `Scriber.Game` emits.

  Playback, mixing and caching are `Cauldron2D.Audio`'s; the beds themselves are
  `Scriber.Ambience`'s. What lives here is which bed belongs to which stratum, and what
  each event sounds like: footsteps, a creature's step and chatter and cry where it
  stands, the hit of each weapon on each kind of creature, misses, parries, stuns, deaths,
  pickups, the gate, the drop.

  Events placed with a position are played against the player's position by the audio
  instance, fading with distance and panned by side; `play/3` sets the listener and
  plays a frame's events in one go.

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
  alias TuningFork.{Cache, Envelope, Voice}

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
            earshot: 14.0,
            fx: [reverb: [room: 0.8, damp: 0.7, mix: 0.22]]
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

  @doc "Set where the player stands and sound the frame's events."
  @spec play(t(), {integer(), integer()}, [term()]) :: :ok
  def play(nil, _at, _events), do: :ok

  def play(audio, at, events) do
    Audio.listener(audio, at)
    Audio.play(audio, Enum.map(events, &placed/1))
  end

  defp placed({:step, kind, pos}), do: {{:step, kind}, pos}
  defp placed({:noticed, kind, pos}), do: {{:noticed, kind}, pos}
  defp placed({:chatter, kind, pos}), do: {{:chatter, kind}, pos}
  defp placed({:miss, kind, pos}), do: {{:miss, kind}, pos}
  defp placed({:stunned, kind, pos}), do: {{:stunned, kind}, pos}
  defp placed({:died, kind, pos}), do: {{:died, kind}, pos}
  defp placed({:hit, weapon, kind, pos}), do: {{:hit, weapon, kind}, pos}
  defp placed({:fuse, pos}), do: {:fuse, pos}
  defp placed({:decoy, pos}), do: {:decoy, pos}
  defp placed({:unsealed, pos}), do: {:unsealed, pos}
  defp placed({:hurt, amount}), do: {:hurt, amount}
  defp placed(event), do: event

  @doc "What an event sounds like: a voice, a run of `{delay_ms, voice}`, or `nil` for silence."
  @spec voice(term()) :: Cauldron2D.Audio.sound()
  def voice({:step, :scriber}), do: tone(:triangle, 160.0, 0.9, 0.05, 0.16)

  def voice({:step, :mite}),
    do: Voice.new(shape: :noise, cutoff: 0.6, envelope: Envelope.hit(0.03), gain: 0.14)

  def voice({:step, :husk}), do: tone(:sine, 55.0, 0.7, 0.14, 0.38)
  def voice({:step, :sentry}), do: nil

  def voice({:step, :daemon}),
    do: [{0, tone(:sine, 48.0, 0.8, 0.12, 0.5)}, {140, tone(:sine, 44.0, 0.8, 0.12, 0.42)}]

  def voice({:noticed, :mite}), do: run([1200.0, 1500.0, 1800.0], :square, 0.05, 0.2, 40)
  def voice({:noticed, :husk}), do: tone(:saw, 90.0, 0.6, 0.6, 0.4)
  def voice({:noticed, :sentry}), do: run([880.0, 1320.0], :sine, 0.25, 0.3, 120)

  def voice({:noticed, :daemon}),
    do:
      Voice.new(
        shape: :saw,
        freq: 70.0,
        sweep: 0.5,
        envelope: Envelope.hit(0.9),
        gain: 0.55,
        distort: 0.6
      )

  def voice({:chatter, :mite}), do: run([1400.0, 1700.0], :square, 0.04, 0.12, 60)
  def voice({:chatter, :husk}), do: tone(:saw, 75.0, 0.8, 0.5, 0.22)
  def voice({:chatter, :sentry}), do: tone(:sine, 1100.0, 1.0, 0.08, 0.16)

  def voice({:chatter, :daemon}),
    do:
      Voice.new(
        shape: :triangle,
        freq: 62.0,
        sweep: 1.3,
        envelope: Envelope.hit(0.7),
        gain: 0.3,
        vib: 5.0,
        vibmod: 1.5
      )

  def voice({:hit, weapon, kind}), do: [{0, swing(weapon)}, {30, flesh(kind)}]

  def voice({:miss, :scriber}),
    do: Voice.new(shape: :noise, cutoff: 0.35, envelope: Envelope.hit(0.12), gain: 0.2)

  def voice({:miss, _kind}),
    do: Voice.new(shape: :noise, cutoff: 0.5, envelope: Envelope.hit(0.1), gain: 0.18)

  def voice({:hurt, amount}), do: tone(:sine, 130.0 - min(amount, 15) * 4.0, 0.5, 0.25, 0.5)
  def voice(:parry), do: tone(:triangle, 1800.0, 1.4, 0.18, 0.35)

  def voice({:stunned, _kind}),
    do:
      Voice.new(
        shape: :sine,
        freq: 400.0,
        sweep: 0.6,
        envelope: Envelope.hit(0.4),
        gain: 0.3,
        vib: 9.0,
        vibmod: 3.0
      )

  def voice({:died, kind}),
    do: [
      {0, flesh(kind)},
      {60, Voice.new(shape: :noise, cutoff: 0.3, envelope: Envelope.hit(0.5), gain: 0.35)},
      {80, tone(:saw, 300.0, 0.15, 0.6, 0.3)}
    ]

  def voice({:pickup, :shard}), do: run([1568.0, 2093.0], :sine, 0.12, 0.3, 50)
  def voice({:pickup, :patch}), do: tone(:sine, 660.0, 1.5, 0.3, 0.3)

  def voice({:pickup, :fragment}),
    do: run([784.0, 988.0, 1175.0, 1568.0], :triangle, 0.15, 0.3, 70)

  def voice({:pickup, _tool}), do: tone(:square, 520.0, 1.2, 0.12, 0.22)
  def voice(:patch), do: tone(:sine, 440.0, 2.0, 0.6, 0.3)
  def voice(:refused), do: tone(:square, 220.0, 0.9, 0.08, 0.2)

  def voice(:door),
    do: Voice.new(shape: :noise, cutoff: 0.15, envelope: Envelope.hit(0.35), gain: 0.3)

  def voice(:console), do: run([1046.5, 1318.5, 1568.0], :square, 0.06, 0.18, 50)

  def voice(:unsealed),
    do: [
      {0, Voice.new(shape: :noise, cutoff: 0.08, envelope: Envelope.hit(1.6), gain: 0.5)},
      {0, tone(:saw, 40.0, 1.6, 1.6, 0.4)}
    ]

  def voice({:descended, _depth}), do: tone(:sine, 300.0, 0.25, 0.8, 0.4)

  def voice(:fuse),
    do: [
      {0, Voice.new(shape: :noise, cutoff: 0.9, envelope: Envelope.hit(0.25), gain: 0.6)},
      {0, tone(:sine, 90.0, 0.4, 0.4, 0.5)}
    ]

  def voice(:decoy), do: run([900.0, 1100.0, 900.0], :square, 0.05, 0.12, 90)

  def voice(:pulse),
    do: Voice.new(shape: :sine, freq: 200.0, sweep: 4.0, envelope: Envelope.hit(0.5), gain: 0.5)

  def voice(_event), do: nil

  defp swing(:unarmed), do: tone(:sine, 140.0, 0.6, 0.08, 0.35)

  defp swing(:two_hand),
    do: Voice.new(shape: :noise, cutoff: 0.25, envelope: Envelope.hit(0.2), gain: 0.5)

  defp swing(:shield), do: tone(:triangle, 1400.0, 1.2, 0.2, 0.35)

  defp swing(:daggers),
    do: Voice.new(shape: :noise, cutoff: 0.7, envelope: Envelope.hit(0.05), gain: 0.3)

  defp swing(:mace), do: tone(:square, 110.0, 0.5, 0.15, 0.45)

  defp flesh(:mite),
    do: Voice.new(shape: :noise, cutoff: 0.5, envelope: Envelope.hit(0.08), gain: 0.35)

  defp flesh(:husk),
    do: Voice.new(shape: :noise, cutoff: 0.2, envelope: Envelope.hit(0.18), gain: 0.4)

  defp flesh(:sentry), do: tone(:square, 1200.0, 0.8, 0.15, 0.3)

  defp flesh(:daemon),
    do:
      Voice.new(
        shape: :saw,
        freq: 180.0,
        sweep: 0.5,
        envelope: Envelope.hit(0.25),
        gain: 0.4,
        distort: 0.5
      )

  defp flesh(_kind), do: nil

  defp tone(shape, freq, sweep, decay, gain),
    do:
      Voice.new(shape: shape, freq: freq, sweep: sweep, envelope: Envelope.hit(decay), gain: gain)

  defp run(freqs, shape, decay, gain, gap) do
    freqs
    |> Enum.with_index()
    |> Enum.map(fn {freq, index} -> {index * gap, tone(shape, freq, 1.0, decay, gain)} end)
  end

  defp enabled?, do: System.get_env("SCRIBER_QUIET") in [nil, ""]
end
