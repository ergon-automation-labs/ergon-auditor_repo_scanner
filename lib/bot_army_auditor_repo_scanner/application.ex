defmodule BotArmyAuditorRepoScanner.Application do
  @moduledoc """
  Repo Scanner Bot application supervisor.

  Follows bot army pattern with environment-aware startup:
  - Repo not started in :test (tests inject mocks)
  - PulsePublisher sends `system.health` liveness every 30s and rich `bot.<service>.pulse` every 30 minutes
  - Workers not started in :test (gated by @env)

  Observability: see `PulsePublisher` — fleet UIs keyed on Synapse hydration should use `system.health` freshness (90s), not pulse interval alone.
  """

  use Application

  @env Mix.env()

  @impl true
  def start(_type, _args) do
    # Note: BotArmyLibraryRuntime.Telemetry and BotArmyLibraryRuntime.NATS.Connection are started
    # by bot_army_runtime automatically — do not add them here.

    children =
      []
      |> maybe_add_repo()
      |> maybe_add_pulse_publisher()
      |> maybe_add_consumer()
      |> maybe_add_workers()

    opts = [strategy: :one_for_one, name: BotArmyAuditorRepoScanner.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # No Repo module yet: DB wiring (repo module, config, migrations) lands with
  # the measurement-schema implementation. Starting the nonexistent Repo
  # module here crash-looped the supervisor at boot.
  defp maybe_add_repo(children) do
    children
  end

  defp maybe_add_pulse_publisher(children) do
    if @env == :test do
      children
    else
      [{BotArmyAuditorRepoScanner.PulsePublisher, []} | children]
    end
  end

  defp maybe_add_consumer(children) do
    if @env == :test, do: children, else: [{BotArmyAuditorRepoScanner.NATS.Consumer, []} | children]
  end

  defp maybe_add_workers(children) do
    if @env == :test do
      children
    else
      # Bot-specific workers and pollers go here (GenServers that do async work)
      # Examples: Scheduler, Poller, Watcher
      # Pattern: gated with if @env == :test to prevent long-running processes in test
      children
    end
  end
end
