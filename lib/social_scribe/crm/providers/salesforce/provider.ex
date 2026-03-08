defmodule SocialScribe.CRM.Providers.Salesforce.Provider do
  @moduledoc false

  @behaviour SocialScribe.CRM.Provider

  alias SocialScribe.Accounts
  alias SocialScribe.CRM.Providers.Salesforce.Api
  alias SocialScribe.CRM.Providers.Salesforce.Suggestions
  alias SocialScribe.CRM.SuggestionsHelpers

  @impl true
  def provider_id, do: :salesforce

  @impl true
  def display_name, do: "Salesforce"

  @impl true
  def description, do: "Review and sync contact updates from this meeting"

  @impl true
  def button_class, do: "bg-blue-600 hover:bg-blue-700"

  @impl true
  def account_select_label, do: "Select Salesforce Account"

  @impl true
  def capabilities do
    %{
      account_selection: true,
      mapping: true,
      mapping_toggle: true,
      details_toggle: true,
      lock_on_submit: true,
      paired_fields: true
    }
  end

  @impl true
  def list_credentials(user) do
    Accounts.list_user_credentials(user, provider: "salesforce")
  end

  @impl true
  def default_credential([credential | _]), do: credential

  def default_credential([]), do: nil

  @impl true
  def credential_label(credential), do: credential.email || credential.uid

  @impl true
  def credential_sublabel(credential) do
    case get_in(credential.metadata, ["instance_url"]) do
      nil -> nil
      instance_url -> String.replace_prefix(instance_url, "https://", "")
    end
  end

  @impl true
  def list_contacts(credential, query) do
    api_impl().search_contacts(credential, query)
  end

  @impl true
  def generate_suggestions(credential, contact, meeting) do
    case Suggestions.generate_suggestions(credential, contact.id, meeting) do
      {:ok,
       %{
         contact: full_contact,
         suggestions: suggestions,
         mapping_fields: mapping_fields,
         raw_ai_count: raw_ai_count
       }} ->
        notice =
          cond do
            raw_ai_count == 0 -> :no_ai_suggestions
            Enum.empty?(suggestions) -> :all_up_to_date
            true -> nil
          end

        {:ok,
         %{
           selected_contact: full_contact,
           suggestions: suggestions,
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
      |> Enum.map(fn {suggestion, idx} ->
        prepare_suggestion(suggestion, idx, selected_contact, mapping_fields)
      end)
      |> Enum.reject(&invalid_suggestion_row?/1)
      |> ensure_existing_contact_rows(selected_contact, mapping_fields)
      |> ensure_mailing_pair_rows(selected_contact, mapping_fields)

    apply_duplicate_validation(prepared)
  end

  @impl true
  def apply_form_state(suggestions, params, selected_contact, mapping_fields) do
    applied_rows = Map.get(params, "apply", %{})
    values = Map.get(params, "values", %{})
    mapped_fields = Map.get(params, "mapped_fields", %{})
    toggled_row_id = toggled_apply_row_id(params)
    previous_pair_apply = mailing_pair_apply_value(suggestions)
    checked_rows = Map.keys(applied_rows)

    suggestions =
      apply_form_state_rows(
        suggestions,
        applied_rows,
        values,
        mapped_fields,
        selected_contact,
        mapping_fields
      )
      |> ensure_mailing_pair_rows(selected_contact, mapping_fields)
      |> sync_mailing_pair_apply(toggled_row_id, previous_pair_apply)
      |> maybe_uncheck_mailing_pair_from_toggle(toggled_row_id, checked_rows)
      |> maybe_clear_mailing_pair_apply(applied_rows)

    apply_duplicate_validation(suggestions)
  end

  @impl true
  def build_updates(suggestions) do
    updates =
      suggestions
      |> Enum.filter(&(&1.apply == true and &1.has_change == true))
      |> Enum.reduce(%{}, fn suggestion, acc ->
        Map.put(acc, suggestion.mapped_field, suggestion.new_value)
      end)

    if map_size(updates) == 0 do
      {:error, "Please select at least one changed field to update"}
    else
      {:ok, updates}
    end
  end

  @impl true
  def format_search_error({:reconnect_required, message}) when is_binary(message) do
    %{title: "Salesforce connection required", errors: [%{code: nil, message: message}]}
  end

  def format_search_error(reason) do
    %{title: "Failed to search contacts", errors: [%{code: nil, message: inspect(reason)}]}
  end

  @impl true
  defdelegate format_suggestion_error(reason), to: SocialScribe.CRM.GeminiErrors

  @impl true
  def update_contact(credential, contact_id, updates) do
    api_impl().update_contact(credential, contact_id, updates)
  end

  @impl true
  def format_update_error({:invalid_updates, errors}) when is_list(errors) do
    error_list =
      Enum.map(errors, fn error ->
        field = Map.get(error, :field, "unknown field")
        message = Map.get(error, :message, "invalid value")
        %{code: nil, message: "#{field}: #{message}"}
      end)

    %{title: "Some values could not be validated for Salesforce", errors: error_list}
  end

  def format_update_error({:api_error, 400, body}) when is_list(body) do
    error_list =
      Enum.map(body, fn entry ->
        %{
          code: Map.get(entry, "errorCode"),
          message: Map.get(entry, "message", "Unknown Salesforce error")
        }
      end)

    %{title: "Salesforce rejected the update", errors: error_list}
  end

  def format_update_error(reason) do
    %{title: "Failed to update contact", errors: [%{code: nil, message: inspect(reason)}]}
  end

  defp prepare_suggestion(suggestion, idx, selected_contact, mapping_fields) do
    mapped_field =
      suggestion
      |> Map.get(:mapped_field, Map.get(suggestion, :field))
      |> Suggestions.normalize_field_key()

    mapped_label = mapping_field_label(mapping_fields, mapped_field, suggestion)

    current_value =
      case Map.get(suggestion, :current_value) do
        nil ->
          selected_contact
          |> Suggestions.contact_field_value(mapped_field)
          |> then(&Suggestions.normalize_field_value(mapped_field, &1))
          |> then(&sanitize_suggestion_value(mapped_field, mapped_label, &1, :current))

        value ->
          Suggestions.normalize_field_value(mapped_field, value)
          |> then(&sanitize_suggestion_value(mapped_field, mapped_label, &1, :current))
      end

    new_value =
      suggestion
      |> Map.get(:new_value, Map.get(suggestion, :value, ""))
      |> then(&Suggestions.normalize_field_value(mapped_field, &1))
      |> then(&sanitize_suggestion_value(mapped_field, mapped_label, &1, :new))

    has_change = Suggestions.changed?(current_value, new_value)

    suggestion
    |> Map.put_new(:id, "sf-suggestion-#{idx}")
    |> Map.put(:mapped_field, mapped_field)
    |> Map.put(:mapped_label, mapped_label)
    |> Map.put(:current_value, current_value)
    |> Map.put(:new_value, new_value)
    |> Map.put(:has_change, has_change)
    |> Map.put(:apply, has_change && Map.get(suggestion, :apply, true))
    |> Map.put_new(:details_open, true)
    |> Map.put_new(:mapping_open, false)
    |> maybe_add_pair_warning()
  end

  defp mapping_field_label(mapping_fields, mapped_field, suggestion) do
    case Enum.find(mapping_fields, fn field -> field.name == mapped_field end) do
      nil -> Map.get(suggestion, :mapped_label, Map.get(suggestion, :label, mapped_field))
      field -> field.label
    end
  end

  defp apply_form_state_rows(
         suggestions,
         applied_rows,
         values,
         mapped_fields,
         selected_contact,
         mapping_fields
       ) do
    checked_rows = Map.keys(applied_rows)

    Enum.map(suggestions, fn suggestion ->
      row_id = suggestion.id

      mapped_field =
        mapped_fields
        |> Map.get(row_id, suggestion.mapped_field || suggestion.field)
        |> Suggestions.normalize_field_key()

      mapped_label = mapping_field_label(mapping_fields, mapped_field, suggestion)

      current_value =
        selected_contact
        |> Suggestions.contact_field_value(mapped_field)
        |> then(&Suggestions.normalize_field_value(mapped_field, &1))
        |> then(&sanitize_suggestion_value(mapped_field, mapped_label, &1, :current))

      new_value =
        values
        |> Map.get(row_id, suggestion.new_value || "")
        |> then(&Suggestions.normalize_field_value(mapped_field, &1))
        |> then(&sanitize_suggestion_value(mapped_field, mapped_label, &1, :new))

      has_change = Suggestions.changed?(current_value, new_value)
      apply? = row_id in checked_rows

      suggestion
      |> Map.put(:mapped_field, mapped_field)
      |> Map.put(:mapped_label, mapped_label)
      |> Map.put(:current_value, current_value)
      |> Map.put(:new_value, new_value)
      |> Map.put(:has_change, has_change)
      |> Map.put(:apply, apply?)
      |> Map.put(:details_open, apply?)
      |> maybe_add_pair_warning()
    end)
  end

  defp sanitize_suggestion_value(field, label, value, _kind),
    do: SuggestionsHelpers.sanitize_suggestion_value(field, label, value)

  defp invalid_suggestion_row?(suggestion) do
    new_value = Map.get(suggestion, :new_value)

    is_nil(new_value) or (is_binary(new_value) and String.trim(new_value) == "")
  end

  defp present_existing_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_existing_value?(nil), do: false
  defp present_existing_value?(_), do: true

  defp include_existing_row?(mapped_field, mapped_label) do
    normalized_field = String.downcase(to_string(mapped_field || ""))
    normalized_label = String.downcase(to_string(mapped_label || ""))

    normalized_field != "ownerid" and normalized_label != "owner id"
  end

  defp ensure_existing_contact_rows(suggestions, nil, _mapping_fields), do: suggestions

  defp ensure_existing_contact_rows(suggestions, selected_contact, mapping_fields) do
    existing_fields =
      suggestions
      |> Enum.map(& &1.mapped_field)
      |> MapSet.new()

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
              |> then(&sanitize_suggestion_value(mapped_field, mapped_label, &1, :current))

            if include_existing_row?(mapped_field, mapped_label) and
                 present_existing_value?(current_value) do
              [
                maybe_add_pair_warning(%{
                  id: "sf-existing-#{mapped_field}",
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
                })
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

  defp apply_duplicate_validation(suggestions),
    do: SuggestionsHelpers.apply_duplicate_validation(suggestions)

  defp toggled_apply_row_id(%{"_target" => ["apply", row_id]}) when is_binary(row_id), do: row_id
  defp toggled_apply_row_id(_params), do: nil

  defp mailing_pair_present?(suggestions) do
    Enum.any?(suggestions, fn suggestion ->
      suggestion.mapped_field in ["mailingstate", "mailingcountry"]
    end)
  end

  defp ensure_mailing_pair_rows(suggestions, selected_contact, mapping_fields) do
    if mailing_pair_present?(suggestions) do
      suggestions
      |> maybe_add_missing_pair_row("mailingstate", selected_contact, mapping_fields)
      |> maybe_add_missing_pair_row("mailingcountry", selected_contact, mapping_fields)
      |> order_mailing_pair_rows()
    else
      suggestions
    end
  end

  defp maybe_add_missing_pair_row(suggestions, field, selected_contact, mapping_fields) do
    if Enum.any?(suggestions, &(&1.mapped_field == field)) do
      suggestions
    else
      suggestions ++ [build_missing_pair_row(field, selected_contact, mapping_fields)]
    end
  end

  defp build_missing_pair_row(field, selected_contact, mapping_fields) do
    mapped_label =
      mapping_field_label(mapping_fields, field, %{mapped_label: field, label: field})

    current_value =
      selected_contact
      |> Suggestions.contact_field_value(field)
      |> then(&Suggestions.normalize_field_value(field, &1))
      |> then(&sanitize_suggestion_value(field, mapped_label, &1, :current))

    %{
      id: "sf-paired-#{field}",
      field: field,
      mapped_field: field,
      label: mapped_label,
      mapped_label: mapped_label,
      current_value: current_value,
      new_value: current_value,
      context: nil,
      timestamp: nil,
      apply: false,
      details_open: true,
      mapping_open: false,
      has_change: Suggestions.changed?(current_value, current_value)
    }
    |> maybe_add_pair_warning()
  end

  defp maybe_add_pair_warning(%{mapped_field: "mailingcountry"} = suggestion) do
    Map.put(
      suggestion,
      :pair_warning,
      "* Mailing State/Province and Mailing Country/Territory depend on each other. Update both together."
    )
  end

  defp maybe_add_pair_warning(suggestion), do: Map.delete(suggestion, :pair_warning)

  defp order_mailing_pair_rows(suggestions) do
    state_row = Enum.find(suggestions, &(&1.mapped_field == "mailingstate"))
    country_row = Enum.find(suggestions, &(&1.mapped_field == "mailingcountry"))

    case {state_row, country_row} do
      {%{} = state_row, %{} = country_row} ->
        {reversed, inserted?} =
          Enum.reduce(suggestions, {[], false}, fn suggestion, {acc, inserted?} ->
            if suggestion.mapped_field in ["mailingstate", "mailingcountry"] do
              if inserted? do
                {acc, inserted?}
              else
                {[country_row, state_row | acc], true}
              end
            else
              {[suggestion | acc], inserted?}
            end
          end)

        if inserted?, do: Enum.reverse(reversed), else: suggestions

      _ ->
        suggestions
    end
  end

  defp sync_mailing_pair_apply(suggestions, toggled_row_id, previous_pair_apply) do
    state_row = Enum.find(suggestions, &(&1.mapped_field == "mailingstate"))
    country_row = Enum.find(suggestions, &(&1.mapped_field == "mailingcountry"))

    case {state_row, country_row} do
      {%{id: state_id, apply: state_apply}, %{id: country_id, apply: country_apply}} ->
        cond do
          state_apply == country_apply ->
            suggestions

          toggled_row_id == state_id ->
            Enum.map(suggestions, &set_pair_apply(&1, state_apply))

          toggled_row_id == country_id ->
            Enum.map(suggestions, &set_pair_apply(&1, country_apply))

          true ->
            mirror_apply =
              case previous_pair_apply do
                true -> false
                false -> true
                _ -> state_apply or country_apply
              end

            Enum.map(suggestions, &set_pair_apply(&1, mirror_apply))
        end

      _ ->
        suggestions
    end
  end

  defp set_pair_apply(%{mapped_field: mapped_field} = suggestion, apply?)
       when mapped_field in ["mailingstate", "mailingcountry"] do
    Map.put(suggestion, :apply, apply?)
  end

  defp set_pair_apply(suggestion, _apply?), do: suggestion

  defp maybe_clear_mailing_pair_apply(suggestions, applied_rows)
       when map_size(applied_rows) == 0 do
    Enum.map(suggestions, &set_pair_apply(&1, false))
  end

  defp maybe_clear_mailing_pair_apply(suggestions, _applied_rows), do: suggestions

  defp maybe_uncheck_mailing_pair_from_toggle(suggestions, toggled_row_id, checked_rows) do
    if is_binary(toggled_row_id) and toggled_row_id not in checked_rows do
      case Enum.find(suggestions, &(&1.id == toggled_row_id)) do
        %{mapped_field: mapped_field} when mapped_field in ["mailingstate", "mailingcountry"] ->
          Enum.map(suggestions, &set_pair_apply(&1, false))

        _ ->
          suggestions
      end
    else
      suggestions
    end
  end

  defp mailing_pair_apply_value(suggestions) do
    state_apply =
      suggestions
      |> Enum.find(&(&1.mapped_field == "mailingstate"))
      |> case do
        %{apply: apply?} -> apply?
        _ -> nil
      end

    country_apply =
      suggestions
      |> Enum.find(&(&1.mapped_field == "mailingcountry"))
      |> case do
        %{apply: apply?} -> apply?
        _ -> nil
      end

    if state_apply in [true, false] and country_apply in [true, false] and
         state_apply == country_apply do
      state_apply
    else
      nil
    end
  end

  defp api_impl do
    Application.get_env(:social_scribe, :salesforce_api, Api)
  end
end
