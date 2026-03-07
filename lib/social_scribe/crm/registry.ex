defmodule SocialScribe.CRM.Registry do
  @moduledoc """
  Registry of all available CRM provider modules.

  To add a new CRM, add its provider module to @providers below.
  No other files need to change.
  """

  alias SocialScribe.CRM.Providers.Hubspot.Provider, as: HubspotProvider
  alias SocialScribe.CRM.Providers.Salesforce.Provider, as: SalesforceProvider

  @providers [HubspotProvider, SalesforceProvider]

  @doc "Returns all registered CRM provider modules."
  def all_providers, do: @providers

  @doc """
  Returns the provider module for the given atom id, or `{:error, :not_found}`.
  """
  def provider_for_id(id) when is_atom(id) do
    case Enum.find(@providers, fn provider -> provider.provider_id() == id end) do
      nil -> {:error, :not_found}
      provider -> {:ok, provider}
    end
  end

  @doc """
  Returns a list of `{provider_module, credentials}` tuples for the given user,
  filtered to providers where the user has at least one connected credential.
  """
  def providers_for_user(user) do
    @providers
    |> Enum.map(fn provider -> {provider, provider.list_credentials(user)} end)
    |> Enum.reject(fn {_provider, credentials} -> Enum.empty?(credentials) end)
  end
end
