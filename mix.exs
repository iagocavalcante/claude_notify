defmodule ClaudeNotify.MixProject do
  use Mix.Project

  def project do
    [
      app: :claude_notify,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ClaudeNotify.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:dotenvy, "~> 0.8"}
    ]
  end
end
