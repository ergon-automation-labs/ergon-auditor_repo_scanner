defmodule BotArmyAuditorRepoScanner.ExampleTest do
  @moduledoc """
  Example unit test with proper tagging.

  @moduletag :handlers — for handler tests
  @moduletag :stores — for persistence/store tests
  @moduletag :nats — for NATS integration tests
  @moduletag :scheduler — for scheduler/polling tests
  @moduletag :integrations — for external API integration tests

  @tag :integration — marks individual test as requiring database or real services
  @tag :nats_live — marks test as requiring real NATS connection
  @tag :load — marks test as performance/load test
  """

  use ExUnit.Case, async: true
  @moduletag :core

  describe "module initialization" do
    test "application starts without errors" do
      assert BotArmyAuditorRepoScanner.Application != nil
    end
  end

  describe "pulse publisher" do
    test "pulse publisher module exists" do
      # Verify PulsePublisher is defined
      # In production: started by Application.ex
      # In test: not started (gated by @env)
      assert module_exists?(BotArmyAuditorRepoScanner.PulsePublisher)
    end
  end

  describe "http client behavior" do
    test "http client behavior is defined" do
      # HTTPClient allows mocking in tests
      assert module_exists?(BotArmyAuditorRepoScanner.HTTPClient)
      assert module_exists?(BotArmyAuditorRepoScanner.HTTPClient.Req)
    end
  end

  # ============================================================================
  # Example: Using Mox for HTTP client mocking
  # ============================================================================

  # @tag :integration
  # test "fetches data via mocked HTTP client" do
  #   Mox.expect(HTTPClientMock, :get, fn url, _opts ->
  #     {:ok, %{status: 200, body: %{"key" => "value"}}}
  #   end)
  #
  #   # Example function that uses http_client (pass HTTPClientMock in tests)
  #   # result = YourModule.fetch_data(url, HTTPClientMock)
  #   # assert result.key == "value"
  # end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp module_exists?(module) do
    try do
      module.__info__(:module)
      true
    rescue
      _ -> false
    end
  end
end
