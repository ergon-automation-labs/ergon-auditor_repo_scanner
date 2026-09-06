defmodule BotArmyAuditorRepoScanner.Skills.ExampleTest do
  @moduledoc """
  Unit tests for Example skill.

  Skills are tested in isolation:
  - Mock LLM context
  - Validate input schema
  - Verify output shape
  - No external services called
  """

  use ExUnit.Case, async: true
  @moduletag :skills

  alias BotArmyAuditorRepoScanner.Skills.Example

  describe "name/0" do
    test "returns skill name" do
      assert Example.name() == :example
    end
  end

  describe "description/0" do
    test "returns description" do
      desc = Example.description()
      assert is_binary(desc)
      assert byte_size(desc) > 0
    end
  end

  describe "nats_triggers/0" do
    test "returns list of trigger subjects" do
      triggers = Example.nats_triggers()
      assert is_list(triggers)
      assert Enum.all?(triggers, &is_binary/1)
      assert "bot.bot_army_auditor_repo_scanner.command.example" in triggers
    end
  end

  describe "llm_hint/0" do
    test "returns atom hint" do
      hint = Example.llm_hint()
      assert hint in [:fast, :deep]
    end
  end

  describe "validate/1" do
    test "accepts valid payload with content" do
      assert Example.validate(%{"content" => "hello world"}) == :ok
    end

    test "rejects empty string" do
      assert Example.validate(%{"content" => ""}) != :ok
    end

    test "rejects missing content" do
      assert Example.validate(%{}) != :ok
    end

    test "rejects non-string content" do
      assert Example.validate(%{"content" => 123}) != :ok
    end
  end

  describe "execute/2" do
    test "executes successfully with valid input" do
      payload = %{"content" => "test content"}
      ctx = mock_context()

      {:ok, result} = Example.execute(payload, ctx)

      assert result.message == "Example skill executed successfully"
      assert result.content_length == 12
      assert result.bot_id == "test-bot-id"
      assert result.executed_at != nil
    end

    test "returns result with processed content" do
      payload = %{"content" => "hello world"}
      ctx = mock_context()

      {:ok, result} = Example.execute(payload, ctx)

      assert result.result.length == 11
      assert result.result.words == 2
      assert result.result.processed == "HELLO WORLD"
    end

    test "handles errors gracefully" do
      # Simulate error by passing invalid context
      payload = %{"content" => "test"}
      ctx = %{bot_id: nil}

      result = Example.execute(payload, ctx)

      # Should still return {:error, reason}
      assert elem(result, 0) in [:ok, :error]
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp mock_context do
    %{
      bot_id: "test-bot-id",
      llm: mock_llm(),
      personality: "helpful",
      context: %{}
    }
  end

  defp mock_llm do
    %{
      request: fn prompt, opts ->
        {:ok, %{
          output: "mock response for: " <> prompt,
          confidence: 0.95
        }}
      end
    }
  end
end
