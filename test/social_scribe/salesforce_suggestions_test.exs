defmodule SocialScribe.SalesforceSuggestionsTest do
  use SocialScribe.DataCase

  import Mox
  import SocialScribe.AccountsFixtures

  alias SocialScribe.SalesforceSuggestions

  setup :verify_on_exit!

  describe "merge_with_contact/2" do
    test "merges suggestions with contact data and filters unchanged values" do
      suggestions = [
        %{
          field: "phone",
          label: "Phone",
          current_value: nil,
          new_value: "555-1234",
          context: "Mentioned in call",
          apply: false,
          has_change: true
        },
        %{
          field: "title",
          label: "Title",
          current_value: nil,
          new_value: "Director",
          context: "Title mentioned",
          apply: false,
          has_change: true
        }
      ]

      contact = %{
        id: "003123",
        phone: nil,
        title: "Director",
        email: "test@example.com"
      }

      result = SalesforceSuggestions.merge_with_contact(suggestions, contact)

      assert length(result) == 1
      assert hd(result).field == "phone"
      assert hd(result).new_value == "555-1234"
    end

    test "returns empty list when all suggestions match current values" do
      suggestions = [
        %{
          field: "email",
          label: "Email",
          current_value: nil,
          new_value: "test@example.com",
          context: "Email mentioned",
          apply: false,
          has_change: true
        }
      ]

      contact = %{
        id: "003123",
        email: "test@example.com"
      }

      assert SalesforceSuggestions.merge_with_contact(suggestions, contact) == []
    end

    test "normalizes email suggestions to lowercase" do
      suggestions = [
        %{
          field: "email",
          label: "Email",
          current_value: nil,
          new_value: "Michael.Thompson@northgatepartners.com",
          context: "Email mentioned",
          apply: false,
          has_change: true
        }
      ]

      contact = %{
        id: "003123",
        email: nil
      }

      [result] = SalesforceSuggestions.merge_with_contact(suggestions, contact)
      assert result.new_value == "michael.thompson@northgatepartners.com"
    end

    test "dedupes duplicate field/value suggestions and keeps the most recent timestamp" do
      suggestions = [
        %{
          field: "firstname",
          label: "First Name",
          current_value: nil,
          new_value: "Tyler",
          context: "Mentioned early",
          timestamp: "00:27",
          apply: true,
          has_change: true
        },
        %{
          field: "firstname",
          label: "First Name",
          current_value: nil,
          new_value: "Tyler",
          context: "Mentioned again later",
          timestamp: "01:19",
          apply: true,
          has_change: true
        }
      ]

      contact = %{id: "003123", firstname: "Ani"}

      result = SalesforceSuggestions.merge_with_contact(suggestions, contact)

      assert length(result) == 1
      assert hd(result).field == "firstname"
      assert hd(result).new_value == "Tyler"
      assert hd(result).timestamp == "01:19"
      assert hd(result).context == "Mentioned again later"
    end

    test "reads existing value for custom Salesforce field from raw fields map" do
      suggestions = [
        %{
          field: "Account_Value__c",
          label: "Account Value",
          current_value: nil,
          new_value: "$60,000.00",
          context: "Updated account value",
          timestamp: "01:19",
          apply: true,
          has_change: true
        }
      ]

      contact = %{
        id: "003123",
        fields: %{"Account_Value__c" => "$50,000.00"}
      }

      result = SalesforceSuggestions.merge_with_contact(suggestions, contact)

      assert length(result) == 1
      assert hd(result).current_value == "$50,000.00"
      assert hd(result).has_change == true
    end

    test "formats scientific numeric existing values into plain numbers" do
      suggestions = [
        %{
          field: "Account_Value__c",
          label: "Account Value",
          current_value: nil,
          new_value: "60000",
          context: "Updated account value",
          timestamp: "01:19",
          apply: true,
          has_change: true
        }
      ]

      contact = %{
        id: "003123",
        fields: %{"Account_Value__c" => 5.0e4}
      }

      result = SalesforceSuggestions.merge_with_contact(suggestions, contact)

      assert length(result) == 1
      assert hd(result).current_value == "50000"
    end

    test "treats numerically equivalent values as unchanged" do
      suggestions = [
        %{
          field: "Account_Value__c",
          label: "Account Value",
          current_value: nil,
          new_value: "50000",
          context: "Mentioned value",
          timestamp: "01:19",
          apply: true,
          has_change: true
        }
      ]

      contact = %{
        id: "003123",
        fields: %{"Account_Value__c" => 5.0e4}
      }

      result = SalesforceSuggestions.merge_with_contact(suggestions, contact)
      assert result == []
    end
  end

  describe "generate_suggestions/3 timestamp resolution" do
    test "resolves timestamp from transcript context and dedupes using most recent mention" do
      user = user_fixture()
      credential = salesforce_credential_fixture(%{user_id: user.id})

      meeting = %{
        meeting_transcript: %{
          content: %{
            "data" => [
              %{
                "words" => [
                  %{"text" => "My"},
                  %{"text" => "first"},
                  %{"text" => "name"},
                  %{"text" => "is"},
                  %{"text" => "Tyler", "start_timestamp" => 27.0}
                ]
              },
              %{
                "words" => [
                  %{"text" => "Please"},
                  %{"text" => "update"},
                  %{"text" => "my"},
                  %{"text" => "first"},
                  %{"text" => "name"},
                  %{"text" => "to"},
                  %{"text" => "Tyler", "start_timestamp" => 79.0}
                ]
              }
            ]
          }
        }
      }

      contact = %{id: "003123", firstname: "Ani", fields: %{}}

      SocialScribe.SalesforceApiMock
      |> expect(:describe_contact_fields, fn _credential ->
        {:ok, [%{name: "FirstName", label: "First Name", type: "string"}]}
      end)
      |> expect(:get_contact, fn _credential, "003123" ->
        {:ok, contact}
      end)

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting, _custom_fields ->
        {:ok,
         [
           %{
             field: "firstname",
             value: "Tyler",
             context: "My first name is Tyler",
             timestamp: "00:27"
           },
           %{
             field: "firstname",
             value: "Tyler",
             context: "Please update my first name to Tyler",
             timestamp: "01:19"
           }
         ]}
      end)

      assert {:ok, %{suggestions: [suggestion], mapping_fields: mapping_fields}} =
               SalesforceSuggestions.generate_suggestions(credential, "003123", meeting)

      assert suggestion.timestamp == "01:19"
      assert suggestion.context == "Please update my first name to Tyler"
      assert Enum.any?(mapping_fields, &(&1.name == "firstname"))
    end

    test "falls back to AI timestamp when transcript match is missing" do
      user = user_fixture()
      credential = salesforce_credential_fixture(%{user_id: user.id})

      meeting = %{
        meeting_transcript: %{
          content: %{
            "data" => [
              %{
                "words" => [
                  %{"text" => "Unrelated", "start_timestamp" => 10.0}
                ]
              }
            ]
          }
        }
      }

      SocialScribe.SalesforceApiMock
      |> expect(:describe_contact_fields, fn _credential ->
        {:ok, [%{name: "Phone", label: "Phone", type: "phone"}]}
      end)
      |> expect(:get_contact, fn _credential, "003123" ->
        {:ok, %{id: "003123", phone: nil, fields: %{}}}
      end)

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting, _custom_fields ->
        {:ok,
         [
           %{
             field: "phone",
             value: "5551234",
             context: "Call me maybe",
             timestamp: "02:10"
           }
         ]}
      end)

      assert {:ok, %{suggestions: [suggestion]}} =
               SalesforceSuggestions.generate_suggestions(credential, "003123", meeting)

      assert suggestion.timestamp == "02:10"
    end

    test "resolves different timestamps for multiple suggestions inside one transcript segment" do
      user = user_fixture()
      credential = salesforce_credential_fixture(%{user_id: user.id})

      meeting = %{
        meeting_transcript: %{
          content: %{
            "data" => [
              %{
                "words" => [
                  %{"text" => "My", "start_timestamp" => 12.0},
                  %{"text" => "mobile", "start_timestamp" => 13.0},
                  %{"text" => "phone", "start_timestamp" => 14.0},
                  %{"text" => "is", "start_timestamp" => 15.0},
                  %{"text" => "888550199", "start_timestamp" => 16.0},
                  %{"text" => "and", "start_timestamp" => 17.0},
                  %{"text" => "my", "start_timestamp" => 18.0},
                  %{"text" => "address", "start_timestamp" => 19.0},
                  %{"text" => "is", "start_timestamp" => 20.0},
                  %{"text" => "1420", "start_timestamp" => 21.0},
                  %{"text" => "Park", "start_timestamp" => 22.0},
                  %{"text" => "Avenue", "start_timestamp" => 23.0},
                  %{"text" => "apartment", "start_timestamp" => 24.0},
                  %{"text" => "6B", "start_timestamp" => 25.0},
                  %{"text" => "San", "start_timestamp" => 26.0},
                  %{"text" => "Diego", "start_timestamp" => 27.0}
                ]
              }
            ]
          }
        }
      }

      SocialScribe.SalesforceApiMock
      |> expect(:describe_contact_fields, fn _credential ->
        {:ok,
         [
           %{name: "MobilePhone", label: "Mobile Phone", type: "phone"},
           %{name: "MailingStreet", label: "Mailing Street", type: "string"},
           %{name: "MailingCity", label: "Mailing City", type: "string"}
         ]}
      end)
      |> expect(:get_contact, fn _credential, "003123" ->
        {:ok,
         %{id: "003123", mobilephone: nil, mailingstreet: nil, mailingcity: nil, fields: %{}}}
      end)

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting, _custom_fields ->
        {:ok,
         [
           %{
             field: "mobilephone",
             value: "888550199",
             context: "my mobile phone is 888550199",
             timestamp: "00:12"
           },
           %{
             field: "mailingstreet",
             value: "1420 Park Avenue apartment 6B",
             context: "my address is 1420 Park Avenue apartment 6B",
             timestamp: "00:12"
           },
           %{
             field: "mailingcity",
             value: "San Diego",
             context: "San Diego",
             timestamp: "00:12"
           }
         ]}
      end)

      assert {:ok, %{suggestions: suggestions}} =
               SalesforceSuggestions.generate_suggestions(credential, "003123", meeting)

      suggestions_by_field = Map.new(suggestions, &{&1.field, &1})

      assert suggestions_by_field["mobilephone"].timestamp == "00:16"
      assert suggestions_by_field["mailingstreet"].timestamp == "00:21"
      assert suggestions_by_field["mailingcity"].timestamp == "00:26"
    end

    test "filters malformed suggestions that repeat the Salesforce field identifier as the value" do
      user = user_fixture()
      credential = salesforce_credential_fixture(%{user_id: user.id})

      meeting = %{
        meeting_transcript: %{
          content: %{
            "data" => [
              %{
                "words" => [
                  %{"text" => "My", "start_timestamp" => 12.0},
                  %{"text" => "city", "start_timestamp" => 13.0},
                  %{"text" => "is", "start_timestamp" => 14.0},
                  %{"text" => "San", "start_timestamp" => 15.0},
                  %{"text" => "Diego", "start_timestamp" => 16.0}
                ]
              }
            ]
          }
        }
      }

      SocialScribe.SalesforceApiMock
      |> expect(:describe_contact_fields, fn _credential ->
        {:ok,
         [
           %{name: "MailingPostalCode", label: "Mailing Postal Code", type: "string"},
           %{name: "MailingCity", label: "Mailing City", type: "string"},
           %{name: "Account_Value__c", label: "Account Value", type: "currency"}
         ]}
      end)
      |> expect(:get_contact, fn _credential, "003123" ->
        {:ok, %{id: "003123", mailingpostalcode: nil, mailingcity: nil, fields: %{}}}
      end)

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
             value: "Account_Value__c",
             context: "Account_Value__c",
             timestamp: "01:46"
           },
           %{
             field: "mailingcity",
             value: "San Diego",
             context: "My city is San Diego",
             timestamp: "00:15"
           }
         ]}
      end)

      assert {:ok, %{suggestions: suggestions}} =
               SalesforceSuggestions.generate_suggestions(credential, "003123", meeting)

      assert Enum.map(suggestions, & &1.field) == ["mailingcity"]
      assert hd(suggestions).new_value == "San Diego"
    end
  end
end
