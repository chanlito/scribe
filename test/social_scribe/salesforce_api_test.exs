defmodule SocialScribe.SalesforceApiTest do
  use SocialScribe.DataCase

  alias SocialScribe.SalesforceApi
  alias SocialScribe.Accounts.UserCredential

  import SocialScribe.AccountsFixtures

  describe "apply_updates/3" do
    test "returns :no_updates when all updates have apply false" do
      user = user_fixture()
      credential = salesforce_credential_fixture(%{user_id: user.id})

      updates = [
        %{field: "phone", new_value: "555-1234", apply: false},
        %{field: "email", new_value: "test@example.com", apply: false}
      ]

      assert {:ok, :no_updates} = SalesforceApi.apply_updates(credential, "003123", updates)
    end

    test "returns reconnect_required when instance_url is missing" do
      user = user_fixture()
      credential = salesforce_credential_fixture(%{user_id: user.id, metadata: %{}})

      updates = [%{field: "phone", new_value: "555-1234", apply: true}]

      assert {:error, {:reconnect_required, _message}} =
               SalesforceApi.apply_updates(credential, "003123", updates)
    end
  end

  describe "normalize_update_value/2" do
    test "casts currency strings with commas to numeric JSON values" do
      assert SalesforceApi.normalize_update_value("137,143", "currency") == 137_143.0
      assert SalesforceApi.normalize_update_value("$137,143.50", "currency") == 137_143.5
    end

    test "casts percent strings and integer strings" do
      assert SalesforceApi.normalize_update_value("12%", "percent") == 12.0
      assert SalesforceApi.normalize_update_value("10,000", "int") == 10_000
    end

    test "casts boolean string values" do
      assert SalesforceApi.normalize_update_value("true", "boolean") == true
      assert SalesforceApi.normalize_update_value("no", "boolean") == false
    end

    test "downcases email values before sending to Salesforce" do
      assert SalesforceApi.normalize_update_value(
               "Michael.Thompson@northgatepartners.com",
               "email"
             ) ==
               "michael.thompson@northgatepartners.com"
    end

    test "casts date and datetime string values to Salesforce-friendly formats" do
      assert SalesforceApi.normalize_update_value("2026-03-07", "date") == "2026-03-07"
      assert SalesforceApi.normalize_update_value("03/07/2026", "date") == "2026-03-07"

      assert SalesforceApi.normalize_update_value("2026-03-07 12:30", "datetime") ==
               "2026-03-07T12:30:00Z"
    end
  end

  describe "search_contacts/2 identity scoping" do
    test "returns reconnect_required when identity_url is missing" do
      user = user_fixture()
      credential = salesforce_credential_fixture(%{user_id: user.id})

      assert {:error, {:reconnect_required, message}} =
               SalesforceApi.search_contacts(credential, "john")

      assert message =~ "Please reconnect Salesforce"
    end
  end

  describe "extract_salesforce_user_id/1" do
    test "extracts user id from identity_url metadata" do
      credential = %UserCredential{
        metadata: %{
          "identity_url" => "https://login.salesforce.com/id/00D123456789ABC/005ABCDEF123456"
        }
      }

      assert {:ok, "005ABCDEF123456"} = SalesforceApi.extract_salesforce_user_id(credential)
    end

    test "returns reconnect_required for malformed identity_url" do
      credential = %UserCredential{metadata: %{"identity_url" => "https://login.salesforce.com"}}

      assert {:error, {:reconnect_required, _message}} =
               SalesforceApi.extract_salesforce_user_id(credential)
    end
  end

  describe "build_search_soql/2" do
    test "adds OwnerId filter for blank query" do
      soql = SalesforceApi.build_search_soql("", "005ABCDEF123456")

      assert soql =~ "FROM Contact"
      assert soql =~ "WHERE OwnerId = '005ABCDEF123456'"
      refute soql =~ "Name LIKE"
    end

    test "adds OwnerId filter for typed query" do
      soql = SalesforceApi.build_search_soql("john", "005ABCDEF123456")

      assert soql =~ "FROM Contact"
      assert soql =~ "WHERE OwnerId = '005ABCDEF123456' AND ("
      assert soql =~ "Name LIKE '%john%'"
    end
  end
end
