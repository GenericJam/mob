defmodule Mob.MixProject do
  use Mix.Project

  def project do
    [
      app: :mob,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "BEAM-on-device mobile framework for Elixir",
      source_url: "https://github.com/genericjam/mob",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/genericjam/mob"}
    ]
  end

  defp deps do
    [
      # HTML/HEEx template engine — same one Phoenix uses
      # {:phoenix_live_view, "~> 1.0", optional: true},  # add when HEEx rendering lands
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
