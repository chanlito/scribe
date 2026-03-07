defmodule Ueberauth.Strategy.SalesforceTest do
  use ExUnit.Case, async: true

  alias Ueberauth.Strategy.Salesforce

  import Plug.Test

  defmodule OAuthMock do
    def authorize_url!(params, opts) do
      "#{Keyword.fetch!(opts, :site)}/services/oauth2/authorize?#{URI.encode_query(params)}"
    end

    def get_access_token(params, _opts) do
      send(self(), {:oauth_get_access_token, params})

      case Keyword.get(params, :code) do
        "valid_code" ->
          {:ok,
           %OAuth2.AccessToken{
             access_token: "access-token",
             refresh_token: "refresh-token",
             expires_at: 1_900_000_000,
             token_type: "Bearer",
             other_params: %{"id" => "https://identity.example.com/id/123"}
           }}

        _ ->
          {:error, {"invalid_grant", "Invalid authorization code"}}
      end
    end

    def get_identity("https://identity.example.com/id/123", "access-token") do
      {:ok,
       %{
         "organization_id" => "00D123456789ABC",
         "username" => "owner@example.com",
         "email" => "owner@example.com",
         "display_name" => "Owner"
       }}
    end

    def get_identity(_, _) do
      {:error, {"identity_error", "Could not fetch identity"}}
    end
  end

  test "request with env=prod redirects to login.salesforce.com" do
    conn =
      %{"env" => "prod"}
      |> request_conn()
      |> Salesforce.handle_request!()

    assert conn.halted
    assert conn.status == 302

    location = List.first(Plug.Conn.get_resp_header(conn, "location"))
    assert %URI{host: "login.salesforce.com"} = URI.parse(location)
  end

  test "request with env=sandbox redirects to test.salesforce.com" do
    conn =
      %{"env" => "sandbox"}
      |> request_conn()
      |> Salesforce.handle_request!()

    assert conn.halted
    assert conn.status == 302

    location = List.first(Plug.Conn.get_resp_header(conn, "location"))
    assert %URI{host: "test.salesforce.com"} = URI.parse(location)
  end

  test "request with env=custom redirects to provided custom domain" do
    conn =
      %{"env" => "custom", "domain" => "acme.my.salesforce.com"}
      |> request_conn()
      |> Salesforce.handle_request!()

    assert conn.halted
    assert conn.status == 302

    location = List.first(Plug.Conn.get_resp_header(conn, "location"))
    assert %URI{host: "acme.my.salesforce.com"} = URI.parse(location)
  end

  test "request without env defaults to login.salesforce.com" do
    conn =
      %{}
      |> request_conn()
      |> Salesforce.handle_request!()

    assert conn.halted
    assert conn.status == 302

    location = List.first(Plug.Conn.get_resp_header(conn, "location"))
    assert %URI{host: "login.salesforce.com"} = URI.parse(location)
  end

  test "request with invalid custom domain returns 400" do
    conn =
      %{"env" => "custom", "domain" => "invalid.example.com"}
      |> request_conn()
      |> Salesforce.handle_request!()

    assert conn.halted
    assert conn.status == 400
    assert conn.resp_body =~ "Custom domain must end with .salesforce.com"
  end

  test "callback stores identity and uid from organization_id" do
    conn =
      %{"code" => "valid_code", "env" => "prod"}
      |> callback_conn()
      |> Salesforce.handle_callback!()

    assert conn.private.salesforce_user["organization_id"] == "00D123456789ABC"
    assert Salesforce.uid(conn) == "00D123456789ABC"
    assert Salesforce.info(conn).email == "owner@example.com"
  end

  test "callback with invalid env sets errors" do
    conn =
      %{"code" => "valid_code", "env" => "bad"}
      |> callback_conn()
      |> Salesforce.handle_callback!()

    assert %{errors: errors} = conn.assigns.ueberauth_failure
    assert Enum.any?(errors, &(&1.message =~ "Invalid env"))
  end

  test "callback recovers env from session when provider does not return it" do
    conn =
      %{"code" => "valid_code"}
      |> callback_conn(%{salesforce_oauth_env: "prod"})
      |> Salesforce.handle_callback!()

    assert conn.private.salesforce_user["organization_id"] == "00D123456789ABC"
    assert Salesforce.uid(conn) == "00D123456789ABC"
    assert_received {:oauth_get_access_token, token_params}
    assert Keyword.get(token_params, :redirect_uri) =~ "env=prod"
  end

  defp request_conn(params) do
    conn(:get, "/auth/salesforce", params)
    |> Plug.Conn.put_private(:ueberauth_request_options, strategy_options())
  end

  defp callback_conn(params, session \\ %{}) do
    conn(:get, "/auth/salesforce/callback", params)
    |> init_test_session(session)
    |> Plug.Conn.put_private(:ueberauth_request_options, strategy_options())
  end

  defp strategy_options do
    %{
      strategy: Salesforce,
      strategy_name: :salesforce,
      request_path: "/auth/salesforce",
      callback_path: "/auth/salesforce/callback",
      callback_params: ["env", "domain"],
      options: [
        uid_field: :organization_id,
        default_scope: "api refresh_token",
        oauth2_module: OAuthMock
      ]
    }
  end
end
