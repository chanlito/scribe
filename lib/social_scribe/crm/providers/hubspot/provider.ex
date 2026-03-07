defmodule SocialScribe.CRM.Providers.Hubspot.Provider do
  @moduledoc false

  @behaviour SocialScribe.CRM.Provider

  alias SocialScribe.Accounts
  alias SocialScribe.CRM.Providers.Hubspot.Api
  alias SocialScribe.CRM.Providers.Hubspot.Suggestions

  @mapping_fields [
    %{name: "firstname", label: "First Name", type: "string", options: []},
    %{name: "lastname", label: "Last Name", type: "string", options: []},
    %{name: "email", label: "Email", type: "string", options: []},
    %{name: "phone", label: "Phone", type: "string", options: []},
    %{name: "mobilephone", label: "Mobile Phone", type: "string", options: []},
    %{name: "company", label: "Company", type: "string", options: []},
    %{name: "jobtitle", label: "Job Title", type: "string", options: []},
    %{name: "address", label: "Address", type: "string", options: []},
    %{name: "city", label: "City", type: "string", options: []},
    %{name: "state", label: "State", type: "string", options: []},
    %{name: "zip", label: "ZIP Code", type: "string", options: []},
    %{name: "country", label: "Country", type: "string", options: []},
    %{name: "website", label: "Website", type: "string", options: []},
    %{name: "linkedin_url", label: "LinkedIn", type: "string", options: []},
    %{name: "twitter_handle", label: "Twitter", type: "string", options: []}
  ]

  @impl true
  def provider_id, do: :hubspot

  @impl true
  def display_name, do: "HubSpot"

  @impl true
  def account_select_label, do: "Select HubSpot Account"

  @impl true
  def capabilities do
    %{
      account_selection: false,
      mapping: false,
      mapping_toggle: false,
      details_toggle: true,
      lock_on_submit: true,
      paired_fields: false
    }
  end

  @impl true
  def list_credentials(user) do
    case Accounts.get_user_hubspot_credential(user.id) do
      nil -> []
      credential -> [credential]
    end
  end

  @impl true
  def default_credential([credential]), do: credential

  def default_credential(_credentials), do: nil

  @impl true
  def list_contacts(credential, query) do
    api_impl().search_contacts(credential, query)
  end

  @impl true
  def generate_suggestions(_credential, contact, meeting) do
    case Suggestions.generate_suggestions_from_meeting(meeting) do
      {:ok, suggestions} ->
        merged = Suggestions.merge_with_contact(suggestions, contact)

        {:ok,
         %{
           selected_contact: contact,
           suggestions: merged,
           mapping_fields: @mapping_fields
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def default_mapping_fields, do: @mapping_fields

  @impl true
  def prepare_suggestions(suggestions, _selected_contact, mapping_fields) do
    prepared =
      suggestions
      |> Enum.with_index(1)
      |> Enum.map(fn {suggestion, idx} -> prepare_row(suggestion, idx, mapping_fields) end)
      |> Enum.filter(& &1.has_change)

    {prepared, nil}
  end

  @impl true
  def apply_form_state(suggestions, params, selected_contact, _mapping_fields) do
    applied_rows = Map.get(params, "apply", %{})
    values = Map.get(params, "values", %{})
    checked_rows = Map.keys(applied_rows)

    prepared =
      Enum.map(suggestions, fn suggestion ->
        row_id = suggestion.id
        field = suggestion.mapped_field || suggestion.field

        current_value =
          selected_contact
          |> Suggestions.contact_field_value(field)
          |> then(&Suggestions.normalize_field_value(field, &1))

        new_value =
          values
          |> Map.get(row_id, suggestion.new_value || "")
          |> then(&Suggestions.normalize_field_value(field, &1))

        has_change = Suggestions.changed?(current_value, new_value)

        suggestion
        |> Map.put(:current_value, current_value)
        |> Map.put(:new_value, new_value)
        |> Map.put(:has_change, has_change)
        |> Map.put(:apply, row_id in checked_rows)
      end)

    {prepared, nil}
  end

  @impl true
  def build_updates(suggestions) do
    updates =
      suggestions
      |> Enum.filter(&(&1.apply == true and &1.has_change == true))
      |> Enum.reduce(%{}, fn suggestion, acc ->
        Map.put(acc, suggestion.mapped_field || suggestion.field, suggestion.new_value)
      end)

    if map_size(updates) == 0 do
      {:error, "Please select at least one changed field to update"}
    else
      {:ok, updates}
    end
  end

  @impl true
  def format_search_error(reason), do: "Failed to search contacts: #{inspect(reason)}"

  @impl true
  def format_suggestion_error({:api_error, 429, body}) do
    retry_seconds = extract_retry_seconds(body)

    retry_hint =
      if retry_seconds do
        " Please retry in about #{retry_seconds} seconds."
      else
        " Please retry shortly."
      end

    "AI suggestion generation is rate-limited by Gemini quota." <>
      retry_hint <>
      " If this persists, check Gemini API quota/billing settings."
  end

  def format_suggestion_error({:config_error, message}) when is_binary(message) do
    "AI suggestion generation is unavailable: #{message}"
  end

  def format_suggestion_error(reason), do: "Failed to generate suggestions: #{inspect(reason)}"

  @impl true
  def format_update_error(reason), do: "Failed to update contact: #{inspect(reason)}"

  defp prepare_row(suggestion, idx, mapping_fields) do
    field = Map.get(suggestion, :mapped_field, Map.get(suggestion, :field))
    current_value = Suggestions.normalize_field_value(field, Map.get(suggestion, :current_value))

    new_value =
      Suggestions.normalize_field_value(
        field,
        Map.get(suggestion, :new_value, Map.get(suggestion, :value, ""))
      )

    has_change = Suggestions.changed?(current_value, new_value)

    suggestion
    |> Map.put_new(:id, "hubspot-suggestion-#{idx}")
    |> Map.put(:mapped_field, field)
    |> Map.put(:mapped_label, mapping_field_label(mapping_fields, field, suggestion))
    |> Map.put(:current_value, current_value)
    |> Map.put(:new_value, new_value)
    |> Map.put(:has_change, has_change)
    |> Map.put(:apply, has_change && Map.get(suggestion, :apply, true))
    |> Map.put_new(:details_open, true)
    |> Map.put_new(:mapping_open, false)
  end

  defp mapping_field_label(mapping_fields, mapped_field, suggestion) do
    case Enum.find(mapping_fields, fn field -> field.name == mapped_field end) do
      nil -> Map.get(suggestion, :mapped_label, Map.get(suggestion, :label, mapped_field))
      field -> field.label
    end
  end

  defp extract_retry_seconds(%{"error" => %{"details" => details}}) when is_list(details) do
    details
    |> Enum.find_value(fn
      %{"@type" => "type.googleapis.com/google.rpc.RetryInfo", "retryDelay" => delay} ->
        case Regex.run(~r/^(\d+(?:\.\d+)?)s$/, delay, capture: :all_but_first) do
          [seconds] ->
            case Float.parse(seconds) do
              {value, _} -> trunc(Float.ceil(value))
              :error -> nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end)
  end

  defp extract_retry_seconds(_), do: nil

  defp api_impl do
    Application.get_env(:social_scribe, :hubspot_api, Api)
  end
end
