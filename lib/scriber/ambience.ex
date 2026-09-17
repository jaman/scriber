defmodule Scriber.Ambience do
  @moduledoc """
  The dungeon ambience bed: a seeded, loopable drone for one depth.

  Three parts play at once: two held tones a fifth apart, a slow breath of filtered noise,
  and occasional distant drips and rumbles placed by chance. The random placement is seeded
  from the depth, so a given depth always sounds the same.

  Depth darkens the bed. Deeper levels lower the drone's root, raise the breath's gain, and
  make the distant sounds more frequent. The darkening saturates: beyond depth 8 the bed
  stops changing.

  `duration/0` gives the bed's length in seconds; rendering one with `loop/2` takes far
  longer than playing the score with `score/2` does to start.

  ## Example

      Scriber.Ambience.score(3, 1.0)
      Scriber.Ambience.loop(3, 0.8)
  """

  import TuningFork.Part

  alias TuningFork.{Envelope, Mixer, Notes, Score, Voice}

  @rate 44_100
  @bpm 40
  @bars 12
  @bar 4

  @loudness 1_500

  @doc """
  The bed for `depth` rendered to PCM and normalised to a fixed quiet loudness.

  `gain` scales every part before rendering. Rendering is expensive — far longer than the
  bed's own `duration/0` — so callers should cache the result rather than render per descent.
  """
  @spec loop(pos_integer(), float()) :: binary()
  def loop(depth \\ 1, gain \\ 1.0) do
    depth
    |> score(gain)
    |> Score.render(@rate)
    |> Mixer.normalise(@loudness)
  end

  @doc """
  The same bed as `loop/2`, as an unrendered `TuningFork.Score` for live playback.

  `gain` scales every part. Playing this starts immediately where `loop/2` must synthesise
  first, at the cost of the loudness normalisation `loop/2` applies; the playing stage's own
  reverb stands in for the per-part rooms.
  """
  @spec score(pos_integer(), float()) :: Score.t()
  def score(depth \\ 1, gain \\ 1.0) do
    dark = min((depth - 1) * 0.1, 0.7)
    seed = 9_001 + depth

    Score.from_parts([drone(dark, gain), breath(dark, gain, seed), far(dark, gain, seed)],
      beats: @bars * @bar
    )
  end

  @doc "How long the bed runs, in seconds. The same for every depth."
  @spec duration() :: float()
  def duration, do: @bars * @bar * 60.0 / @bpm

  defp drone(dark, gain) do
    root = Notes.name_of(Notes.semitone(:d1) + trunc((1.0 - dark) * 5))

    part(
      bpm: @bpm,
      synth: drone_voice(),
      gain: gain,
      fx: [reverb: [room: 0.9, damp: 0.7, mix: 0.35]]
    )
    |> repeat(div(@bars, 2), fn line ->
      line
      |> under(root, gain: 0.9)
      |> play(Notes.name_of(Notes.semitone(root) + 7), 2 * @bar, gain: 0.55)
    end)
  end

  defp breath(dark, gain, seed) do
    part(bpm: @bpm, synth: air(), gain: gain, seed: seed)
    |> repeat(@bars, fn line ->
      line
      |> maybe(0.7, &play(&1, :d2, 0.0, gain: {:between, 0.4, 1.0}))
      |> rest(@bar)
    end)
    |> then(fn line -> if dark > 0.4, do: gain(line, 1.3), else: line end)
  end

  defp far(dark, gain, seed) do
    part(
      bpm: @bpm,
      gain: gain,
      seed: seed + 1,
      fx: [reverb: [room: 0.97, damp: 0.75, mix: 0.6]]
    )
    |> repeat(round(@bars * @bar / 0.7), fn line ->
      line
      |> maybe(0.09 + dark * 0.05, fn drop ->
        drop
        |> synth(drip())
        |> play_any([:a5, :c6, :d6, :e6, :g6], 0.0, gain: {:between, 0.15, 0.5})
      end)
      |> maybe(0.03 + dark * 0.04, fn hit ->
        hit |> synth(rumble()) |> play_any([:c2, :d2, :ds2, :g1], 0.0, gain: {:between, 0.3, 0.8})
      end)
      |> rest(0.7)
    end)
  end

  defp drone_voice do
    Voice.new(
      shape: :triangle,
      cutoff: 0.03,
      envelope: Envelope.new(attack: 2.5, decay: 3.0, sustain: 0.5, hold: 4.0, release: 3.0),
      gain: 0.28
    )
  end

  defp air do
    Voice.new(
      shape: :noise,
      cutoff: 0.004,
      envelope: Envelope.new(attack: 2.0, decay: 2.5, sustain: 0.0, release: 1.5),
      gain: 0.16
    )
  end

  defp drip do
    Voice.new(
      shape: :sine,
      sweep: 0.94,
      envelope: Envelope.new(attack: 0.001, decay: 0.10, sustain: 0.0, release: 0.05),
      gain: 0.10
    )
  end

  defp rumble do
    Voice.new(
      shape: :noise,
      cutoff: 0.02,
      envelope: Envelope.new(attack: 0.6, decay: 1.8, sustain: 0.0, release: 1.0),
      gain: 0.22
    )
  end
end
