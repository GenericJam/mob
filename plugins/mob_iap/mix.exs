defmodule MobIap.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/earendil-works/mob"

  def project do
    [
      app: :mob_iap,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      source_url: @source_url,
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets]
    ]
  end

  defp deps do
    [
      {:mob, "~> 0.6", path: "../.."},
      {:jason, "~> 1.4"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      description: "In-App Purchase plugin for Mob (StoreKit 2 + Play Billing 7)",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md)
    ]
  end
end
