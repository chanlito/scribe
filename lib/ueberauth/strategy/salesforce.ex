defmodule Ueberauth.Strategy.Salesforce do
  @moduledoc """
  Salesforce strategy for Ueberauth.
  """

  use Ueberauth.Strategy,
    uid_field: :organization_id,
    default_scope: "api refresh_token",
    oauth2_module: Ueberauth.Strategy.Salesforce.OAuth

  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra
  alias Ueberauth.Auth.Info

  @prod_host "login.salesforce.com"
  @sandbox_host "test.salesforce.com"
  @custom_domain_suffix ".salesforce.com"

  def handle_request!(conn) do
    scopes = conn.params["scope"] || option(conn, :default_scope)

    with {:ok, host, domain} <- resolve_request_target(conn.params) do
      env = conn.params["env"]
      redirect_uri = oauth_redirect_uri(conn, env, domain)

      params =
        [scope: scopes, redirect_uri: redirect_uri]
        |> with_param(:prompt, conn)
        |> with_state_param(conn)

      oauth_opts = [site: "https://#{host}"]

      module = option(conn, :oauth2_module)

      conn
      |> store_oauth_context(env, domain)
      |> redirect!(module.authorize_url!(params, oauth_opts))
    else
      {:error, reason} ->
        bad_request(conn, reason)
    end
  end

  def handle_callback!(%Plug.Conn{params: %{"error" => error, "error_description" => description}} = conn) do
    set_errors!(conn, [error(error, description)])
  end

  def handle_callback!(%Plug.Conn{params: %{"error" => error}} = conn) do
    set_errors!(conn, [error(error, "Salesforce OAuth error")])
  end

  def handle_callback!(%Plug.Conn{params: %{"code" => code} = params} = conn) do
    request_params = with_oauth_context_from_session(params, conn)
    conn = clear_oauth_context(conn)

    with {:ok, host, _domain} <- resolve_request_target(request_params),
         {:ok, token} <- fetch_token(conn, request_params, host, code),
         {:ok, user} <- fetch_identity(conn, token) do
      conn
      |> put_private(:salesforce_token, token)
      |> put_private(:salesforce_user, user)
    else
      {:error, {error_code, error_description}} ->
        set_errors!(conn, [error(to_string(error_code), to_string(error_description))])

      {:error, reason} ->
        set_errors!(conn, [error("invalid_request", reason)])
    end
  end

  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end

  def handle_cleanup!(conn) do
    conn
    |> put_private(:salesforce_token, nil)
    |> put_private(:salesforce_user, nil)
  end

  def uid(conn) do
    uid_field =
      conn
      |> option(:uid_field)
      |> to_string()

    conn.private.salesforce_user[uid_field]
  end

  def credentials(conn) do
    token = conn.private.salesforce_token
    scopes = (token.other_params["scope"] || "") |> String.split(" ", trim: true)

    %Credentials{
      expires: !!token.expires_at,
      expires_at: token.expires_at,
      scopes: scopes,
      token: token.access_token,
      refresh_token: token.refresh_token,
      token_type: token.token_type
    }
  end

  def info(conn) do
    user = conn.private.salesforce_user

    email = user["email"] || user["username"]

    %Info{
      email: email,
      name: user["display_name"] || email
    }
  end

  def extra(conn) do
    %Extra{
      raw_info: %{
        token: conn.private.salesforce_token,
        user: conn.private.salesforce_user
      }
    }
  end

  defp fetch_token(conn, request_params, host, code) do
    redirect_uri = oauth_redirect_uri(conn, request_params["env"], request_params["domain"])
    params = [code: code, redirect_uri: redirect_uri]
    opts = [site: "https://#{host}"]

    module = option(conn, :oauth2_module)
    module.get_access_token(params, opts)
  end

  defp fetch_identity(conn, token) do
    module = option(conn, :oauth2_module)
    identity_url = token.other_params["id"]

    if is_binary(identity_url) and identity_url != "" do
      module.get_identity(identity_url, token.access_token)
    else
      {:error, {"missing_identity", "Salesforce token did not include identity URL"}}
    end
  end

  defp resolve_request_target(%{"env" => "prod"}), do: {:ok, @prod_host, nil}
  defp resolve_request_target(%{"env" => "sandbox"}), do: {:ok, @sandbox_host, nil}

  defp resolve_request_target(%{"env" => "custom", "domain" => domain}) do
    case normalize_custom_domain(domain) do
      {:ok, normalized} -> {:ok, normalized, normalized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_request_target(%{"env" => "custom"}) do
    {:error, "Missing domain for env=custom"}
  end

  defp resolve_request_target(%{"env" => env}) do
    {:error, "Invalid env '#{env}'. Expected prod, sandbox, or custom"}
  end

  defp resolve_request_target(_), do: {:ok, @prod_host, nil}

  defp normalize_custom_domain(domain) when is_binary(domain) do
    normalized = domain |> String.trim() |> String.downcase()

    cond do
      normalized == "" ->
        {:error, "Missing domain for env=custom"}

      String.contains?(normalized, "://") ->
        {:error, "Custom domain must be a host only (no scheme)"}

      String.contains?(normalized, "/") ->
        {:error, "Custom domain must not include path segments"}

      String.starts_with?(normalized, ".") or String.ends_with?(normalized, ".") ->
        {:error, "Invalid custom domain format"}

      String.contains?(normalized, "..") ->
        {:error, "Invalid custom domain format"}

      not Regex.match?(~r/\A[a-z0-9][a-z0-9.-]*\z/, normalized) ->
        {:error, "Invalid custom domain format"}

      not String.ends_with?(normalized, @custom_domain_suffix) ->
        {:error, "Custom domain must end with #{@custom_domain_suffix}"}

      true ->
        {:ok, normalized}
    end
  end

  defp normalize_custom_domain(_), do: {:error, "Invalid custom domain format"}

  defp store_oauth_context(conn, env, domain) do
    if session_available?(conn) do
      conn
      |> put_session(:salesforce_oauth_env, env)
      |> maybe_put_domain_session(domain)
    else
      conn
    end
  end

  defp maybe_put_domain_session(conn, nil), do: delete_session(conn, :salesforce_oauth_domain)

  defp maybe_put_domain_session(conn, domain),
    do: put_session(conn, :salesforce_oauth_domain, domain)

  defp with_oauth_context_from_session(params, conn) do
    env = params["env"] || session_value(conn, :salesforce_oauth_env)
    domain = params["domain"] || session_value(conn, :salesforce_oauth_domain)

    params
    |> maybe_put_param("env", env)
    |> maybe_put_param("domain", domain)
  end

  defp clear_oauth_context(conn) do
    if session_available?(conn) do
      conn
      |> delete_session(:salesforce_oauth_env)
      |> delete_session(:salesforce_oauth_domain)
    else
      conn
    end
  end

  defp session_available?(conn), do: conn.private[:plug_session_fetch] == :done

  defp session_value(conn, key) do
    if session_available?(conn), do: get_session(conn, key), else: nil
  end

  defp maybe_put_param(params, _key, nil), do: params
  defp maybe_put_param(params, key, value), do: Map.put(params, key, value)

  defp oauth_redirect_uri(conn, "prod", _domain), do: callback_url(conn, env: "prod")
  defp oauth_redirect_uri(conn, "sandbox", _domain), do: callback_url(conn, env: "sandbox")

  defp oauth_redirect_uri(conn, "custom", domain),
    do: callback_url(conn, env: "custom", domain: domain)

  defp oauth_redirect_uri(conn, _env, _domain), do: callback_url(conn)

  defp bad_request(conn, reason) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(400, reason)
    |> Plug.Conn.halt()
  end

  defp with_param(opts, key, conn) do
    if value = conn.params[to_string(key)], do: Keyword.put(opts, key, value), else: opts
  end

  defp option(conn, key) do
    Keyword.get(options(conn), key, Keyword.get(default_options(), key))
  end
end
