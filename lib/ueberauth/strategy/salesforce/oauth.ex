defmodule Ueberauth.Strategy.Salesforce.OAuth do
  @moduledoc """
  OAuth2 client for Salesforce.

  Configure credentials:

      config :ueberauth, Ueberauth.Strategy.Salesforce.OAuth,
        client_id: System.get_env("SALESFORCE_CLIENT_ID"),
        client_secret: System.get_env("SALESFORCE_CLIENT_SECRET")
  """

  use OAuth2.Strategy

  @defaults [
    strategy: __MODULE__,
    site: "https://login.salesforce.com",
    authorize_url: "/services/oauth2/authorize",
    token_url: "/services/oauth2/token"
  ]

  def client(opts \\ []) do
    config = Application.get_env(:ueberauth, __MODULE__, [])

    @defaults
    |> Keyword.merge(config)
    |> Keyword.merge(opts)
    |> OAuth2.Client.new()
    |> OAuth2.Client.put_serializer("application/json", Ueberauth.json_library())
  end

  def authorize_url!(params \\ [], opts \\ []) do
    opts
    |> client()
    |> OAuth2.Client.authorize_url!(params)
  end

  def get_access_token(params \\ [], opts \\ []) do
    config = Application.get_env(:ueberauth, __MODULE__, [])

    params =
      params
      |> Keyword.put(:client_id, config[:client_id])
      |> Keyword.put(:client_secret, config[:client_secret])

    case opts |> client() |> OAuth2.Client.get_token(params) do
      {:ok, %OAuth2.Client{token: %OAuth2.AccessToken{} = token}} ->
        {:ok, token}

      {:ok, %OAuth2.Client{token: nil}} ->
        {:error, {"no_token", "No token returned from Salesforce"}}

      {:error, %OAuth2.Response{body: %{"error" => error} = body}} ->
        {:error, {error, Map.get(body, "error_description", "OAuth error")}}

      {:error, %OAuth2.Error{reason: reason}} ->
        {:error, {"oauth2_error", to_string(reason)}}
    end
  end

  def get_identity(identity_url, access_token) do
    case Tesla.get(http_client(access_token), identity_url) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error, {"identity_error", "Failed to fetch identity: #{status} - #{inspect(body)}"}}

      {:error, reason} ->
        {:error, {"identity_error", "HTTP error: #{inspect(reason)}"}}
    end
  end

  defp http_client(access_token) do
    Tesla.client([
      {Tesla.Middleware.Headers, [{"authorization", "Bearer #{access_token}"}]},
      Tesla.Middleware.JSON
    ])
  end

  @impl OAuth2.Strategy
  def authorize_url(client, params) do
    OAuth2.Strategy.AuthCode.authorize_url(client, params)
  end

  @impl OAuth2.Strategy
  def get_token(client, params, headers) do
    client
    |> put_param(:grant_type, "authorization_code")
    |> put_header("Content-Type", "application/x-www-form-urlencoded")
    |> put_header("Accept", "application/json")
    |> OAuth2.Strategy.AuthCode.get_token(params, headers)
  end
end
