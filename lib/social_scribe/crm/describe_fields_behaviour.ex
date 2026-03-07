defmodule SocialScribe.CRM.DescribeFieldsBehaviour do
  @moduledoc """
  Optional CRM behaviour for providers that support contact field discovery.
  """

  alias SocialScribe.Accounts.UserCredential

  @callback describe_contact_fields(credential :: UserCredential.t()) ::
              {:ok, list(map())} | {:error, any()}
end
