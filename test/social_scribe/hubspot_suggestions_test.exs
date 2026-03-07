defmodule SocialScribe.HubspotSuggestionsTest do
  use SocialScribe.DataCase

  import Mox

  alias SocialScribe.CRM.Providers.Hubspot.Suggestions

  setup :verify_on_exit!

  describe "generate_suggestions_from_meeting/1" do
    test "filters malformed values, unknown fields, and blank values" do
      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_hubspot_suggestions, fn _meeting ->
        {:ok,
         [
           %{
             field: "phone",
             value: "555-1234",
             context: "Call me at 555-1234",
             timestamp: "00:10"
           },
           %{field: "phone", value: "phone", context: "phone", timestamp: "00:12"},
           %{field: "unknown_field", value: "Acme", context: "Acme", timestamp: "00:20"},
           %{field: "email", value: "   ", context: "email", timestamp: "00:40"}
         ]}
      end)

      assert {:ok, suggestions} =
               Suggestions.generate_suggestions_from_meeting(%{
                 meeting_transcript: %{content: %{"data" => []}}
               })

      assert length(suggestions) == 1
      assert hd(suggestions).field == "phone"
      assert hd(suggestions).new_value == "555-1234"
    end

    test "dedupes by field/value and keeps the most recent timestamp" do
      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_hubspot_suggestions, fn _meeting ->
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

      assert {:ok, suggestions} =
               Suggestions.generate_suggestions_from_meeting(%{
                 meeting_transcript: %{content: %{"data" => []}}
               })

      assert length(suggestions) == 1
      assert hd(suggestions).field == "firstname"
      assert hd(suggestions).new_value == "Tyler"
      assert hd(suggestions).timestamp == "01:19"
      assert hd(suggestions).context == "Please update my first name to Tyler"
    end

    test "resolves timestamp from transcript context near AI timestamp" do
      meeting = %{
        meeting_transcript: %{
          content: %{
            "data" => [
              %{
                "words" => [
                  %{"text" => "My"},
                  %{"text" => "phone"},
                  %{"text" => "is"},
                  %{"text" => "5551234", "start_timestamp" => 27.0}
                ]
              },
              %{
                "words" => [
                  %{"text" => "Please"},
                  %{"text" => "update"},
                  %{"text" => "my"},
                  %{"text" => "phone"},
                  %{"text" => "to"},
                  %{"text" => "5551234", "start_timestamp" => 79.0}
                ]
              }
            ]
          }
        }
      }

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_hubspot_suggestions, fn _meeting ->
        {:ok,
         [
           %{
             field: "phone",
             value: "5551234",
             context: "My phone is 5551234",
             timestamp: "00:05"
           }
         ]}
      end)

      assert {:ok, [suggestion]} = Suggestions.generate_suggestions_from_meeting(meeting)
      assert suggestion.timestamp == "00:27"
    end

    test "prefers latest matching timestamp when AI timestamp is missing" do
      meeting = %{
        meeting_transcript: %{
          content: %{
            "data" => [
              %{
                "words" => [
                  %{"text" => "My"},
                  %{"text" => "phone"},
                  %{"text" => "is"},
                  %{"text" => "5551234", "start_timestamp" => 27.0}
                ]
              },
              %{
                "words" => [
                  %{"text" => "Please"},
                  %{"text" => "update"},
                  %{"text" => "my"},
                  %{"text" => "phone"},
                  %{"text" => "to"},
                  %{"text" => "5551234", "start_timestamp" => 79.0}
                ]
              }
            ]
          }
        }
      }

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_hubspot_suggestions, fn _meeting ->
        {:ok,
         [
           %{
             field: "phone",
             value: "5551234",
             context: "My phone is 5551234",
             timestamp: nil
           }
         ]}
      end)

      assert {:ok, [suggestion]} = Suggestions.generate_suggestions_from_meeting(meeting)
      assert suggestion.timestamp == "01:19"
    end

    test "does not trust AI timestamp when transcript has timing but no match" do
      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_hubspot_suggestions, fn _meeting ->
        {:ok,
         [
           %{field: "company", value: "Acme Corp", context: "Company update", timestamp: "2:5"}
         ]}
      end)

      assert {:ok, [suggestion]} =
               Suggestions.generate_suggestions_from_meeting(%{
                 meeting_transcript: %{
                   content: %{
                     "data" => [
                       %{
                         "words" => [
                           %{"text" => "No"},
                           %{"text" => "matching"},
                           %{"text" => "value", "start_timestamp" => 11.0}
                         ]
                       }
                     ]
                   }
                 }
               })

      assert is_nil(suggestion.timestamp)
    end

    test "falls back to AI timestamp when transcript has no timing metadata" do
      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_hubspot_suggestions, fn _meeting ->
        {:ok,
         [
           %{field: "company", value: "Acme Corp", context: "Company update", timestamp: "2:5"}
         ]}
      end)

      assert {:ok, [suggestion]} =
               Suggestions.generate_suggestions_from_meeting(%{
                 meeting_transcript: %{
                   content: %{
                     "data" => [
                       %{
                         "words" => [
                           %{"text" => "No"},
                           %{"text" => "timing"},
                           %{"text" => "metadata"}
                         ]
                       }
                     ]
                   }
                 }
               })

      assert suggestion.timestamp == "02:05"
    end

    test "resolves compact transcript tokens for spaced or punctuated values" do
      meeting = %{
        meeting_transcript: %{
          content: %{
            "data" => [
              %{
                "words" => [
                  %{"text" => "my"},
                  %{"text" => "email"},
                  %{"text" => "is"},
                  %{"text" => "tyler.harris@gmail.com", "start_timestamp" => 27.0}
                ]
              },
              %{
                "words" => [
                  %{"text" => "phone"},
                  %{"text" => "555712333", "start_timestamp" => 41.0}
                ]
              }
            ]
          }
        }
      }

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_hubspot_suggestions, fn _meeting ->
        {:ok,
         [
           %{
             field: "email",
             value: "Tyler.HARRIS@GMAIL.COM",
             context: "email",
             timestamp: "00:10"
           },
           %{field: "phone", value: "555 712 333", context: "phone", timestamp: "00:10"}
         ]}
      end)

      assert {:ok, suggestions} = Suggestions.generate_suggestions_from_meeting(meeting)
      by_field = Map.new(suggestions, &{&1.field, &1})

      assert by_field["email"].timestamp == "00:27"
      assert by_field["phone"].timestamp == "00:41"
    end

    test "resolves timestamps when transcript timing is encoded as strings" do
      meeting = %{
        meeting_transcript: %{
          content: %{
            "data" => [
              %{
                "words" => [
                  %{"text" => "my"},
                  %{"text" => "email"},
                  %{"text" => "is"},
                  %{"text" => "tyler.harris@gmail.com", "start_timestamp" => %{"relative" => "27.0"}}
                ]
              },
              %{
                "words" => [
                  %{"text" => "phone"},
                  %{"text" => "is"},
                  %{"text" => "555712333", "start_timestamp" => "79.0"}
                ]
              }
            ]
          }
        }
      }

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_hubspot_suggestions, fn _meeting ->
        {:ok,
         [
           %{
             field: "email",
             value: "Tyler.HARRIS@GMAIL.COM",
             context: "email",
             timestamp: "00:10"
           },
           %{field: "phone", value: "555 712 333", context: "phone", timestamp: "00:10"}
         ]}
      end)

      assert {:ok, suggestions} = Suggestions.generate_suggestions_from_meeting(meeting)
      by_field = Map.new(suggestions, &{&1.field, &1})

      assert by_field["email"].timestamp == "00:27"
      assert by_field["phone"].timestamp == "01:19"
    end
  end

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
          field: "company",
          label: "Company",
          current_value: nil,
          new_value: "Acme Corp",
          context: "Works at Acme",
          apply: false,
          has_change: true
        }
      ]

      contact = %{
        id: "123",
        phone: nil,
        company: "Acme Corp",
        email: "test@example.com"
      }

      result = Suggestions.merge_with_contact(suggestions, contact)

      assert length(result) == 1
      assert hd(result).field == "phone"
      assert hd(result).new_value == "555-1234"
    end

    test "normalizes values when comparing changes" do
      suggestions = [
        %{
          field: "email",
          label: "Email",
          current_value: nil,
          new_value: " USER@EXAMPLE.COM ",
          context: "Email mentioned",
          apply: true,
          has_change: true
        },
        %{
          field: "phone",
          label: "Phone",
          current_value: nil,
          new_value: "50000",
          context: "Phone mentioned",
          apply: true,
          has_change: true
        }
      ]

      contact = %{
        id: "123",
        email: "user@example.com",
        phone: 5.0e4
      }

      assert Suggestions.merge_with_contact(suggestions, contact) == []
    end
  end
end
