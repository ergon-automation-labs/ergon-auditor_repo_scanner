defmodule BotArmyAuditorRepoScanner.HTTPClient do
  @moduledoc """
  HTTP client behavior for dependency injection and testing.

  Allows mocking HTTP requests in tests via Mox.

  ## Usage in Production

      {:ok, response} = HTTPClient.get(url, opts)

  ## Usage in Tests

      Mox.expect(HTTPClientMock, :get, fn url, opts ->
        {:ok, %{status: 200, body: %{"key" => "value"}}}
      end)

  ## Pattern

  Pass http_client as an option in init:
      def init(opts) do
        http_client = Keyword.get(opts, :http_client, BotArmyAuditorRepoScanner.HTTPClient.Req)
        {:ok, %{http_client: http_client}}
      end

  Then use it in private functions:
      defp fetch_data(url, http_client) do
        case http_client.get(url) do
          {:ok, response} -> process(response)
          {:error, reason} -> {:error, reason}
        end
      end
  """

  @callback get(url :: String.t(), opts :: keyword()) :: {:ok, map()} | {:error, any()}
  @callback get(url :: String.t()) :: {:ok, map()} | {:error, any()}
end

defmodule BotArmyAuditorRepoScanner.HTTPClient.Req do
  @moduledoc """
  Real HTTP client implementation using the Req library.
  """

  @behaviour BotArmyAuditorRepoScanner.HTTPClient

  @impl true
  def get(url, opts \\ []) do
    Req.get(url, opts)
  end
end
