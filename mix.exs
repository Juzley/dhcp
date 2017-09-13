defmodule Dhcp.Mixfile do
  use Mix.Project

  def project do
    [
      app: :dhcp,
      version: "0.1.0",
      elixir: "~> 1.5",
      elixirc_paths: elixirc_paths(Mix.env),
      start_permanent: Mix.env == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :timex],
      mod: {Dhcp, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/mocks", "test/packets"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:pkt, github: "msantos/pkt", tag: "0.4.4"},
      {:procket, github: "msantos/procket", tag: "0.8.0"},
      {:timex, "~> 3.1"}
    ]
  end

  defp aliases do
    [
      test: "test --no-start"
    ]
  end
end
