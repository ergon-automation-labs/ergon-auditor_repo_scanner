defmodule BotArmyAuditorRepoScanner.Skills.Example do
  @moduledoc """
  Example skill for Repo Scanner Bot.

  Skills are autonomous units of work triggered by NATS messages. Each skill:
  - Listens for specific NATS subjects
  - Validates input payload
  - Executes domain logic (with optional LLM integration)
  - Returns structured results

  ## How It Works

  1. NATS message arrives on trigger subject: `bot.bot_army_auditor_repo_scanner.command.example`
  2. GenBot routes message to this skill
  3. `validate/1` checks payload structure
  4. `execute/2` runs skill logic with context (bot_id, llm, personality, etc.)
  5. Result published to response subject: `bot.bot_army_auditor_repo_scanner.response.<request_id>`

  ## Payload Format

  ```json
  {
    "request_id": "uuid",
    "content": "what to do",
    "metadata": {...}
  }
  ```

  Request ID allows correlation with responses via NATS reply subjects.

  ## Customization

  Replace this example with your skill:

  1. Rename: `lib/bot_army_auditor_repo_scanner/skills/your_skill.ex`
  2. Update `name/0` → `:your_skill`
  3. Update `description/0` → your description
  4. Update `nats_triggers/0` → subjects you listen on
  5. Implement `validate/1` → payload schema
  6. Implement `execute/2` → business logic
  7. Optional: update `llm_hint/0` → :fast or :deep
  8. Register in Application.ex via GenBot

  ## LLM Integration (Optional)

  If your skill needs LLM reasoning:

  ```elixir
  def execute(%{"content" => content}, ctx) do
    {:ok, llm_result} = ctx.llm.request(
      "Analyze: " <> content,
      hint: :fast  # or :deep for complex reasoning
    )

    {:ok, %{
      analysis: llm_result.output,
      confidence: llm_result.confidence
    }}
  end
  ```

  The context includes:
  - `ctx.bot_id` — Your bot's ID
  - `ctx.llm` — LLM proxy for requests
  - `ctx.personality` — Bot personality for LLM tone
  - `ctx.context` — Current context/state (if available)
  """

  use BotArmy.Skill

  require Logger

  @impl true
  def name, do: :example

  @impl true
  def description do
    "Example skill - processes content and returns analysis"
  end

  @impl true
  def nats_triggers do
    # NATS subjects that trigger this skill
    # Pattern: bot.<app_name>.command.<action>
    [
      "bot.bot_army_auditor_repo_scanner.command.example"
    ]
  end

  @impl true
  def llm_hint do
    # :fast — simple/quick reasoning
    # :deep — complex reasoning, multi-turn, chains
    :fast
  end

  @impl true
  def validate(%{"content" => content}) when is_binary(content) and byte_size(content) > 0 do
    :ok
  end

  def validate(_) do
    {:error, "content field required and must be non-empty string"}
  end

  @impl true
  def execute(%{"content" => content}, ctx) do
    try do
      Logger.info("[Example] Executing with content length: #{byte_size(content)}")

      # Example 1: Simple processing (no LLM)
      result = process_content(content)

      # Example 2: LLM integration (optional)
      # {:ok, llm_result} = ctx.llm.request(
      #   "Analyze this: " <> content,
      #   hint: :fast
      # )

      {:ok, %{
        message: "Example skill executed successfully",
        content_length: byte_size(content),
        result: result,
        bot_id: ctx.bot_id,
        executed_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }}
    rescue
      e ->
        Logger.error("[Example] Execution failed", error: inspect(e))
        {:error, :execution_failed}
    end
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp process_content(content) do
    # Replace with your domain logic
    %{
      length: byte_size(content),
      words: Enum.count(String.split(content)),
      processed: String.upcase(content)
    }
  end
end
