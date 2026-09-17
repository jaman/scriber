defmodule Scriber.MixProject do
  use Mix.Project

  @version "0.1.0"
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
      deps: deps()
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
      {:cauldron_2d, path: "../cauldron/cauldron_2d"},
      {:cauldron_2d_drafter, path: "../cauldron/cauldron_2d_drafter"},
      {:drafter, path: "../drafter"},
      {:tuning_fork, path: "../tuning_fork/tuning_fork"},
      {:tuning_fork_speaker, path: "../tuning_fork/tuning_fork_speaker"},
      {:french_curve, path: "../french_curve", override: true}
    ]
  end
end
