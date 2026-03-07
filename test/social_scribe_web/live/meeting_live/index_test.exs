defmodule SocialScribeWeb.MeetingLive.IndexTest do
  use SocialScribeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SocialScribe.MeetingsFixtures

  alias SocialScribe.Calendar
  alias SocialScribeWeb.DateTimeFormat

  setup :register_and_log_in_user

  test "renders recorded timestamp in browser timezone", %{conn: conn, user: user} do
    recorded_at = ~U[2026-03-07 18:45:00Z]
    meeting = meeting_fixture(%{title: "Past Timezone Meeting", recorded_at: recorded_at})

    meeting.calendar_event_id
    |> Calendar.get_calendar_event!()
    |> Calendar.update_calendar_event(%{user_id: user.id})

    timezone = "America/New_York"
    conn = put_connect_params(conn, %{"timezone" => timezone})

    {:ok, _view, html} = live(conn, ~p"/dashboard/meetings")

    assert html =~ "Past Timezone Meeting"
    assert html =~ DateTimeFormat.format_in_timezone(recorded_at, timezone)
  end
end
