defmodule Scriber.Renderer do
  @moduledoc """
  How the map is drawn, layered over `Cauldron2D.Renderer`.

  Two settings select a rendering mode, in order of precedence:

    1. the `SCRIBER_MODE` environment variable
    2. `config :scriber, :mode`

  Either may be `pixel`, `text`, or the name of a specific pixel protocol. When neither is
  set the engine resolves the mode itself from `CAULDRON_MODE`, its own config, and the terminal's
  capabilities.

  ## Example

      System.put_env("SCRIBER_MODE", "text")
      Scriber.Renderer.mode()
      #=> :text
  """

  @doc """
  The mode selected by `SCRIBER_MODE` or `config :scriber, :mode`.

  Returns `nil` when neither is set, or when `config :scriber, :mode` holds a non-atom, which
  leaves the mode for the engine to resolve. Every other function in this module passes this
  value to `Cauldron2D.Renderer`.
  """
  @spec override() :: atom() | nil
  def override do
    Cauldron2D.Renderer.parse(System.get_env("SCRIBER_MODE")) || configured()
  end

  defp configured do
    case Application.get_env(:scriber, :mode) do
      mode when is_atom(mode) and not is_nil(mode) -> mode
      _other -> nil
    end
  end

  @doc "Whether the map is drawn as an image (`:pixel`) or as characters (`:text`)."
  @spec mode() :: :pixel | :text
  def mode, do: Cauldron2D.Renderer.mode(override())

  @doc "The pixel protocol the map is drawn with, or `nil` in text mode."
  @spec protocol() :: atom() | nil
  def protocol, do: Cauldron2D.Renderer.protocol(override())

  @doc "A one-line description of the resolved mode and protocol, for the status bar."
  @spec describe() :: String.t()
  def describe, do: Cauldron2D.Renderer.describe(override())
end
