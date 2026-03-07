defmodule SocialScribe.SalesforceTokenRefresher do
  @moduledoc """
  Refreshes Salesforce OAuth tokens.
  """

  alias SocialScribe.Accounts
  alias SocialScribe.Accounts.UserCredential

  @token_path "/services/oauth2/token"

  def client do
    Tesla.client([
      {Tesla.Middleware.FormUrlencoded,
       encode: &Plug.Conn.Query.encode/1, decode: &Plug.Conn.Query.decode/1},
      Tesla.Middleware.JSON
    ])
  end

  def refresh_token(%UserCredential{} = credential) do
    with {:ok, instance_url} <- instance_url(credential) do
      config = Application.get_env(:ueberauth, Ueberauth.Strategy.Salesforce.OAuth, [])

      body = %{
        grant_type: "refresh_token",
        client_id: config[:client_id],
        client_secret: config[:client_secret],
        refresh_token: credential.refresh_token
      }

      case Tesla.post(client(), instance_url <> @token_path, body) do
        {:ok, %Tesla.Env{status: 200, body: response_body}} ->
          {:ok, response_body}

        {:ok, %Tesla.Env{status: status, body: error_body}} ->
          {:error, {status, error_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def refresh_credential(%UserCredential{} = credential) do
    case refresh_token(credential) do
      {:ok, response} ->
        metadata =
          credential.metadata
          |> normalize_metadata()
          |> maybe_put_metadata("instance_url", response["instance_url"])
          |> maybe_put_metadata("identity_url", response["id"])
          |> maybe_put_metadata("id_url", response["id"])

        attrs = %{
          token: response["access_token"],
          refresh_token: response["refresh_token"] || credential.refresh_token,
          expires_at: DateTime.add(DateTime.utc_now(), response["expires_in"] || 3600, :second),
          metadata: metadata
        }

        Accounts.update_user_credential(credential, attrs)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def ensure_valid_token(%UserCredential{} = credential) do
    with {:ok, _} <- instance_url(credential) do
      buffer_seconds = 300

      if DateTime.compare(
           credential.expires_at,
           DateTime.add(DateTime.utc_now(), buffer_seconds, :second)
         ) == :lt do
        refresh_credential(credential)
      else
        {:ok, credential}
      end
    end
  end

  def instance_url(%UserCredential{metadata: metadata}) do
    case normalize_metadata(metadata)["instance_url"] do
      nil ->
        {:error,
         {:reconnect_required, "Missing Salesforce instance URL. Please reconnect Salesforce."}}

      instance_url when is_binary(instance_url) ->
        {:ok, String.trim_trailing(instance_url, "/")}
    end
  end

  defp normalize_metadata(nil), do: %{}
  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_), do: %{}

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)
end
