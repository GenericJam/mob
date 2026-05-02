defmodule Mob.MixProject do
  use Mix.Project

  def project do
    [
      app: :mob,
      version: "0.5.14",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: "BEAM-on-device mobile framework for Elixir",
      source_url: "https://github.com/genericjam/mob",
      homepage_url: "https://hexdocs.pm/mob",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/logo/logo_full_color.png",
      source_url: "https://github.com/genericjam/mob",
      source_url_pattern: "https://github.com/genericjam/mob/blob/main/%{path}#L%{line}",
      extras: [
        "README.md": [title: "Mob"],
        "guides/why_beam.md": [title: "Why the BEAM?"],
        "guides/getting_started.md": [title: "Getting Started"],
        "guides/architecture.md": [title: "Architecture & Prior Art"],
        "guides/screen_lifecycle.md": [title: "Screen Lifecycle"],
        "guides/components.md": [title: "Components"],
        "guides/styling.md": [title: "Styling & Native Rendering"],
        "guides/theming.md": [title: "Theming"],
        "guides/navigation.md": [title: "Navigation"],
        "guides/device_capabilities.md": [title: "Device Capabilities"],
        "guides/data.md": [title: "Data & Persistence"],
        "guides/testing.md": [title: "Testing"],
        "guides/publishing.md": [title: "Publishing to App Store / TestFlight"],
        "guides/troubleshooting.md": [title: "Troubleshooting"],
        "guides/agentic_coding.md": [title: "Agentic Coding"]
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ],
      groups_for_modules: [
        Core: [Mob, Mob.App, Mob.Screen, Mob.Socket, Mob.State],
        UI: [
          Mob.UI,
          Mob.Style,
          Mob.Renderer,
          Mob.Theme,
          Mob.Theme.Obsidian,
          Mob.Theme.Citrus,
          Mob.Theme.Birch
        ],
        Navigation: [Mob.Nav.Registry],
        "Device APIs": [
          Mob.Haptic,
          Mob.Clipboard,
          Mob.Share,
          Mob.Permissions,
          Mob.Biometric,
          Mob.Location,
          Mob.Camera,
          Mob.Photos,
          Mob.Files,
          Mob.Audio,
          Mob.Motion,
          Mob.Scanner,
          Mob.Notify
        ],
        "Testing & Debugging": [Mob.Test],
        Internals: [Mob.Dist, Mob.NativeLogger, Mob.List, Mob.Sigil]
      ],
      before_closing_body_tag: &before_closing_body_tag/1
    ]
  end

  defp before_closing_body_tag(:html) do
    """
    <script>
      // Ensure code blocks with language hints are highlighted
      document.querySelectorAll("pre code").forEach(el => {
        if (!el.className) el.className = "language-elixir";
      });
    </script>
    """
  end

  defp before_closing_body_tag(_), do: ""

  defp elixirc_paths(:test), do: ["lib", "test/onboarding", "test/onboarding/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/genericjam/mob"},
      files: ~w(
        lib src priv
        android ios assets
        mix.exs mix.lock
        README.md LICENSE
      )
    ]
  end

  defp deps do
    [
      # HTML/HEEx template engine — same one Phoenix uses
      # {:phoenix_live_view, "~> 1.0", optional: true},  # add when HEEx rendering lands
      {:nimble_parsec, "~> 1.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1.0", only: [:dev, :test], runtime: false}
    ]
  end
end
