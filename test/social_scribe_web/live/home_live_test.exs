defmodule SocialScribeWeb.HomeLiveTest do
  use SocialScribeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SocialScribe.AccountsFixtures
  import SocialScribe.CalendarFixtures

  alias SocialScribeWeb.DateTimeFormat

  setup :register_and_log_in_user

  test "renders upcoming event in browser timezone", %{conn: conn, user: user} do
    credential = user_credential_fixture(%{user_id: user.id, provider: "google"})

    start_time =
      DateTime.utc_now()
      |> DateTime.add(3600, :second)
      |> DateTime.truncate(:second)

    _event =
      calendar_event_fixture(%{
        user_id: user.id,
        user_credential_id: credential.id,
        summary: "Timezone Display Event",
        start_time: start_time,
        end_time: DateTime.add(start_time, 1800, :second)
      })

    timezone = "America/Los_Angeles"
    conn = put_connect_params(conn, %{"timezone" => timezone})

    {:ok, _view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Timezone Display Event"
    assert html =~ DateTimeFormat.format_in_timezone(start_time, timezone)
  end

  test "falls back to UTC when timezone is invalid", %{conn: conn, user: user} do
    credential = user_credential_fixture(%{user_id: user.id, provider: "google"})

    start_time =
      DateTime.utc_now()
      |> DateTime.add(7200, :second)
      |> DateTime.truncate(:second)

    _event =
      calendar_event_fixture(%{
        user_id: user.id,
        user_credential_id: credential.id,
        summary: "Invalid Timezone Event",
        start_time: start_time,
        end_time: DateTime.add(start_time, 1800, :second)
      })

    conn = put_connect_params(conn, %{"timezone" => "Not/A_Real_Timezone"})

    {:ok, _view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Invalid Timezone Event"
    assert html =~ DateTimeFormat.format_in_timezone(start_time, "Etc/UTC")
  end
end
