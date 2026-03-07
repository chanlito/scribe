defmodule SocialScribe.SalesforceApiPropertyTest do
  use SocialScribe.DataCase, async: true
  use ExUnitProperties

  import SocialScribe.AccountsFixtures

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

  describe "apply_updates/3 properties" do
    setup do
      user = user_fixture()
      credential = salesforce_credential_fixture(%{user_id: user.id})
      %{credential: credential}
    end

    property "returns {:ok, :no_updates} when all updates have apply false", %{
      credential: credential
    } do
      check all(updates <- list_of(update_generator(apply: false), min_length: 1, max_length: 10)) do
        result = SocialScribe.SalesforceApi.apply_updates(credential, "003123", updates)
        assert result == {:ok, :no_updates}
      end
    end

    property "returns {:ok, :no_updates} for empty updates list", %{credential: credential} do
      check all(contact_id <- string(:alphanumeric, min_length: 1, max_length: 20)) do
        result = SocialScribe.SalesforceApi.apply_updates(credential, contact_id, [])
        assert result == {:ok, :no_updates}
      end
    end
  end

  defp update_generator(opts) do
    apply_value = Keyword.get(opts, :apply, :random)

    gen all(
          field <- member_of(@salesforce_fields),
          new_value <- string(:alphanumeric, min_length: 1, max_length: 50),
          apply? <- if(apply_value == :random, do: boolean(), else: constant(apply_value))
        ) do
      %{field: field, new_value: new_value, apply: apply?}
    end
  end
end
