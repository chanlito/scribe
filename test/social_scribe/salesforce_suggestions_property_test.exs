defmodule SocialScribe.SalesforceSuggestionsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SocialScribe.CRM.Providers.Salesforce.Suggestions

  @salesforce_fields [
    "firstname",
    "lastname",
    "email",
    "phone",
    "mobilephone",
    "title",
    "department",
    "mailingstreet",
    "mailingcity",
    "mailingstate",
    "mailingpostalcode",
    "mailingcountry"
  ]

  describe "merge_with_contact/2 properties" do
    property "never returns suggestions where new_value equals contact current value" do
      check all(
              suggestions <- list_of(suggestion_generator(), min_length: 1, max_length: 5),
              contact <- contact_generator()
            ) do
        result = Suggestions.merge_with_contact(suggestions, contact)

        for suggestion <- result do
          current_in_contact = get_contact_value(contact, suggestion.field)
          refute suggestion.new_value == current_in_contact
        end
      end
    end

    property "all returned suggestions are marked apply true" do
      check all(
              suggestions <- list_of(suggestion_generator(), min_length: 1, max_length: 5),
              contact <- contact_generator()
            ) do
        result = Suggestions.merge_with_contact(suggestions, contact)
        assert Enum.all?(result, &(&1.apply == true))
      end
    end
  end

  defp suggestion_generator do
    gen all(
          field <- member_of(@salesforce_fields),
          new_value <-
            one_of([string(:alphanumeric, min_length: 1, max_length: 50), constant(nil)]),
          context <- string(:alphanumeric, min_length: 5, max_length: 100)
        ) do
      %{
        field: field,
        label: field,
        current_value: nil,
        new_value: new_value,
        context: context,
        apply: false,
        has_change: true
      }
    end
  end

  defp contact_generator do
    gen all(
          firstname <-
            one_of([string(:alphanumeric, min_length: 1, max_length: 20), constant(nil)]),
          lastname <-
            one_of([string(:alphanumeric, min_length: 1, max_length: 20), constant(nil)]),
          email <- one_of([email_generator(), constant(nil)]),
          phone <- one_of([phone_generator(), constant(nil)]),
          title <- one_of([string(:alphanumeric, min_length: 1, max_length: 30), constant(nil)])
        ) do
      %{
        id: "test_#{:rand.uniform(10000)}",
        firstname: firstname,
        lastname: lastname,
        email: email,
        phone: phone,
        mobilephone: nil,
        title: title,
        department: nil,
        mailingstreet: nil,
        mailingcity: nil,
        mailingstate: nil,
        mailingpostalcode: nil,
        mailingcountry: nil
      }
    end
  end

  defp email_generator do
    gen all(
          local <- string(:alphanumeric, min_length: 3, max_length: 10),
          domain <- string(:alphanumeric, min_length: 3, max_length: 8)
        ) do
      "#{local}@#{domain}.com"
    end
  end

  defp phone_generator do
    gen all(digits <- string(?0..?9, length: 10)) do
      "#{String.slice(digits, 0, 3)}-#{String.slice(digits, 3, 3)}-#{String.slice(digits, 6, 4)}"
    end
  end

  defp get_contact_value(contact, field) do
    field_atom = String.to_existing_atom(field)
    Map.get(contact, field_atom)
  rescue
    ArgumentError -> nil
  end
end
