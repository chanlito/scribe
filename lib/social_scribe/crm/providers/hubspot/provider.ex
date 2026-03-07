defmodule SocialScribe.CRM.Providers.Hubspot.Provider do
  @moduledoc false

  @behaviour SocialScribe.CRM.Provider

  alias SocialScribe.Accounts
  alias SocialScribe.CRM.Providers.Hubspot.Api
  alias SocialScribe.CRM.Providers.Hubspot.Suggestions
  alias SocialScribe.CRM.SuggestionsHelpers

  @impl true
  def provider_id, do: :hubspot

  @impl true
  def display_name, do: "HubSpot"

  @impl true
  def description, do: "Update CRM contacts with information from this meeting"

  @impl true
  def button_class, do: "bg-orange-500 hover:bg-orange-600"

  @impl true
  def account_select_label, do: "Select HubSpot Account"

  @impl true
  def capabilities do
    %{
      account_selection: false,
      mapping: true,
      mapping_toggle: true,
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
  def generate_suggestions(credential, contact, meeting) do
    mapping_fields = Suggestions.build_mapping_fields(credential)

    case Suggestions.generate_suggestions_from_meeting(meeting) do
      {:ok, ai_suggestions} ->
        merged = Suggestions.merge_with_contact(ai_suggestions, contact)

        notice =
          cond do
            Enum.empty?(ai_suggestions) -> :no_ai_suggestions
            Enum.empty?(merged) -> :all_up_to_date
            true -> nil
          end

        {:ok,
         %{
           selected_contact: contact,
           suggestions: merged,
           mapping_fields: mapping_fields,
           notice: notice
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def default_mapping_fields, do: Suggestions.default_mapping_fields()

  @impl true
  def prepare_suggestions(suggestions, selected_contact, mapping_fields) do
    prepared =
      suggestions
      |> Enum.with_index(1)
      |> Enum.map(fn {suggestion, idx} -> prepare_row(suggestion, idx, mapping_fields) end)
      |> Enum.filter(& &1.has_change)
      |> ensure_existing_contact_rows(selected_contact, mapping_fields)

    {prepared, nil}
  end

  @impl true
  def apply_form_state(suggestions, params, selected_contact, mapping_fields) do
    applied_rows = Map.get(params, "apply", %{})
    values = Map.get(params, "values", %{})
    mapped_fields_params = Map.get(params, "mapped_fields", %{})
    checked_rows = Map.keys(applied_rows)

    prepared =
      Enum.map(suggestions, fn suggestion ->
        row_id = suggestion.id

        mapped_field =
          mapped_fields_params
          |> Map.get(row_id, suggestion.mapped_field || suggestion.field)
          |> Suggestions.normalize_field_key()

        mapped_label = mapping_field_label(mapping_fields, mapped_field, suggestion)

        current_value =
          selected_contact
          |> Suggestions.contact_field_value(mapped_field)
          |> then(&Suggestions.normalize_field_value(mapped_field, &1))
          |> then(&SuggestionsHelpers.sanitize_suggestion_value(mapped_field, mapped_label, &1))

        new_value =
          values
          |> Map.get(row_id, suggestion.new_value || "")
          |> then(&Suggestions.normalize_field_value(mapped_field, &1))
          |> then(&SuggestionsHelpers.sanitize_suggestion_value(mapped_field, mapped_label, &1))

        has_change = Suggestions.changed?(current_value, new_value)

        suggestion
        |> Map.put(:mapped_field, mapped_field)
        |> Map.put(:mapped_label, mapped_label)
        |> Map.put(:current_value, current_value)
        |> Map.put(:new_value, new_value)
        |> Map.put(:has_change, has_change)
        |> Map.put(:apply, row_id in checked_rows)
      end)

    SuggestionsHelpers.apply_duplicate_validation(prepared)
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
  defdelegate format_suggestion_error(reason), to: SocialScribe.CRM.GeminiErrors

  @impl true
  def update_contact(credential, contact_id, updates) do
    api_impl().update_contact(credential, contact_id, updates)
  end

  @impl true
  def format_update_error({:api_error, 400, %{"message" => message}}) when is_binary(message) do
    "HubSpot rejected the update: #{message}"
  end

  def format_update_error({:api_error, 400, body}) when is_list(body) do
    details =
      body
      |> Enum.map(fn entry -> Map.get(entry, "message", "Unknown error") end)
      |> Enum.join("; ")

    "HubSpot rejected the update: #{details}"
  end

  def format_update_error({:api_error, status, _body}) do
    "HubSpot API error (#{status}). Please try again."
  end

  def format_update_error({:http_error, _reason}) do
    "Could not connect to HubSpot. Please check your connection and try again."
  end

  def format_update_error({:token_refresh_failed, _reason}) do
    "Your HubSpot session has expired. Please reconnect HubSpot and try again."
  end

  def format_update_error(reason), do: "Failed to update contact: #{inspect(reason)}"

  defp prepare_row(suggestion, idx, mapping_fields) do
    field = Map.get(suggestion, :mapped_field, Map.get(suggestion, :field))
    mapped_label = mapping_field_label(mapping_fields, field, suggestion)

    current_value =
      Suggestions.normalize_field_value(field, Map.get(suggestion, :current_value))
      |> then(&SuggestionsHelpers.sanitize_suggestion_value(field, mapped_label, &1))

    new_value =
      Suggestions.normalize_field_value(
        field,
        Map.get(suggestion, :new_value, Map.get(suggestion, :value, ""))
      )
      |> then(&SuggestionsHelpers.sanitize_suggestion_value(field, mapped_label, &1))

    has_change = Suggestions.changed?(current_value, new_value)

    suggestion
    |> Map.put_new(:id, "hubspot-suggestion-#{idx}")
    |> Map.put(:mapped_field, field)
    |> Map.put(:mapped_label, mapped_label)
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

  defp ensure_existing_contact_rows(suggestions, nil, _mapping_fields), do: suggestions

  defp ensure_existing_contact_rows(suggestions, selected_contact, mapping_fields) do
    existing_fields = suggestions |> Enum.map(& &1.mapped_field) |> MapSet.new()

    additional_rows =
      mapping_fields
      |> Enum.reduce([], fn mapping_field, acc ->
        mapped_field =
          mapping_field
          |> Map.get(:name, Map.get(mapping_field, "name"))
          |> Suggestions.normalize_field_key()

        mapped_label =
          Map.get(mapping_field, :label, Map.get(mapping_field, "label", mapped_field))

        cond do
          not is_binary(mapped_field) ->
            acc

          MapSet.member?(existing_fields, mapped_field) ->
            acc

          true ->
            current_value =
              selected_contact
              |> Suggestions.contact_field_value(mapped_field)
              |> then(&Suggestions.normalize_field_value(mapped_field, &1))
              |> then(&SuggestionsHelpers.sanitize_suggestion_value(mapped_field, mapped_label, &1))

            if present_existing_value?(current_value) do
              [
                %{
                  id: "hubspot-existing-#{mapped_field}",
                  field: mapped_field,
                  mapped_field: mapped_field,
                  label: mapped_label,
                  mapped_label: mapped_label,
                  current_value: current_value,
                  new_value: current_value,
                  context: nil,
                  timestamp: nil,
                  apply: false,
                  details_open: false,
                  mapping_open: false,
                  has_change: false
                }
                | acc
              ]
            else
              acc
            end
        end
      end)
      |> Enum.reverse()

    suggestions ++ additional_rows
  end

  defp present_existing_value?(nil), do: false
  defp present_existing_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_existing_value?(_), do: true

  defp api_impl do
    Application.get_env(:social_scribe, :hubspot_api, Api)
  end
end
