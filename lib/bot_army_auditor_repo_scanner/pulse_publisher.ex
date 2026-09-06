defmodule BotArmyAuditorRepoScanner.PulsePublisher do
  @moduledoc """
  Periodic health publisher for Repo Scanner Bot.

  Two channels, aligned with `docs/SYNAPSE_CONTEXT_HYDRATION_CONTRACT.md`:

  1. **`system.health`** — lightweight liveness envelope every 30s so Synapse
     fleet views (90s staleness) stay **online** when the bot is running.
  2. **`bot.auditor_repo_scanner.pulse`** — richer metrics every 30 minutes (lower NATS volume).

  Health signal rules (`health_signal/0` → pulse + heartbeat status):

  - `:nominal` — healthy
  - `:degraded` — minor issues or zero activity
  - `:critical` — errors or operational issues

  Customize `record_metric/2` and `health_signal/0` for domain-specific logic.
  """

  use GenServer
  require Logger

  # Under Synapse `system.health` stale window (90s); 30s cadence leaves margin for jitter.
  @health_interval_ms 30 * 1000
  @publish_interval_ms 30 * 60 * 1000
  @service_name "auditor_repo_scanner"
  @envelope_source "bot_army_auditor_repo_scanner"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("[PulsePublisher] Starting Repo Scanner Bot pulse publisher")
    started_at = DateTime.utc_now() |> DateTime.truncate(:second)
    send(self(), :publish_health)
    send(self(), :publish_pulse)
    {:ok, %{started_at: started_at}}
  end

  @impl true
  def handle_info(:publish_health, state) do
    Task.start(fn -> publish_system_health(state) end)
    Process.send_after(self(), :publish_health, @health_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:publish_pulse, state) do
    Task.start(fn -> publish_pulse() end)
    Process.send_after(self(), :publish_pulse, @publish_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:record_metric, _key, _value}, state) do
    # TODO: Track metric in state for next pulse publish
    {:noreply, state}
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp publish_pulse do
    signal = health_signal()

    pulse = %{
      service: @service_name,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      health: signal,
      # TODO: Add domain-specific metrics here
      # Examples: active_sessions, items_processed, errors_in_window
      metrics: %{}
    }

    case BotArmyRuntime.NATS.Publisher.publish("bot.#{@service_name}.pulse", pulse) do
      {:ok, _} ->
        Logger.debug("[PulsePublisher] Published pulse: #{signal}")

      {:error, reason} ->
        Logger.warning("[PulsePublisher] Failed to publish pulse: #{inspect(reason)}")
    end
  end

  defp publish_system_health(%{started_at: started_at}) do
    tenant_id = System.get_env("BOT_ARMY_TENANT_ID") || BotArmyRuntime.Tenant.default_tenant_id()
    signal = health_signal()
    uptime_seconds = DateTime.diff(DateTime.utc_now() |> DateTime.truncate(:second), started_at, :second)

    case BotArmyRuntime.SynapseHealth.publish(
           source_node: node() |> Atom.to_string(),
           triggered_by: @envelope_source,
           service: @service_name,
           tenant_id: tenant_id,
           health_signal: signal,
           uptime_seconds: max(uptime_seconds, 0)
         ) do
      {:ok, _} ->
        Logger.debug("[PulsePublisher] Published system.health: #{signal}")

      {:error, reason} ->
        Logger.warning("[PulsePublisher] Failed to publish system.health: #{inspect(reason)}")
    end
  end

  defp health_signal do
    # TODO: Implement health signal logic based on domain metrics
    # Examples:
    #   - Return :critical if error_count > threshold
    #   - Return :degraded if activity_count == 0
    #   - Return :nominal otherwise
    :nominal
  end
end
