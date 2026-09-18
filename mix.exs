defmodule Scriber.MixProject do
  use Mix.Project

  @version "0.1.2"
  @source_url "https://github.com/jaman/scriber"
  @description "A roguelike drawn in real pixels, with a console inside it, on Cauldron."

  def project do
    [
      app: :scriber,
      version: @version,
      elixir: "~> 1.18",
      description: @description,
      start_permanent: Mix.env() == :prod,
      elixirc_options: [warnings_as_errors: true],
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      name: "Scriber",
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      family(:cauldron_2d, "~> 0.1.3", "../cauldron/cauldron_2d", []),
      family(:cauldron_2d_drafter, "~> 0.1.3", "../cauldron/cauldron_2d_drafter", []),
      family(:drafter, "~> 0.4.0", "../drafter", []),
      family(:tuning_fork, "~> 0.1.11", "../tuning_fork/tuning_fork", []),
      family(:tuning_fork_speaker, "~> 0.1.11", "../tuning_fork/tuning_fork_speaker", []),
      family(:french_curve, "~> 0.1.4", "../french_curve", override: true)
    ]
  end

  defp family(app, requirement, path, opts) do
    if System.get_env("PLUMB_HEX") == nil and File.dir?(path),
      do: {app, [path: path] ++ opts},
      else: {app, requirement, Keyword.delete(opts, :override)}
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md TECHNICAL.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url_pattern: "#{@source_url}/blob/v#{@version}/%{path}#L%{line}",
      extras: ["README.md", "TECHNICAL.md"]
    ]
  end
end
