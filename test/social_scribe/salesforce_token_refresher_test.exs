defmodule SocialScribe.SalesforceTokenRefresherTest do
  use SocialScribe.DataCase

  alias SocialScribe.SalesforceTokenRefresher

  import SocialScribe.AccountsFixtures

  describe "ensure_valid_token/1" do
    test "returns reconnect_required when instance_url metadata is missing" do
      credential = salesforce_credential_fixture(%{metadata: %{}})

      assert {:error, {:reconnect_required, _message}} =
               SalesforceTokenRefresher.ensure_valid_token(credential)
    end

    test "returns credential unchanged when token is still valid" do
      credential =
        salesforce_credential_fixture(%{
          expires_at: DateTime.add(DateTime.utc_now(), 1800, :second),
          metadata: %{"instance_url" => "https://acme.my.salesforce.com"}
        })

      assert {:ok, result} = SalesforceTokenRefresher.ensure_valid_token(credential)
      assert result.id == credential.id
    end
  end
end
