defmodule BotArmyAuditorRepoScanner.Receipts do
  @moduledoc """
  Publishes the observability receipts a completed repo scan owes the fleet
  (the conformance-bot receipt pattern):

    - audit receipt on `sre.audit.repo_scanner` (event `sre.repo.scan.completed`)
      — published on EVERY completed scan regardless of verdict, so external
      taps can verify scans happened even when sre is absent from the fleet.
    - incident envelope on `events.sre.log.incident` (event `sre.log.incident`)
      — only when the scan's verdict is "failing" (required checks failed).

  Envelope shape matches the fleet contract (event, event_id, timestamp,
  source); the runtime Publisher adds tracing/correlation headers.
  """

  require Logger

  alias BotArmyLibraryRuntime.NATS.Publisher

  @audit_subject "sre.audit.repo_scanner"
  @incident_subject "events.sre.log.incident"

  @doc "Publishes the sre audit receipt for a completed scan. Returns :ok | {:error, reason}."
  def publish_scan_receipt(results) do
    envelope = %{
      "event" => "sre.repo.scan.completed",
      "event_id" => scan_id(results),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "auditor_repo_scanner",
      "payload" => %{
        "repo" => results["repo"],
        "name" => results["name"],
        "verdict" => results["verdict"],
        "summary" => results["summary"],
        "score" => results["score"],
        "duration_ms" => results["duration_ms"],
        "failing" => failing_checks(results)
      }
    }

    case Publisher.publish(@audit_subject, envelope) do
      {:ok, _} ->
        Logger.info(
          "[Receipts] scan receipt published (#{results["name"]}: #{results["verdict"]}, " <>
            "#{results["score"]})"
        )

        :ok

      {:error, reason} ->
        Logger.warning("[Receipts] scan receipt publish failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Publishes an sre incident envelope when the scan verdict is "failing"
  (required checks failed). Warnings never raise incidents.
  """
  def publish_failure_incident(results)

  def publish_failure_incident(%{"verdict" => "failing"} = results) do
    failures =
      results["checks"]
      |> Enum.filter(&(&1["status"] == "fail"))
      |> Enum.with_index(1)
      |> Enum.map(fn {c, i} ->
        %{"line_number" => i, "line" => "#{c["id"]} (#{c["severity"]}): #{c["detail"]}"}
      end)

    envelope = %{
      "event" => "sre.log.incident",
      "event_id" => Elixir.UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "auditor_repo_scanner",
      "payload" => %{
        "bot" => "auditor_repo_scanner",
        "error_type" => "repo_contract_failure",
        "repo" => results["repo"],
        "match_count" => length(failures),
        "matches" => failures
      }
    }

    case Publisher.publish(@incident_subject, envelope) do
      {:ok, _} ->
        Logger.warning("[Receipts] #{length(failures)} failing check(s) — sre incident published")
        :ok

      {:error, reason} ->
        Logger.warning("[Receipts] incident publish failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def publish_failure_incident(_results), do: :ok

  defp failing_checks(results) do
    results["checks"]
    |> Enum.filter(&(&1["status"] == "fail"))
    |> Enum.map(&%{"id" => &1["id"], "detail" => &1["detail"]})
  end

  defp scan_id(results) do
    "scan-" <> (results["name"] || "unknown") <> "-" <> Elixir.UUID.uuid4()
  end
end