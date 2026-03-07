defmodule SocialScribeWeb.HubspotModalMoxTest do
  use SocialScribeWeb.ConnCase

  import Phoenix.LiveViewTest
  import SocialScribe.AccountsFixtures
  import SocialScribe.MeetingsFixtures
  import Mox

  setup :verify_on_exit!

  describe "HubSpot Modal with mocked API" do
    setup %{conn: conn} do
      user = user_fixture()
      hubspot_credential = hubspot_credential_fixture(%{user_id: user.id})
      meeting = meeting_fixture_with_transcript(user)

      %{
        conn: log_in_user(conn, user),
        user: user,
        meeting: meeting,
        hubspot_credential: hubspot_credential
      }
    end

    test "search_contacts returns mocked results", %{conn: conn, meeting: meeting} do
      mock_contacts = [
        %{
          id: "123",
          firstname: "John",
          lastname: "Doe",
          email: "john@example.com",
          phone: nil,
          company: "Acme Corp",
          display_name: "John Doe"
        },
        %{
          id: "456",
          firstname: "Jane",
          lastname: "Smith",
          email: "jane@example.com",
          phone: "555-1234",
          company: "Tech Inc",
          display_name: "Jane Smith"
        }
      ]

      SocialScribe.HubspotApiMock
      |> expect(:search_contacts, fn _credential, query ->
        assert query == "John"
        {:ok, mock_contacts}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/hubspot")

      # Trigger contact search
      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "John"})

      # Wait for async update
      :timer.sleep(200)

      # Re-render to see updates
      html = render(view)

      # Verify contacts are displayed
      assert html =~ "John Doe"
      assert html =~ "Jane Smith"
    end

    test "search_contacts handles API error gracefully", %{conn: conn, meeting: meeting} do
      SocialScribe.HubspotApiMock
      |> expect(:search_contacts, fn _credential, _query ->
        {:error, {:api_error, 500, %{"message" => "Internal server error"}}}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/hubspot")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "Test"})

      :timer.sleep(200)

      html = render(view)

      # Should show error message
      assert html =~ "Failed to search contacts"
    end

    test "selecting contact triggers suggestion generation", %{conn: conn, meeting: meeting} do
      mock_contact = %{
        id: "123",
        firstname: "John",
        lastname: "Doe",
        email: "john@example.com",
        phone: nil,
        company: "Acme Corp",
        display_name: "John Doe"
      }

      mock_suggestions = [
        %{
          field: "phone",
          value: "555-1234",
          context: "Mentioned phone number"
        }
      ]

      SocialScribe.HubspotApiMock
      |> expect(:search_contacts, fn _credential, _query ->
        {:ok, [mock_contact]}
      end)

      # Also need to mock the AI content generator for suggestions
      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_hubspot_suggestions, fn _meeting ->
        {:ok, mock_suggestions}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/hubspot")

      # Search for contact
      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "John"})

      :timer.sleep(200)

      # Select the contact (it's a button, not li)
      view
      |> element("button[phx-click='select_contact'][phx-value-id='123']")
      |> render_click()

      :timer.sleep(500)

      # After selecting contact, suggestions should be generated
      # Modal should still be present
      assert has_element?(view, "#hubspot-modal-wrapper")
    end

    test "contact dropdown shows search results", %{conn: conn, meeting: meeting} do
      mock_contact = %{
        id: "789",
        firstname: "Test",
        lastname: "User",
        email: "test@example.com",
        phone: nil,
        company: nil,
        display_name: "Test User"
      }

      SocialScribe.HubspotApiMock
      |> expect(:search_contacts, fn _credential, _query ->
        {:ok, [mock_contact]}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/hubspot")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "Test"})

      :timer.sleep(200)

      html = render(view)

      # Verify contact appears in dropdown
      assert html =~ "Test User"
      assert html =~ "test@example.com"
    end

    test "toggle hide details collapses and expands suggestion details", %{
      conn: conn,
      meeting: meeting
    } do
      mock_contact = %{
        id: "123",
        firstname: "John",
        lastname: "Doe",
        email: "john@example.com",
        phone: nil,
        company: "Acme Corp",
        display_name: "John Doe"
      }

      SocialScribe.HubspotApiMock
      |> expect(:search_contacts, fn _credential, _query -> {:ok, [mock_contact]} end)

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_hubspot_suggestions, fn _meeting ->
        {:ok,
         [
           %{
             field: "phone",
             value: "555-1234",
             context: "Mentioned phone number"
           }
         ]}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/hubspot")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "John"})

      :timer.sleep(200)

      view
      |> element("button[phx-click='select_contact'][phx-value-id='123']")
      |> render_click()

      :timer.sleep(300)

      assert has_element?(
               view,
               "button[phx-click='toggle_suggestion_details'][aria-label='Hide details']"
             )

      assert has_element?(view, "input[name^='values[']")

      view
      |> element("button[phx-click='toggle_suggestion_details']")
      |> render_click()

      refute has_element?(view, "input[name^='values[']")

      assert has_element?(
               view,
               "button[phx-click='toggle_suggestion_details'][aria-label='Show details']"
             )
    end

    test "submit error keeps modal open and restores cancel action", %{
      conn: conn,
      meeting: meeting
    } do
      mock_contact = %{
        id: "123",
        firstname: "John",
        lastname: "Doe",
        email: "john@example.com",
        phone: nil,
        company: "Acme Corp",
        display_name: "John Doe"
      }

      SocialScribe.HubspotApiMock
      |> expect(:search_contacts, fn _credential, _query -> {:ok, [mock_contact]} end)
      |> expect(:update_contact, fn _credential, "123", %{"phone" => "555-1234"} ->
        :timer.sleep(250)
        {:error, {:api_error, 500, %{"message" => "boom"}}}
      end)

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_hubspot_suggestions, fn _meeting ->
        {:ok,
         [
           %{
             field: "phone",
             value: "555-1234",
             context: "Mentioned phone number"
           }
         ]}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/hubspot")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "John"})

      :timer.sleep(200)

      view
      |> element("button[phx-click='select_contact'][phx-value-id='123']")
      |> render_click()

      :timer.sleep(300)

      row_id = row_id_for_mapped_field(render(view), "phone")
      refute is_nil(row_id)

      view
      |> element("form[phx-submit='apply_updates']")
      |> render_submit(%{
        "apply" => %{row_id => "1"},
        "values" => %{row_id => "555-1234"}
      })

      :timer.sleep(350)

      unlocked_html = render(view)
      assert has_element?(view, "button[type='submit']", "Update HubSpot")
      assert has_element?(view, "button", "Cancel")
      assert unlocked_html =~ "Failed to update contact"
      assert has_element?(view, "#hubspot-modal-wrapper")
    end

    test "provider capabilities include shared details toggle and submit lock behavior" do
      capabilities = SocialScribe.CRM.Providers.Hubspot.Provider.capabilities()

      assert capabilities.details_toggle
      assert capabilities.lock_on_submit
      refute capabilities.mapping_toggle
      refute capabilities.paired_fields
    end
  end

  describe "HubSpot API behavior delegation" do
    setup do
      user = user_fixture()
      credential = hubspot_credential_fixture(%{user_id: user.id})
      %{credential: credential}
    end

    test "search_contacts delegates to implementation", %{credential: credential} do
      expected = [%{id: "1", firstname: "Test", lastname: "User"}]

      SocialScribe.HubspotApiMock
      |> expect(:search_contacts, fn _cred, query ->
        assert query == "test query"
        {:ok, expected}
      end)

      impl = Application.fetch_env!(:social_scribe, :hubspot_api)

      assert {:ok, ^expected} =
               impl.search_contacts(credential, "test query")
    end

    test "get_contact delegates to implementation", %{credential: credential} do
      expected = %{id: "123", firstname: "John", lastname: "Doe"}

      SocialScribe.HubspotApiMock
      |> expect(:get_contact, fn _cred, contact_id ->
        assert contact_id == "123"
        {:ok, expected}
      end)

      impl = Application.fetch_env!(:social_scribe, :hubspot_api)
      assert {:ok, ^expected} = impl.get_contact(credential, "123")
    end

    test "update_contact delegates to implementation", %{credential: credential} do
      updates = %{"phone" => "555-1234", "company" => "New Corp"}
      expected = %{id: "123", phone: "555-1234", company: "New Corp"}

      SocialScribe.HubspotApiMock
      |> expect(:update_contact, fn _cred, contact_id, upd ->
        assert contact_id == "123"
        assert upd == updates
        {:ok, expected}
      end)

      impl = Application.fetch_env!(:social_scribe, :hubspot_api)

      assert {:ok, ^expected} =
               impl.update_contact(credential, "123", updates)
    end

    test "apply_updates delegates to implementation", %{credential: credential} do
      updates_list = [
        %{field: "phone", new_value: "555-1234", apply: true},
        %{field: "email", new_value: "test@example.com", apply: false}
      ]

      SocialScribe.HubspotApiMock
      |> expect(:apply_updates, fn _cred, contact_id, list ->
        assert contact_id == "123"
        assert list == updates_list
        {:ok, %{id: "123"}}
      end)

      impl = Application.fetch_env!(:social_scribe, :hubspot_api)
      assert {:ok, _} = impl.apply_updates(credential, "123", updates_list)
    end
  end

  # Helper function to create a meeting with transcript for testing
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
              %{"text" => "Hello,"},
              %{"text" => "my"},
              %{"text" => "phone"},
              %{"text" => "is"},
              %{"text" => "555-1234"}
            ]
          }
        ]
      }
    })

    SocialScribe.Meetings.get_meeting_with_details(meeting.id)
  end

  defp row_id_for_mapped_field(html, mapped_field) do
    Regex.run(
      ~r/name=\"mapped_fields\[([^\]]+)\]\"[^>]*value=\"#{mapped_field}\"/s,
      html,
      capture: :all_but_first
    )
    |> case do
      [row_id] -> row_id
      _ -> nil
    end
  end
end
