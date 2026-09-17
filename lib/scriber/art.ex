defmodule Scriber.Art do
  @moduledoc """
  The game's tile art, drawn in code, and the `Cauldron2D.Atlas` it is installed into.

  Every tile is a 16×16 RGBA raster built from `FrenchCurve.Draw` primitives; no image is
  decoded and no asset ships with the game.

  Each entry carries three renderings of the same thing, so text and pixel modes cannot
  drift: the raster, a two-column glyph, and an RGB colour. The glyph is two columns wide
  because one tile occupies two terminal cells.

  Terrain rasters (`:rock`, `:wall`, `:floor`, `:door`, `:console`, `:gate`, `:stair`) fill
  their tile opaquely. Everything that stands on terrain — the player, monsters, items — is
  drawn on a transparent background so `Cauldron2D.Surface` composites it over whichever
  floor it is standing on.

  The atlas also carries a `:dim` tint, applied by the renderer to remembered but unlit
  tiles.

  ## Example

      Scriber.Art.install()
      #=> :scriber
  """

  alias Cauldron2D.Atlas
  alias FrenchCurve.{Draw, Raster}

  @tile 16
  @name :scriber
  @void {6, 7, 11}

  @catalogue [
    {:rock, "  ", {6, 7, 11}},
    {:wall, "▓▓", {90, 98, 128}},
    {:floor, "· ", {60, 66, 88}},
    {:door, "++", {200, 170, 90}},
    {:console, "[]", {70, 220, 190}},
    {:gate, "##", {225, 80, 90}},
    {:stair, ">>", {120, 255, 210}},
    {:scriber, "@ ", {245, 235, 200}},
    {:mite, "m ", {150, 200, 120}},
    {:husk, "h ", {190, 160, 110}},
    {:sentry, "S ", {120, 180, 235}},
    {:daemon, "D ", {235, 110, 130}},
    {:shard, "◈ ", {90, 215, 235}},
    {:patch, "+ ", {235, 240, 245}},
    {:probe, "/ ", {230, 210, 120}}
  ]

  @doc "The atlas name `install/0` registers under and every caller refers to."
  @spec name() :: atom()
  def name, do: @name

  @doc "Every art name in the catalogue, in drawing order."
  @spec arts() :: [atom()]
  def arts, do: Enum.map(@catalogue, &elem(&1, 0))

  @doc """
  Draw every tile in the catalogue and install the atlas, returning `name/0`.

  Installation is per-VM and idempotent: a second call finds the atlas already installed and
  draws nothing. Must be called before any surface using this atlas is rendered.
  """
  @spec install() :: atom()
  def install do
    if Atlas.installed?(@name) do
      @name
    else
      @catalogue
      |> Enum.reduce(Atlas.new(@name, tile: @tile, void: @void), fn {art, glyph, color}, atlas ->
        Atlas.put(atlas, art, raster(art), glyph: glyph, color: color)
      end)
      |> Atlas.tint(:dim, &dim/1)
      |> Atlas.install()
    end
  end

  @doc """
  The `:dim` tint: one pixel darkened and shifted towards blue.

  Scales red by 0.30, green by 0.32 and blue by 0.42, leaving alpha untouched.
  """
  @spec dim(Atlas.rgba()) :: Atlas.rgba()
  def dim({r, g, b, a}), do: {round(r * 0.30), round(g * 0.32), round(b * 0.42), a}

  defp raster(:rock) do
    tile({10, 11, 16, 255})
  end

  defp raster(:floor) do
    {13, 15, 22, 255}
    |> tile()
    |> Draw.fill_rect({1, 1}, {@tile - 2, @tile - 2}, {40, 45, 62, 255})
    |> speckle([{3, 4}, {11, 6}, {6, 12}, {13, 13}], {56, 62, 84, 255})
  end

  defp raster(:wall) do
    {22, 25, 36, 255}
    |> tile()
    |> Draw.fill_rect({1, 1}, {@tile - 2, @tile - 2}, {88, 96, 124, 255})
    |> Draw.line({1, 1}, {@tile - 2, 1}, {126, 136, 170, 255})
    |> Draw.line({1, 1}, {1, @tile - 2}, {112, 122, 155, 255})
    |> Draw.line({@tile - 2, 2}, {@tile - 2, @tile - 2}, {54, 59, 80, 255})
    |> Draw.line({2, @tile - 2}, {@tile - 2, @tile - 2}, {54, 59, 80, 255})
    |> Draw.line({1, 8}, {@tile - 2, 8}, {66, 72, 96, 255})
  end

  defp raster(:door) do
    raster(:floor)
    |> Draw.fill_rect({3, 1}, {12, 14}, {96, 68, 40, 255})
    |> Draw.rect({3, 1}, {12, 14}, {140, 102, 60, 255})
    |> Draw.fill_rect({7, 7}, {8, 9}, {200, 170, 90, 255})
  end

  defp raster(:console) do
    raster(:floor)
    |> Draw.fill_rect({2, 3}, {13, 11}, {40, 44, 58, 255})
    |> Draw.rect({2, 3}, {13, 11}, {88, 96, 120, 255})
    |> Draw.fill_rect({4, 5}, {11, 9}, {24, 90, 80, 255})
    |> scanlines(5, 9, {70, 220, 190, 255})
    |> Draw.fill_rect({5, 13}, {10, 14}, {58, 63, 82, 255})
  end

  defp raster(:gate) do
    {14, 10, 14, 255}
    |> tile()
    |> Draw.fill_rect({1, 1}, {@tile - 2, @tile - 2}, {58, 30, 38, 255})
    |> bars({120, 46, 56, 255})
    |> Draw.fill_rect({6, 6}, {9, 9}, {210, 70, 80, 255})
    |> Draw.fill_rect({7, 7}, {8, 8}, {255, 160, 150, 255})
  end

  defp raster(:stair) do
    {6, 8, 10, 255}
    |> tile()
    |> chevrons({40, 180, 140, 255})
    |> Draw.fill_rect({6, 12}, {9, 13}, {120, 255, 210, 255})
  end

  defp raster(:scriber) do
    overlay()
    |> Draw.fill_circle({8, 5}, 3, {245, 232, 200, 255})
    |> Draw.fill_rect({6, 8}, {9, 13}, {225, 205, 165, 255})
    |> Draw.line({5, 9}, {3, 12}, {225, 205, 165, 255})
    |> Draw.line({10, 9}, {13, 11}, {225, 205, 165, 255})
    |> Draw.line({6, 14}, {5, 15}, {200, 180, 145, 255})
    |> Draw.line({9, 14}, {10, 15}, {200, 180, 145, 255})
    |> Draw.fill_rect({12, 8}, {13, 12}, {120, 230, 255, 255})
  end

  defp raster(:mite) do
    overlay()
    |> Draw.fill_circle({8, 10}, 4, {120, 190, 95, 255})
    |> Draw.fill_circle({8, 8}, 2, {160, 225, 130, 255})
    |> legs({70, 130, 60, 255})
    |> Raster.put_pixel(6, 8, {20, 30, 20, 255})
    |> Raster.put_pixel(10, 8, {20, 30, 20, 255})
  end

  defp raster(:husk) do
    overlay()
    |> Draw.fill_rect({5, 6}, {10, 14}, {170, 140, 95, 255})
    |> Draw.fill_circle({8, 5}, 3, {195, 165, 115, 255})
    |> Draw.line({4, 8}, {4, 13}, {140, 112, 74, 255})
    |> Draw.line({11, 8}, {11, 13}, {140, 112, 74, 255})
    |> Raster.put_pixel(6, 5, {60, 40, 25, 255})
    |> Raster.put_pixel(9, 5, {60, 40, 25, 255})
  end

  defp raster(:sentry) do
    overlay()
    |> Draw.fill_rect({4, 7}, {11, 15}, {70, 120, 175, 255})
    |> Draw.fill_rect({5, 4}, {10, 7}, {95, 155, 215, 255})
    |> Draw.rect({4, 7}, {11, 15}, {135, 190, 240, 255})
    |> Draw.fill_rect({6, 5}, {9, 6}, {255, 235, 140, 255})
    |> Draw.line({4, 10}, {11, 10}, {45, 85, 130, 255})
  end

  defp raster(:daemon) do
    overlay()
    |> Draw.fill_rect({5, 6}, {10, 15}, {180, 55, 75, 255})
    |> Draw.fill_circle({8, 5}, 3, {215, 75, 95, 255})
    |> Draw.line({4, 2}, {6, 4}, {230, 120, 130, 255})
    |> Draw.line({11, 2}, {9, 4}, {230, 120, 130, 255})
    |> Draw.line({4, 8}, {2, 13}, {180, 55, 75, 255})
    |> Draw.line({11, 8}, {13, 13}, {180, 55, 75, 255})
    |> Raster.put_pixel(6, 5, {255, 220, 120, 255})
    |> Raster.put_pixel(9, 5, {255, 220, 120, 255})
  end

  defp raster(:shard) do
    overlay()
    |> diamond(8, 9, 4, {90, 215, 235, 255})
    |> diamond(8, 9, 2, {200, 250, 255, 255})
  end

  defp raster(:patch) do
    overlay()
    |> Draw.fill_rect({4, 8}, {11, 11}, {235, 240, 245, 255})
    |> Draw.fill_rect({6, 6}, {9, 13}, {235, 240, 245, 255})
    |> Draw.fill_rect({7, 9}, {8, 10}, {90, 200, 120, 255})
  end

  defp raster(:probe) do
    overlay()
    |> Draw.line({4, 13}, {12, 5}, {230, 210, 120, 255})
    |> Draw.line({5, 13}, {13, 5}, {255, 240, 170, 255})
    |> Draw.fill_rect({3, 12}, {5, 14}, {130, 110, 70, 255})
  end

  defp tile(color), do: Raster.new(@tile, @tile, background: color)

  defp overlay, do: Raster.new(@tile, @tile)

  defp speckle(raster, points, color) do
    Enum.reduce(points, raster, fn {x, y}, acc -> Raster.put_pixel(acc, x, y, color) end)
  end

  defp scanlines(raster, top, bottom, color) do
    Enum.reduce(top..bottom//2, raster, fn y, acc -> Draw.line(acc, {5, y}, {10, y}, color) end)
  end

  defp bars(raster, color) do
    Enum.reduce([3, 7, 11], raster, fn x, acc ->
      Draw.fill_rect(acc, {x, 1}, {x + 1, @tile - 2}, color)
    end)
  end

  defp chevrons(raster, color) do
    Enum.reduce([2, 6, 10], raster, fn y, acc ->
      acc
      |> Draw.line({3, y}, {8, y + 3}, color)
      |> Draw.line({8, y + 3}, {12, y}, color)
    end)
  end

  defp legs(raster, color) do
    Enum.reduce([{4, 11}, {12, 11}, {5, 13}, {11, 13}], raster, fn {x, y}, acc ->
      Draw.line(acc, {8, 10}, {x, y}, color)
    end)
  end

  defp diamond(raster, cx, cy, radius, color) do
    Enum.reduce(-radius..radius//1, raster, fn dy, acc ->
      span = radius - abs(dy)
      Draw.line(acc, {cx - span, cy + dy}, {cx + span, cy + dy}, color)
    end)
  end
end
