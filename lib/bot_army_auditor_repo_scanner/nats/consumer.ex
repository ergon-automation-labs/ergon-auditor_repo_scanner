defmodule BotArmyAuditorRepoScanner.NATS.Consumer do
  @moduledoc """
  NATS message consumer for auditor_repo_scanner.

  Serves the bot-contract checklist over request/reply:

    - `auditor.repo.scan` — run the checklist against a repo. Payload:
      `{"repo": "<path-or-name>"}` (bare name resolves against
      AUDITOR_REPO_ROOT, default /repos). Optional `catalog_path` adds the
      catalog-entry check. Replies with the full results map; publishes an
      sre audit receipt (`sre.audit.repo_scanner`, event
      `sre.repo.scan.completed`) on every completed scan regardless of
      verdict, and an sre incident envelope when required checks fail.
    - `auditor.repo.ping` — liveness (used by the provisioned schedule
      trigger to check the fleet is up before scanning).

  Bare payloads (VM `nats request`) are accepted with defaults — the
  conformance-bot leniency pattern. Replies are published directly on
  msg.reply_to.
  """

  use GenServer
  require Logger

  alias BotArmyAuditorRepoScanner.Checklist
  alias BotArmyAuditorRepoScanner.Receipts

  @reconnect_delay_ms 5000
  @version Mix.Project.config()[:version]
  # Re-register every 20s: renews the Registry entry (40s stale sweep) and
  # re-broadcasts presence so peers that booted before us still see us.
  @registry_heartbeat_ms 20_000

  # Register subjects with their metadata for runtime discovery
  @subjects [
    %{subject: "auditor.repo.scan", type: :request_reply,
      description: "Run the bot-contract checklist against a repo (payload: repo path or name)"},
    %{subject: "auditor.repo.ping", type: :request_reply,
      description: "Liveness probe: returns bot name + version"}
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("[RepoScanner] starting NATS consumer")

    state = %{
      subscriptions: [],
      conn: nil,
      opts: opts,
      last_scan: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        BotArmyLibraryRuntime.NATS.Connection.subscribe_to_status()
        Logger.info("[RepoScanner] connected to NATS, subscribing to topics")

        subscriptions =
          [
            "auditor.repo.scan",
            "auditor.repo.ping"
          ]
          |> Enum.map(fn subject ->
            case Gnat.sub(conn, self(), subject) do
              {:ok, sub} ->
                Logger.info("[RepoScanner] subscribed to #{subject}")
                sub

              {:error, reason} ->
                Logger.error("[RepoScanner] failed to subscribe to #{subject}: #{inspect(reason)}")
                nil
            end
          end)
          |> Enum.filter(&(not is_nil(&1)))

        # Register subjects for runtime discovery
        BotArmyLibraryRuntime.Registry.register("auditor_repo_scanner", @subjects, @version)

        Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)

        {:noreply, %{state | subscriptions: subscriptions, conn: conn}}

      {:error, _reason} ->
        Logger.warning("[RepoScanner] NATS connection not ready, will retry")
        Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:registry_heartbeat, state) do
    # Re-register: renews the local entry past the Registry's 40s stale sweep
    # and re-broadcasts presence to peers.
    if state.conn do
      BotArmyLibraryRuntime.Registry.register("auditor_repo_scanner", @subjects, @version)
      Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    BotArmyLibraryRuntime.Tracing.with_consumer_span(msg.topic, Map.get(msg, :headers), fn ->
      handle_message(msg, state)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("[RepoScanner] disconnected from NATS, will reconnect")
    Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
    {:noreply, %{state | subscriptions: [], conn: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("[RepoScanner] reconnected to NATS, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  # ── Message handling ────────────────────────────────────────────────────

  defp handle_message(msg, _state) do
    {message, decode_path} =
      case BotArmyLibraryCore.NATS.Decoder.decode(msg.body) do
        {:ok, decoded} ->
          {decoded, "envelope"}

        {:error, _reason} ->
          # Test-bot leniency: bare payload (e.g. VM `nats request`) → treat
          # the body as the payload map with default options.
          case Jason.decode(msg.body) do
            {:ok, %{} = bare} -> {bare, "bare"}
            {:error, _} -> {%{}, "empty"}
          end
      end

    Logger.info("[RepoScanner] #{msg.topic} (#{decode_path_label(decode_path)})")

    case msg.topic do
      "auditor.repo.scan" ->
        handle_repo_scan(message, msg)

      "auditor.repo.ping" ->
        reply(msg, %{
          "ok" => true,
          "bot" => "auditor_repo_scanner",
          "version" => @version,
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

      other ->
        _ = message
        Logger.debug("[RepoScanner] unknown subject #{other}")
    end
  end

  defp decode_path_label("envelope"), do: "envelope-decoded"
  defp decode_path_label("bare"), do: "bare payload accepted (test-bot leniency)"
  defp decode_path_label("empty"), do: "empty payload (defaults)"

  defp handle_repo_scan(message, msg) do
    repo = repo_param(message)

    opts = [
      root: root(),
      catalog_path: catalog_param(message)
    ]

    Logger.info("[RepoScanner] scan requested for #{inspect(repo)}")

    t0 = System.monotonic_time(:millisecond)

    case Checklist.run(repo, opts) do
      {:ok, results} ->
        duration_ms = System.monotonic_time(:millisecond) - t0
        results = Map.put(results, "duration_ms", duration_ms)

        # Receipts publish regardless of verdict — same pass boundary as
        # conformance. Incidents only when required checks failed.
        Receipts.publish_scan_receipt(results)
        Receipts.publish_failure_incident(results)

        GenServer.cast(__MODULE__, {:store_scan, results})
        if msg.reply_to, do: reply(msg, results)

      {:error, :not_found} ->
        if msg.reply_to,
          do:
            reply(msg, %{
              "ok" => false,
              "error" => "repo_not_found",
              "reason" => "no repo at #{Path.absname(expand(repo))} under root #{root()}"
            })

      {:error, :outside_root} ->
        if msg.reply_to,
          do:
            reply(msg, %{
              "ok" => false,
              "error" => "outside_root",
              "reason" => "scan target must live under AUDITOR_REPO_ROOT=#{root()}"
            })
    end
  end

  defp repo_param(message) when is_map(message) do
    case message["repo"] || message["path"] || message[:repo] do
      v when is_binary(v) and v != "" -> v
      _ -> default_repo_root_name()
    end
  end

  defp repo_param(_), do: default_repo_root_name()

  # Empty payload scans the root's own starter (useful smoke target).
  defp default_repo_root_name, do: System.get_env("AUDITOR_DEFAULT_REPO", "bot_army_sre")

  defp catalog_param(message) when is_map(message) do
    case message["catalog_path"] || message[:catalog_path] do
      v when is_binary(v) and v != "" -> v
      _ -> System.get_env("AUDITOR_CATALOG_PATH")
    end
  end

  defp catalog_param(_), do: System.get_env("AUDITOR_CATALOG_PATH")

  defp root, do: System.get_env("AUDITOR_REPO_ROOT", "/repos")

  defp expand(repo), do: if(String.starts_with?(repo, "/"), do: repo, else: Path.join(root(), repo))

  @impl true
  def handle_cast({:store_scan, results}, state) do
    {:noreply, %{state | last_scan: %{results: results, at: DateTime.utc_now()}}}
  end

  @impl true
  def handle_call(:last_scan, _from, state) do
    {:reply, state.last_scan, state}
  end

  defp reply(msg, payload) do
    case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5_000) do
      {:ok, conn} ->
        Gnat.pub(conn, msg.reply_to, Jason.encode!(payload))

      {:error, reason} ->
        Logger.warning("[RepoScanner] reply failed (no connection): #{inspect(reason)}")
    end
  end
end