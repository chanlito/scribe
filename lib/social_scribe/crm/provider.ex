defmodule SocialScribe.CRM.Provider do
  @moduledoc """
  Behaviour for CRM integrations used by the unified CRM modal.
  """

  alias SocialScribe.Accounts.User
  alias SocialScribe.Accounts.UserCredential

  @callback provider_id() :: atom()
  @callback display_name() :: String.t()
  @callback account_select_label() :: String.t()
  @callback capabilities() :: map()

  @callback list_credentials(User.t()) :: [UserCredential.t()]
  @callback default_credential([UserCredential.t()]) :: UserCredential.t() | nil

  @callback list_contacts(UserCredential.t(), String.t()) :: {:ok, [map()]} | {:error, any()}

  @callback generate_suggestions(UserCredential.t(), map(), map()) ::
              {:ok, %{selected_contact: map(), suggestions: [map()], mapping_fields: [map()]}}
              | {:error, any()}

  @callback default_mapping_fields() :: [map()]

  @callback prepare_suggestions([map()], map() | nil, [map()]) :: {[map()], String.t() | nil}

  @callback apply_form_state([map()], map(), map() | nil, [map()]) :: {[map()], String.t() | nil}

  @callback build_updates([map()]) :: {:ok, map()} | {:error, String.t()}

  @callback format_search_error(any()) :: String.t()
  @callback format_suggestion_error(any()) :: String.t()
  @callback format_update_error(any()) :: String.t()
end
