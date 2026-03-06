defmodule SocialScribeWeb.AuthControllerTest do
  use SocialScribeWeb.ConnCase, async: true

  alias SocialScribe.Accounts

  import SocialScribe.AccountsFixtures

  setup :register_and_log_in_user

  test "salesforce callback creates credential for logged-in user", %{conn: conn, user: user} do
    auth = salesforce_auth("00D123456789ABC", "token-a", "refresh-a", user.email)

    conn =
      conn
      |> init_test_session(%{})
      |> Phoenix.Controller.fetch_flash([])
      |> Plug.Conn.assign(:current_user, user)
      |> Plug.Conn.assign(:ueberauth_auth, auth)
      |> SocialScribeWeb.AuthController.callback(%{"provider" => "salesforce"})

    assert redirected_to(conn) == ~p"/dashboard/settings"

    assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
             "Salesforce account connected successfully!"

    credential = Accounts.get_user_credential(user, "salesforce", "00D123456789ABC")
    assert credential.token == "token-a"
    assert credential.refresh_token == "refresh-a"
  end

  test "salesforce callback updates existing credential for logged-in user", %{
    conn: conn,
    user: user
  } do
    existing =
      user_credential_fixture(%{
        user_id: user.id,
        provider: "salesforce",
        uid: "00D123456789ABC",
        token: "old-token",
        refresh_token: "old-refresh",
        email: user.email
      })

    auth = salesforce_auth("00D123456789ABC", "new-token", "new-refresh", user.email)

    conn =
      conn
      |> init_test_session(%{})
      |> Phoenix.Controller.fetch_flash([])
      |> Plug.Conn.assign(:current_user, user)
      |> Plug.Conn.assign(:ueberauth_auth, auth)
      |> SocialScribeWeb.AuthController.callback(%{"provider" => "salesforce"})

    assert redirected_to(conn) == ~p"/dashboard/settings"

    assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
             "Salesforce account connected successfully!"

    updated = Accounts.get_user_credential(user, "salesforce", "00D123456789ABC")
    assert updated.id == existing.id
    assert updated.token == "new-token"
    assert updated.refresh_token == "new-refresh"
  end

  defp salesforce_auth(uid, token, refresh_token, email) do
    %Ueberauth.Auth{
      provider: :salesforce,
      uid: uid,
      info: %Ueberauth.Auth.Info{
        email: email
      },
      credentials: %Ueberauth.Auth.Credentials{
        token: token,
        refresh_token: refresh_token,
        expires_at: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix()
      }
    }
  end
end
