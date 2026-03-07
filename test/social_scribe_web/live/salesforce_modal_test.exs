defmodule SocialScribeWeb.SalesforceModalTest do
  use SocialScribeWeb.ConnCase

  import Phoenix.LiveViewTest
  import SocialScribe.AccountsFixtures
  import SocialScribe.MeetingsFixtures

  describe "Salesforce Modal" do
    setup %{conn: conn} do
      user = user_fixture()
      salesforce_credential = salesforce_credential_fixture(%{user_id: user.id})
      meeting = meeting_fixture_with_transcript(user)

      %{
        conn: log_in_user(conn, user),
        user: user,
        meeting: meeting,
        salesforce_credential: salesforce_credential
      }
    end

    test "renders modal when navigating to salesforce route", %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/crm/salesforce")

      assert has_element?(view, "#salesforce-modal-wrapper")
      assert has_element?(view, "h2", "Update in Salesforce")
    end

    test "displays contact search input when only one Salesforce account exists", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/crm/salesforce")

      assert has_element?(view, "input[phx-keyup='contact_search']")
      refute has_element?(view, "select[name='credential_id']")
    end

    test "shows Salesforce account selector when multiple accounts exist", %{
      conn: conn,
      user: user,
      meeting: meeting
    } do
      _other = salesforce_credential_fixture(%{user_id: user.id})

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/crm/salesforce")

      assert has_element?(view, "select[name='credential_id']")
      assert has_element?(view, "label[for='salesforce-modal-wrapper-credential-select']")

      assert has_element?(
               view,
               "select#salesforce-modal-wrapper-credential-select[name='credential_id']"
             )
    end
  end

  describe "Salesforce Modal - without credential" do
    setup %{conn: conn} do
      user = user_fixture()
      meeting = meeting_fixture_with_transcript(user)

      %{
        conn: log_in_user(conn, user),
        user: user,
        meeting: meeting
      }
    end

    test "does not show Salesforce section when no credential", %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}")

      refute html =~ "Salesforce Integration"
      refute html =~ "Update Salesforce Contact"
    end

    test "salesforce route does not render modal without credential", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/crm/salesforce")
      refute html =~ "salesforce-modal-wrapper"
    end
  end

  defp meeting_fixture_with_transcript(user) do
    meeting = meeting_fixture(%{})

    calendar_event = SocialScribe.Calendar.get_calendar_event!(meeting.calendar_event_id)

    {:ok, _updated_event} =
      SocialScribe.Calendar.update_calendar_event(calendar_event, %{user_id: user.id})

    meeting_transcript_fixture(%{
      meeting_id: meeting.id,
      content: %{
        "data" => [
          %{
            "speaker" => "John Doe",
            "words" => [
              %{"text" => "Call"},
              %{"text" => "me"},
              %{"text" => "at"},
              %{"text" => "555-1234"}
            ]
          }
        ]
      }
    })

    SocialScribe.Meetings.get_meeting_with_details(meeting.id)
  end
end
