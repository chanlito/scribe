defmodule SocialScribeWeb.MeetingLive.ShowTest do
  use SocialScribeWeb.ConnCase

  import Phoenix.LiveViewTest
  import SocialScribe.AccountsFixtures
  import SocialScribe.MeetingsFixtures

  describe "meeting details transcript speaker names" do
    setup %{conn: conn} do
      user = user_fixture()

      %{
        conn: log_in_user(conn, user),
        user: user
      }
    end

    test "renders nested participant names instead of Unknown Speaker", %{
      conn: conn,
      user: user
    } do
      meeting =
        meeting_fixture_with_transcript(user, %{
          "data" => [
            %{
              "participant" => %{"id" => 100, "name" => "Nested Speaker"},
              "words" => [%{"text" => "Hello"}]
            }
          ]
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}")

      assert html =~ "Nested Speaker:"
      refute html =~ "Unknown Speaker"
    end

    test "renders atom-keyed speaker names instead of Unknown Speaker", %{
      conn: conn,
      user: user
    } do
      meeting =
        meeting_fixture_with_transcript(user, %{
          "data" => [
            %{
              speaker: "Atom Speaker",
              words: [%{text: "Hello from atoms"}]
            }
          ]
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}")

      assert html =~ "Atom Speaker:"
      assert html =~ "Hello from atoms"
      refute html =~ "Unknown Speaker"
    end

    test "renders participant names from speaker ids when speaker is missing", %{
      conn: conn,
      user: user
    } do
      meeting =
        meeting_fixture_with_transcript(
          user,
          %{
            "data" => [
              %{
                "speaker_id" => 321,
                "words" => [%{"text" => "Fallback"}]
              }
            ]
          },
          [
            %{name: "Matched Participant", recall_participant_id: "321", is_host: false}
          ]
        )

      {:ok, _view, html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}")

      assert html =~ "Matched Participant:"
      refute html =~ "Unknown Speaker"
    end
  end

  defp meeting_fixture_with_transcript(user, transcript_content, participants \\ []) do
    meeting = meeting_fixture()

    calendar_event = SocialScribe.Calendar.get_calendar_event!(meeting.calendar_event_id)

    {:ok, _updated_event} =
      SocialScribe.Calendar.update_calendar_event(calendar_event, %{user_id: user.id})

    meeting_transcript_fixture(%{
      meeting_id: meeting.id,
      content: transcript_content
    })

    Enum.each(participants, fn participant_attrs ->
      meeting_participant_fixture(Map.put(participant_attrs, :meeting_id, meeting.id))
    end)

    SocialScribe.Meetings.get_meeting_with_details(meeting.id)
  end
end
