defmodule SocialScribe.CRM.Providers.Salesforce.Suggestions do
  @moduledoc """
  Generates and formats Salesforce Contact update suggestions.
  """

  alias SocialScribe.AIContentGeneratorApi
  alias SocialScribe.CRM.Providers.Salesforce.Api
  alias SocialScribe.CRM.SuggestionsHelpers

  @standard_field_labels %{
    "firstname" => "First Name",
    "lastname" => "Last Name",
    "email" => "Email",
    "phone" => "Phone",
    "mobilephone" => "Mobile Phone",
    "title" => "Title",
    "department" => "Department",
    "mailingstreet" => "Mailing Street",
    "mailingcity" => "Mailing City",
    "mailingstate" => "Mailing State",
    "mailingpostalcode" => "Mailing Postal Code",
    "mailingcountry" => "Mailing Country"
  }

  @standard_field_api_to_key %{
    "FirstName" => "firstname",
    "LastName" => "lastname",
    "Email" => "email",
    "Phone" => "phone",
    "MobilePhone" => "mobilephone",
    "Title" => "title",
    "Department" => "department",
    "MailingStreet" => "mailingstreet",
    "MailingCity" => "mailingcity",
    "MailingState" => "mailingstate",
    "MailingPostalCode" => "mailingpostalcode",
    "MailingCountry" => "mailingcountry"
  }

  @default_mapping_fields Enum.map(@standard_field_labels, fn {name, label} ->
                            %{name: name, label: label, type: "string", options: []}
                          end)

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def default_mapping_fields, do: @default_mapping_fields

  def generate_suggestions(credential, contact_id, meeting) do
    describe_fields = fetch_describe_fields(credential)
    custom_fields = extract_custom_contact_fields(describe_fields)
    field_labels = build_field_labels(describe_fields)
    mapping_fields = build_mapping_fields(describe_fields)
    transcript_index = SuggestionsHelpers.build_transcript_index(meeting)

    with {:ok, contact} <- api_impl().get_contact(credential, contact_id),
         {:ok, ai_suggestions} <-
           AIContentGeneratorApi.generate_salesforce_suggestions(meeting, custom_fields) do
      suggestions =
        build_suggestions(ai_suggestions, field_labels, transcript_index,
          contact: contact,
          filter_unchanged: true,
          id_timestamp_source: :resolved,
          id_value_source: :normalized
        )

      {:ok,
       %{
         contact: contact,
         suggestions: suggestions,
         mapping_fields: mapping_fields,
         raw_ai_count: length(ai_suggestions)
       }}
    end
  end

  def generate_suggestions_from_meeting(meeting, credential) do
    describe_fields = fetch_describe_fields(credential)
    custom_fields = extract_custom_contact_fields(describe_fields)
    field_labels = build_field_labels(describe_fields)
    transcript_index = SuggestionsHelpers.build_transcript_index(meeting)

    case AIContentGeneratorApi.generate_salesforce_suggestions(meeting, custom_fields) do
      {:ok, ai_suggestions} ->
        suggestions =
          build_suggestions(ai_suggestions, field_labels, transcript_index,
            contact: nil,
            filter_unchanged: false,
            id_timestamp_source: :ai,
            id_value_source: :raw
          )

        {:ok, suggestions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def generate_suggestions_from_meeting(meeting) do
    transcript_index = SuggestionsHelpers.build_transcript_index(meeting)

    case AIContentGeneratorApi.generate_salesforce_suggestions(meeting) do
      {:ok, ai_suggestions} ->
        suggestions =
          build_suggestions(ai_suggestions, @standard_field_labels, transcript_index,
            contact: nil,
            filter_unchanged: false,
            id_timestamp_source: :ai,
            id_value_source: :raw
          )

        {:ok, suggestions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def merge_with_contact(suggestions, contact) when is_list(suggestions) do
    suggestions
    |> Enum.map(&with_contact_values(&1, contact))
    |> Enum.filter(& &1.has_change)
    |> SuggestionsHelpers.dedupe_suggestions()
  end

  def normalize_field_key(field) when is_binary(field) do
    Map.get(@standard_field_api_to_key, field, field)
  end

  def normalize_field_key(field), do: field

  def contact_field_value(contact, field) when is_map(contact) do
    case get_standard_contact_field(contact, field) do
      nil ->
        case SuggestionsHelpers.map_get(contact, field) do
          nil ->
            contact
            |> SuggestionsHelpers.map_get(:fields)
            |> case do
              map when is_map(map) -> SuggestionsHelpers.map_get(map, field)
              _ -> nil
            end

          value ->
            value
        end

      value ->
        value
    end
  end

  def contact_field_value(_, _), do: nil

  def normalize_field_value(field, value) when is_binary(field) do
    value
    |> SuggestionsHelpers.normalize_for_display()
    |> maybe_downcase_email(field)
  end

  def normalize_field_value(_field, value), do: SuggestionsHelpers.normalize_for_display(value)

  defdelegate changed?(current_value, new_value), to: SuggestionsHelpers
  defdelegate identifier_like_value?(field, label, value), to: SuggestionsHelpers

  # ---------------------------------------------------------------------------
  # Suggestion pipeline
  # ---------------------------------------------------------------------------

  defp build_suggestions(ai_suggestions, field_labels, transcript_index, opts) do
    contact = Keyword.get(opts, :contact)
    filter_unchanged = Keyword.get(opts, :filter_unchanged, false)
    id_timestamp_source = Keyword.get(opts, :id_timestamp_source, :resolved)
    id_value_source = Keyword.get(opts, :id_value_source, :normalized)

    ai_suggestions
    |> Enum.filter(&valid_ai_suggestion?(&1, field_labels))
    |> Enum.with_index(1)
    |> Enum.map(fn {suggestion, index} ->
      build_suggestion(
        suggestion,
        index,
        field_labels,
        transcript_index,
        contact,
        id_timestamp_source,
        id_value_source
      )
    end)
    |> maybe_filter_unchanged(filter_unchanged)
    |> SuggestionsHelpers.dedupe_suggestions()
  end

  defp build_suggestion(
         suggestion,
         index,
         field_labels,
         transcript_index,
         contact,
         id_timestamp_source,
         id_value_source
       ) do
    field = normalize_field_key(Map.get(suggestion, :field))
    label = Map.get(field_labels, field, field)
    raw_value = Map.get(suggestion, :value)
    new_value = normalize_field_value(field, raw_value)
    context = Map.get(suggestion, :context)

    current_value =
      case contact do
        map when is_map(map) -> normalize_field_value(field, contact_field_value(map, field))
        _ -> nil
      end

    resolved_timestamp =
      resolve_timestamp(
        Map.get(suggestion, :timestamp),
        context,
        raw_value,
        transcript_index
      )

    timestamp =
      case id_timestamp_source do
        :ai -> Map.get(suggestion, :timestamp)
        :resolved -> resolved_timestamp
      end

    id_value =
      case id_value_source do
        :raw -> raw_value
        :normalized -> new_value
      end

    has_change = if is_map(contact), do: SuggestionsHelpers.changed?(current_value, new_value), else: true

    %{
      id: suggestion_id(field, index, timestamp, id_value),
      field: field,
      mapped_field: field,
      label: label,
      mapped_label: label,
      current_value: current_value,
      new_value: new_value,
      context: context,
      timestamp: resolved_timestamp,
      apply: true,
      details_open: true,
      mapping_open: false,
      has_change: has_change
    }
  end

  defp maybe_filter_unchanged(suggestions, true), do: Enum.filter(suggestions, & &1.has_change)
  defp maybe_filter_unchanged(suggestions, false), do: suggestions

  defp with_contact_values(suggestion, contact) do
    field = Map.get(suggestion, :mapped_field) || Map.get(suggestion, :field)
    current_value = normalize_field_value(field, contact_field_value(contact, field))
    new_value = normalize_field_value(field, suggestion.new_value)
    has_change = SuggestionsHelpers.changed?(current_value, new_value)

    suggestion
    |> Map.put(:field, field)
    |> Map.put(:mapped_field, field)
    |> Map.put(:current_value, current_value)
    |> Map.put(:new_value, new_value)
    |> Map.put(:has_change, has_change)
    |> Map.put(:apply, has_change)
    |> Map.put_new(:details_open, true)
    |> Map.put_new(:mapping_open, false)
    |> Map.put_new(:mapped_label, Map.get(@standard_field_labels, field, field))
  end

  # ---------------------------------------------------------------------------
  # Field metadata helpers
  # ---------------------------------------------------------------------------

  defp fetch_describe_fields(credential) do
    case api_impl().describe_contact_fields(credential) do
      {:ok, fields} when is_list(fields) -> fields
      {:ok, _} -> []
      {:error, _reason} -> []
    end
  end

  defp extract_custom_contact_fields(describe_fields) do
    Enum.filter(describe_fields, fn field ->
      case Map.get(field, :name) || Map.get(field, "name") do
        name when is_binary(name) -> String.ends_with?(name, "__c")
        _ -> false
      end
    end)
  end

  defp build_mapping_fields([]), do: @default_mapping_fields

  defp build_mapping_fields(describe_fields) do
    describe_fields
    |> Enum.reduce([], fn field, acc ->
      name = normalize_field_key(Map.get(field, :name) || Map.get(field, "name"))
      label = Map.get(field, :label) || Map.get(field, "label") || name
      type = Map.get(field, :type) || Map.get(field, "type")
      options = picklist_options(field)

      if is_binary(name) and is_binary(label) do
        [%{name: name, label: label, type: type, options: options} | acc]
      else
        acc
      end
    end)
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(fn field -> String.downcase(field.label) end)
  end

  defp build_field_labels(describe_fields) do
    describe_labels =
      Enum.reduce(describe_fields, %{}, fn field, acc ->
        name = normalize_field_key(Map.get(field, :name) || Map.get(field, "name"))
        label = Map.get(field, :label) || Map.get(field, "label") || name

        if is_binary(name) and is_binary(label) do
          Map.put(acc, name, label)
        else
          acc
        end
      end)

    Map.merge(@standard_field_labels, describe_labels)
  end

  defp picklist_options(field) do
    field
    |> Map.get(:picklist_values, Map.get(field, "picklist_values", []))
    |> List.wrap()
    |> Enum.map(fn option ->
      case option do
        %{value: value, label: label} when is_binary(value) ->
          %{label: label || value, value: String.trim(value)}

        %{"value" => value, "label" => label} when is_binary(value) ->
          %{label: label || value, value: String.trim(value)}

        %{value: value} when is_binary(value) ->
          trimmed = String.trim(value)
          %{label: trimmed, value: trimmed}

        %{"value" => value} when is_binary(value) ->
          trimmed = String.trim(value)
          %{label: trimmed, value: trimmed}

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(fn %{value: v} -> v == "" end)
    |> Enum.uniq_by(& &1.value)
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp valid_ai_suggestion?(suggestion, field_labels) when is_map(suggestion) do
    field = normalize_field_key(Map.get(suggestion, :field))
    value = Map.get(suggestion, :value)
    label = Map.get(field_labels, field, field)

    is_binary(field) and is_binary(value) and String.trim(value) != "" and
      not SuggestionsHelpers.identifier_like_value?(field, label, value)
  end

  defp valid_ai_suggestion?(_, _field_labels), do: false

  # ---------------------------------------------------------------------------
  # Timestamp resolution (Salesforce-specific strategy)
  # ---------------------------------------------------------------------------

  # Takes the maximum of all candidate seconds from phrase and segment lookups,
  # which gives word-level precision when available. Falls back to the AI-provided
  # timestamp (normalised) when no transcript match exists, regardless of whether
  # the transcript has timing data.
  defp resolve_timestamp(ai_timestamp, context, value, transcript_index) do
    context_query = SuggestionsHelpers.normalize_text(context)
    value_query = SuggestionsHelpers.normalize_text(value)

    best =
      [
        SuggestionsHelpers.find_all_phrase_seconds(transcript_index, value_query),
        SuggestionsHelpers.find_all_phrase_seconds(transcript_index, context_query),
        SuggestionsHelpers.find_all_segment_seconds(transcript_index, value_query),
        SuggestionsHelpers.find_all_segment_seconds(transcript_index, context_query)
      ]
      |> List.flatten()
      |> Enum.filter(&is_number/1)
      |> Enum.max(fn -> nil end)

    case best do
      seconds when is_number(seconds) -> SuggestionsHelpers.format_mmss(seconds)
      _ -> SuggestionsHelpers.normalize_timestamp(ai_timestamp)
    end
  end

  # ---------------------------------------------------------------------------
  # Low-level helpers
  # ---------------------------------------------------------------------------

  defp suggestion_id(field, index, timestamp, new_value) do
    hash = :erlang.phash2({field, timestamp, new_value, index})
    "sf-suggestion-#{index}-#{hash}"
  end

  defp maybe_downcase_email(nil, _field), do: nil
  defp maybe_downcase_email(value, "email"), do: String.downcase(value)
  defp maybe_downcase_email(value, _field), do: value

  defp get_standard_contact_field(contact, field) when is_binary(field) do
    case field do
      "firstname" -> Map.get(contact, :firstname)
      "lastname" -> Map.get(contact, :lastname)
      "email" -> Map.get(contact, :email)
      "phone" -> Map.get(contact, :phone)
      "mobilephone" -> Map.get(contact, :mobilephone)
      "title" -> Map.get(contact, :title)
      "department" -> Map.get(contact, :department)
      "mailingstreet" -> Map.get(contact, :mailingstreet)
      "mailingcity" -> Map.get(contact, :mailingcity)
      "mailingstate" -> Map.get(contact, :mailingstate)
      "mailingpostalcode" -> Map.get(contact, :mailingpostalcode)
      "mailingcountry" -> Map.get(contact, :mailingcountry)
      _ -> nil
    end
  end

  defp get_standard_contact_field(_, _), do: nil

  defp api_impl do
    Application.get_env(:social_scribe, :salesforce_api, Api)
  end
end
