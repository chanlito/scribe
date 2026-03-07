defmodule SocialScribeWeb.SalesforceModalMoxTest do
  use SocialScribeWeb.ConnCase

  import Phoenix.LiveViewTest
  import SocialScribe.AccountsFixtures
  import SocialScribe.MeetingsFixtures
  import Mox

  setup :verify_on_exit!

  describe "Salesforce Modal with mocked API" do
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

    test "search_contacts returns mocked results", %{conn: conn, meeting: meeting} do
      mock_contacts = [
        %{
          id: "003123",
          firstname: "John",
          lastname: "Doe",
          email: "john@example.com",
          phone: "555-1111",
          display_name: "John Doe"
        }
      ]

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _credential, query ->
        assert query == "John"
        {:ok, mock_contacts}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "John"})

      :timer.sleep(200)
      html = render(view)

      assert html =~ "John Doe"
      assert html =~ "john@example.com"
    end

    test "opening dropdown loads contacts without typing", %{conn: conn, meeting: meeting} do
      mock_contacts = [
        %{
          id: "003888",
          firstname: "Taylor",
          lastname: "Harris",
          email: "taylor@example.com",
          phone: nil,
          display_name: "Taylor Harris"
        }
      ]

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _credential, query ->
        assert query == ""
        {:ok, mock_contacts}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      view
      |> element("input[phx-focus='open_contact_dropdown']")
      |> render_focus()

      :timer.sleep(200)

      html = render(view)
      assert html =~ "Taylor Harris"
      assert html =~ "taylor@example.com"
    end

    test "shows reconnect guidance when search cannot be securely scoped", %{
      conn: conn,
      meeting: meeting
    } do
      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _credential, _query ->
        {:error,
         {:reconnect_required,
          "Salesforce identity is missing. Please reconnect Salesforce to search only contacts you own."}}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "John"})

      :timer.sleep(200)
      html = render(view)

      assert html =~ "Please reconnect Salesforce"
    end

    test "selecting contact triggers Salesforce suggestions generation", %{
      conn: conn,
      meeting: meeting
    } do
      mock_contact = %{
        id: "003123",
        firstname: "John",
        lastname: "Doe",
        email: "john@example.com",
        phone: nil,
        display_name: "John Doe"
      }

      mock_suggestions = [
        %{
          field: "phone",
          value: "555-1234",
          context: "My phone is 555-1234",
          timestamp: "00:21"
        }
      ]

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _credential, _query ->
        {:ok, [mock_contact]}
      end)

      SocialScribe.SalesforceApiMock
      |> expect(:describe_contact_fields, fn _credential ->
        {:ok, []}
      end)

      SocialScribe.SalesforceApiMock
      |> expect(:get_contact, fn _credential, contact_id ->
        assert contact_id == "003123"
        {:ok, Map.put(mock_contact, :fields, %{})}
      end)

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting, custom_fields ->
        assert custom_fields == []
        {:ok, mock_suggestions}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "John"})

      :timer.sleep(200)

      view
      |> element("button[phx-click='select_contact'][phx-value-id='003123']")
      |> render_click()

      :timer.sleep(300)

      assert has_element?(view, "#salesforce-modal-wrapper")
      assert render(view) =~ "Update Salesforce"
    end

    test "shows friendly message when Gemini rate limit is hit", %{conn: conn, meeting: meeting} do
      mock_contact = %{
        id: "003123",
        firstname: "John",
        lastname: "Doe",
        email: "john@example.com",
        phone: nil,
        display_name: "John Doe"
      }

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _credential, _query ->
        {:ok, [mock_contact]}
      end)

      SocialScribe.SalesforceApiMock
      |> expect(:describe_contact_fields, fn _credential ->
        {:ok, []}
      end)

      SocialScribe.SalesforceApiMock
      |> expect(:get_contact, fn _credential, contact_id ->
        assert contact_id == "003123"
        {:ok, Map.put(mock_contact, :fields, %{})}
      end)

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting, _custom_fields ->
        {:error,
         {:api_error, 429,
          %{
            "error" => %{
              "details" => [
                %{
                  "@type" => "type.googleapis.com/google.rpc.RetryInfo",
                  "retryDelay" => "31.2s"
                }
              ]
            }
          }}}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "John"})

      :timer.sleep(200)

      view
      |> element("button[phx-click='select_contact'][phx-value-id='003123']")
      |> render_click()

      :timer.sleep(300)

      html = render(view)
      assert html =~ "AI suggestion generation is rate-limited by Gemini quota."
      assert html =~ "retry in about 32 seconds"
    end

    test "toggle hide details collapses and expands suggestion details", %{
      conn: conn,
      meeting: meeting
    } do
      mock_contact = %{
        id: "003123",
        firstname: "John",
        lastname: "Doe",
        email: "john@example.com",
        phone: nil,
        display_name: "John Doe"
      }

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _credential, _query -> {:ok, [mock_contact]} end)
      |> expect(:describe_contact_fields, fn _credential ->
        {:ok, [%{name: "Phone", label: "Phone", type: "phone"}]}
      end)
      |> expect(:get_contact, fn _credential, "003123" ->
        {:ok, Map.put(mock_contact, :fields, %{})}
      end)

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting, _custom_fields ->
        {:ok,
         [
           %{
             field: "phone",
             value: "555-1234",
             context: "My phone is 555-1234",
             timestamp: "00:21"
           }
         ]}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "John"})

      :timer.sleep(200)

      view
      |> element("button[phx-click='select_contact'][phx-value-id='003123']")
      |> render_click()

      :timer.sleep(300)

      assert has_element?(
               view,
               "button[phx-click='toggle_suggestion_details'][aria-label='Hide details']"
             )

      assert has_element?(view, "input[name^='values[']")
      assert has_element?(view, "input[name^='values['][value='555-1234']")

      view
      |> element("button[phx-click='toggle_suggestion_details']")
      |> render_click()

      refute has_element?(view, "input[name^='values[']")

      assert has_element?(
               view,
               "button[phx-click='toggle_suggestion_details'][aria-label='Show details']"
             )
    end

    test "update mapping remaps field label and existing value", %{conn: conn, meeting: meeting} do
      mock_contact = %{
        id: "003123",
        firstname: "Ani",
        lastname: "Harris",
        email: "ani@example.com",
        phone: nil,
        display_name: "Ani Harris"
      }

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _credential, _query -> {:ok, [mock_contact]} end)
      |> expect(:describe_contact_fields, fn _credential ->
        {:ok,
         [
           %{name: "FirstName", label: "First Name", type: "string"},
           %{name: "LastName", label: "Last Name", type: "string"}
         ]}
      end)
      |> expect(:get_contact, fn _credential, "003123" ->
        {:ok, Map.put(mock_contact, :fields, %{})}
      end)

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting, _custom_fields ->
        {:ok,
         [
           %{
             field: "firstname",
             value: "Tyler",
             context: "Please update first name to Tyler",
             timestamp: "01:19"
           }
         ]}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "Ani"})

      :timer.sleep(200)

      view
      |> element("button[phx-click='select_contact'][phx-value-id='003123']")
      |> render_click()

      :timer.sleep(300)

      view
      |> element("button[phx-click='toggle_suggestion_mapping']")
      |> render_click()

      html = render(view)
      [row_id] = suggestion_ids(html)

      view
      |> element("form[phx-submit='apply_updates']")
      |> render_change(%{
        "apply" => %{row_id => "1"},
        "values" => %{row_id => "Tyler"},
        "mapped_fields" => %{row_id => "lastname"}
      })

      html = render(view)
      assert html =~ "Last Name"
      assert html =~ "Harris"
      assert has_element?(view, "input[name^='values['][value='Tyler']")
    end

    test "duplicate mapped fields are blocked before submit", %{conn: conn, meeting: meeting} do
      mock_contact = %{
        id: "003123",
        firstname: "Ani",
        lastname: "Harris",
        email: "ani@example.com",
        phone: nil,
        display_name: "Ani Harris"
      }

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _credential, _query -> {:ok, [mock_contact]} end)
      |> expect(:describe_contact_fields, fn _credential ->
        {:ok,
         [
           %{name: "FirstName", label: "First Name", type: "string"},
           %{name: "LastName", label: "Last Name", type: "string"}
         ]}
      end)
      |> expect(:get_contact, fn _credential, "003123" ->
        {:ok, Map.put(mock_contact, :fields, %{})}
      end)

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting, _custom_fields ->
        {:ok,
         [
           %{
             field: "firstname",
             value: "Tyler",
             context: "First name update",
             timestamp: "00:27"
           },
           %{
             field: "lastname",
             value: "Harrison",
             context: "Last name update",
             timestamp: "01:19"
           }
         ]}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "Ani"})

      :timer.sleep(200)

      view
      |> element("button[phx-click='select_contact'][phx-value-id='003123']")
      |> render_click()

      :timer.sleep(300)

      ids = suggestion_ids(render(view))
      assert length(ids) == 2

      params = %{
        "apply" => Map.new(ids, &{&1, "1"}),
        "values" => %{
          Enum.at(ids, 0) => "Tyler",
          Enum.at(ids, 1) => "Harrison"
        },
        "mapped_fields" => %{
          Enum.at(ids, 0) => "firstname",
          Enum.at(ids, 1) => "firstname"
        }
      }

      _html =
        view
        |> element("form[phx-submit='apply_updates']")
        |> render_change(params)

      assert has_element?(view, "#salesforce-modal-wrapper")
    end

    test "invalid update submission keeps the Salesforce modal open", %{
      conn: conn,
      meeting: meeting
    } do
      mock_contact = %{
        id: "003123",
        firstname: "Ani",
        lastname: "Harris",
        email: "ani@example.com",
        phone: nil,
        display_name: "Ani Harris",
        fields: %{"Account_Value__c" => "50000"}
      }

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _credential, _query -> {:ok, [mock_contact]} end)
      |> expect(:describe_contact_fields, fn _credential ->
        {:ok, [%{name: "Account_Value__c", label: "Account Value", type: "currency"}]}
      end)
      |> expect(:get_contact, fn _credential, "003123" -> {:ok, mock_contact} end)
      |> expect(:update_contact, fn _credential,
                                    "003123",
                                    %{"Account_Value__c" => "invalid currency"} ->
        {:error,
         {:invalid_updates,
          [
            %{
              field: "Account_Value__c",
              message: "must be a valid currency value"
            }
          ]}}
      end)

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting, _custom_fields ->
        {:ok,
         [
           %{
             field: "Account_Value__c",
             value: "137,143",
             context: "Account value updated",
             timestamp: "01:19"
           }
         ]}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "Ani"})

      :timer.sleep(200)

      view
      |> element("button[phx-click='select_contact'][phx-value-id='003123']")
      |> render_click()

      :timer.sleep(300)

      [row_id] = suggestion_ids(render(view))

      view
      |> element("form[phx-submit='apply_updates']")
      |> render_submit(%{
        "apply" => %{row_id => "1"},
        "values" => %{row_id => "invalid currency"},
        "mapped_fields" => %{row_id => "Account_Value__c"}
      })

      :timer.sleep(200)
      html = render(view)

      assert html =~ "Update in Salesforce"
      assert html =~ "Account Value"
      assert has_element?(view, "#salesforce-modal-wrapper")
    end

    test "malformed field-name suggestions do not render in the Salesforce modal", %{
      conn: conn,
      meeting: meeting
    } do
      mock_contact = %{
        id: "003123",
        firstname: "Ani",
        lastname: "Harris",
        email: "ani@example.com",
        phone: nil,
        display_name: "Ani Harris",
        fields: %{"Account_Value__c" => "20000"}
      }

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _credential, _query -> {:ok, [mock_contact]} end)
      |> expect(:describe_contact_fields, fn _credential ->
        {:ok,
         [
           %{name: "MailingPostalCode", label: "Mailing Postal Code", type: "string"},
           %{name: "Account_Value__c", label: "Account Value", type: "currency"},
           %{
             name: "retirement_savings_rate__c",
             label: "Retirement savings rate",
             type: "percent"
           }
         ]}
      end)
      |> expect(:get_contact, fn _credential, "003123" -> {:ok, mock_contact} end)

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting, _custom_fields ->
        {:ok,
         [
           %{
             field: "mailingpostalcode",
             value: "mailingpostalcode",
             context: "mailingpostalcode",
             timestamp: "01:34"
           },
           %{
             field: "Account_Value__c",
             value: "account_value__c",
             context: "account_value__c",
             timestamp: "01:46"
           },
           %{
             field: "retirement_savings_rate__c",
             value: "retirement_savings_rate__c",
             context: "retirement_savings_rate__c",
             timestamp: "01:57"
           }
         ]}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "Ani"})

      :timer.sleep(200)

      view
      |> element("button[phx-click='select_contact'][phx-value-id='003123']")
      |> render_click()

      :timer.sleep(300)

      html = render(view)

      refute html =~ "mailingpostalcode"
      refute html =~ "account_value__c"
      refute html =~ "retirement_savings_rate__c"
      assert html =~ "No update suggestions found from this meeting."
    end
  end

  describe "Salesforce API behavior delegation" do
    setup do
      user = user_fixture()
      credential = salesforce_credential_fixture(%{user_id: user.id})
      %{credential: credential}
    end

    test "search_contacts delegates to implementation", %{credential: credential} do
      expected = [%{id: "0031", firstname: "Test", lastname: "User"}]

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _cred, query ->
        assert query == "test query"
        {:ok, expected}
      end)

      assert {:ok, ^expected} =
               SocialScribe.SalesforceApiBehaviour.search_contacts(credential, "test query")
    end

    test "get_contact delegates to implementation", %{credential: credential} do
      expected = %{id: "0031", firstname: "John", lastname: "Doe"}

      SocialScribe.SalesforceApiMock
      |> expect(:get_contact, fn _cred, contact_id ->
        assert contact_id == "0031"
        {:ok, expected}
      end)

      assert {:ok, ^expected} =
               SocialScribe.SalesforceApiBehaviour.get_contact(credential, "0031")
    end

    test "update_contact delegates to implementation", %{credential: credential} do
      updates = %{"phone" => "555-1234"}
      expected = %{id: "0031", phone: "555-1234"}

      SocialScribe.SalesforceApiMock
      |> expect(:update_contact, fn _cred, contact_id, upd ->
        assert contact_id == "0031"
        assert upd == updates
        {:ok, expected}
      end)

      assert {:ok, ^expected} =
               SocialScribe.SalesforceApiBehaviour.update_contact(credential, "0031", updates)
    end

    test "apply_updates delegates to implementation", %{credential: credential} do
      updates_list = [%{field: "phone", new_value: "555-1234", apply: true}]

      SocialScribe.SalesforceApiMock
      |> expect(:apply_updates, fn _cred, contact_id, list ->
        assert contact_id == "0031"
        assert list == updates_list
        {:ok, %{id: "0031"}}
      end)

      assert {:ok, _} =
               SocialScribe.SalesforceApiBehaviour.apply_updates(credential, "0031", updates_list)
    end

    test "describe_contact_fields delegates to implementation", %{credential: credential} do
      expected = [%{name: "Retirement_Savings_Rate__c", label: "Retirement Savings Rate"}]

      SocialScribe.SalesforceApiMock
      |> expect(:describe_contact_fields, fn _cred ->
        {:ok, expected}
      end)

      assert {:ok, ^expected} =
               SocialScribe.SalesforceApiBehaviour.describe_contact_fields(credential)
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
              %{"text" => "Phone"},
              %{"text" => "is"},
              %{"text" => "555-1234"}
            ]
          }
        ]
      }
    })

    SocialScribe.Meetings.get_meeting_with_details(meeting.id)
  end

  defp suggestion_ids(html) do
    Regex.scan(~r/mapped_fields\[([^\]]+)\]/, html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end
end
