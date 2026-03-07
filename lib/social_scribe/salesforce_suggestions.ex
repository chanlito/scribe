defmodule SocialScribe.SalesforceSuggestions do
  @moduledoc """
  Generates and formats Salesforce Contact update suggestions.
  """

  alias SocialScribe.AIContentGeneratorApi
  alias SocialScribe.SalesforceApiBehaviour, as: SalesforceApi

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
                            %{name: name, label: label, type: "string"}
                          end)

  def default_mapping_fields, do: @default_mapping_fields

  def generate_suggestions(credential, contact_id, meeting) do
    describe_fields = fetch_describe_fields(credential)
    custom_fields = extract_custom_contact_fields(describe_fields)
    field_labels = build_field_labels(describe_fields)
    mapping_fields = build_mapping_fields(describe_fields)
    transcript_index = build_transcript_index(meeting)

    with {:ok, contact} <- SalesforceApi.get_contact(credential, contact_id),
         {:ok, ai_suggestions} <-
           AIContentGeneratorApi.generate_salesforce_suggestions(meeting, custom_fields) do
      suggestions =
        ai_suggestions
        |> Enum.filter(&valid_ai_suggestion?(&1, field_labels))
        |> Enum.with_index(1)
        |> Enum.map(fn {suggestion, idx} ->
          field = normalize_field_key(suggestion.field)
          label = Map.get(field_labels, field, field)
          current_value = normalize_field_value(field, contact_field_value(contact, field))
          new_value = normalize_field_value(field, suggestion.value)

          timestamp =
            resolve_timestamp(
              Map.get(suggestion, :timestamp),
              Map.get(suggestion, :context),
              suggestion.value,
              transcript_index
            )

          %{
            id: suggestion_id(field, idx, timestamp, new_value),
            field: field,
            mapped_field: field,
            label: label,
            mapped_label: label,
            current_value: current_value,
            new_value: new_value,
            context: suggestion.context,
            timestamp: timestamp,
            apply: true,
            details_open: true,
            mapping_open: false,
            has_change: changed?(current_value, new_value)
          }
        end)
        |> Enum.filter(fn suggestion -> suggestion.has_change end)
        |> dedupe_suggestions()

      {:ok, %{contact: contact, suggestions: suggestions, mapping_fields: mapping_fields}}
    end
  end

  def generate_suggestions_from_meeting(meeting, credential) do
    describe_fields = fetch_describe_fields(credential)
    custom_fields = extract_custom_contact_fields(describe_fields)
    field_labels = build_field_labels(describe_fields)
    transcript_index = build_transcript_index(meeting)

    case AIContentGeneratorApi.generate_salesforce_suggestions(meeting, custom_fields) do
      {:ok, ai_suggestions} ->
        suggestions =
          ai_suggestions
          |> Enum.filter(&valid_ai_suggestion?(&1, field_labels))
          |> Enum.with_index(1)
          |> Enum.map(fn {suggestion, idx} ->
            field = normalize_field_key(suggestion.field)
            label = Map.get(field_labels, field, field)

            %{
              id: suggestion_id(field, idx, Map.get(suggestion, :timestamp), suggestion.value),
              field: field,
              mapped_field: field,
              label: label,
              mapped_label: label,
              current_value: nil,
              new_value: normalize_field_value(field, suggestion.value),
              context: Map.get(suggestion, :context),
              timestamp:
                resolve_timestamp(
                  Map.get(suggestion, :timestamp),
                  Map.get(suggestion, :context),
                  suggestion.value,
                  transcript_index
                ),
              apply: true,
              details_open: true,
              mapping_open: false,
              has_change: true
            }
          end)
          |> dedupe_suggestions()

        {:ok, suggestions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def generate_suggestions_from_meeting(meeting) do
    transcript_index = build_transcript_index(meeting)

    case AIContentGeneratorApi.generate_salesforce_suggestions(meeting) do
      {:ok, ai_suggestions} ->
        suggestions =
          ai_suggestions
          |> Enum.filter(&valid_ai_suggestion?(&1, @standard_field_labels))
          |> Enum.with_index(1)
          |> Enum.map(fn {suggestion, idx} ->
            field = normalize_field_key(suggestion.field)
            label = Map.get(@standard_field_labels, field, field)

            %{
              id: suggestion_id(field, idx, Map.get(suggestion, :timestamp), suggestion.value),
              field: field,
              mapped_field: field,
              label: label,
              mapped_label: label,
              current_value: nil,
              new_value: normalize_field_value(field, suggestion.value),
              context: Map.get(suggestion, :context),
              timestamp:
                resolve_timestamp(
                  Map.get(suggestion, :timestamp),
                  Map.get(suggestion, :context),
                  suggestion.value,
                  transcript_index
                ),
              apply: true,
              details_open: true,
              mapping_open: false,
              has_change: true
            }
          end)
          |> dedupe_suggestions()

        {:ok, suggestions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def merge_with_contact(suggestions, contact) when is_list(suggestions) do
    suggestions
    |> Enum.map(fn suggestion ->
      field = Map.get(suggestion, :mapped_field) || Map.get(suggestion, :field)
      current_value = normalize_field_value(field, contact_field_value(contact, field))
      new_value = normalize_field_value(field, suggestion.new_value)
      has_change = changed?(current_value, new_value)

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
    end)
    |> Enum.filter(fn suggestion -> suggestion.has_change end)
    |> dedupe_suggestions()
  end

  def normalize_field_key(field) when is_binary(field) do
    Map.get(@standard_field_api_to_key, field, field)
  end

  def normalize_field_key(field), do: field

  def contact_field_value(contact, field) when is_map(contact) do
    case get_standard_contact_field(contact, field) do
      nil ->
        contact
        |> map_get(:fields)
        |> case do
          map when is_map(map) -> map_get(map, field)
          _ -> nil
        end

      value ->
        value
    end
  end

  def contact_field_value(_, _), do: nil

  def normalize_field_value(field, value) when is_binary(field) do
    value
    |> normalize_for_display()
    |> maybe_downcase_email(field)
  end

  def normalize_field_value(_field, value), do: normalize_for_display(value)

  def normalize_for_display(nil), do: nil

  def normalize_for_display(%Decimal{} = value) do
    value
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  def normalize_for_display(value) when is_float(value) do
    value
    |> :erlang.float_to_binary(decimals: 15)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
    |> case do
      "-0" -> "0"
      result -> result
    end
  end

  def normalize_for_display(value) when is_integer(value), do: Integer.to_string(value)
  def normalize_for_display(value) when is_binary(value), do: String.trim(value)
  def normalize_for_display(value) when is_boolean(value), do: to_string(value)
  def normalize_for_display(value), do: inspect(value)

  def changed?(current_value, new_value) do
    normalize_for_compare(current_value) != normalize_for_compare(new_value)
  end

  def identifier_like_value?(field, label, value) do
    malformed_identifier_value?(field, label, value)
  end

  defp valid_ai_suggestion?(suggestion, field_labels) when is_map(suggestion) do
    field = normalize_field_key(Map.get(suggestion, :field))
    value = Map.get(suggestion, :value)
    label = Map.get(field_labels, field, field)

    is_binary(field) and is_binary(value) and String.trim(value) != "" and
      not malformed_identifier_value?(field, label, value)
  end

  defp valid_ai_suggestion?(_, _field_labels), do: false

  defp malformed_identifier_value?(field, label, value) do
    normalized_value = collapse_identifier(value)

    normalized_value != "" and
      normalized_value in Enum.reject(
        [
          collapse_identifier(field),
          collapse_identifier(label)
        ],
        &(&1 in [nil, ""])
      )
  end

  defp collapse_identifier(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
    |> String.downcase()
    |> String.replace(~r/__c$/, "")
    |> String.replace(~r/[^a-z0-9]+/, "")
  end

  defp collapse_identifier(_), do: nil

  defp dedupe_suggestions(suggestions) do
    {order, suggestions_by_key} =
      Enum.reduce(suggestions, {[], %{}}, fn suggestion, {order, suggestions_by_key} ->
        key = suggestion_key(suggestion)

        case suggestions_by_key do
          %{^key => existing} ->
            chosen =
              if more_recent?(suggestion, existing), do: suggestion, else: existing

            {order, Map.put(suggestions_by_key, key, chosen)}

          _ ->
            {[key | order], Map.put(suggestions_by_key, key, suggestion)}
        end
      end)

    order
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(suggestions_by_key, &1))
  end

  defp suggestion_key(suggestion) do
    {
      Map.get(suggestion, :mapped_field) || Map.get(suggestion, :field),
      normalize_value(Map.get(suggestion, :new_value))
    }
  end

  defp normalize_value(value) do
    case normalize_for_compare(value) do
      {:numeric, normalized} -> {:numeric, normalized}
      {:text, normalized} -> {:text, String.downcase(normalized)}
      nil -> nil
    end
  end

  defp more_recent?(left, right) do
    timestamp_seconds(left) >= timestamp_seconds(right)
  end

  defp timestamp_seconds(%{timestamp: timestamp}) when is_binary(timestamp) do
    case String.split(timestamp, ":") do
      [minutes, seconds] ->
        with {minutes, ""} <- Integer.parse(minutes),
             {seconds, ""} <- Integer.parse(seconds) do
          minutes * 60 + seconds
        else
          _ -> -1
        end

      _ ->
        -1
    end
  end

  defp timestamp_seconds(_), do: -1

  defp fetch_describe_fields(credential) do
    case SalesforceApi.describe_contact_fields(credential) do
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

      if is_binary(name) and is_binary(label) do
        [%{name: name, label: label, type: type} | acc]
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

  defp build_transcript_index(%{meeting_transcript: %{content: content}}) when is_map(content) do
    segments =
      content
      |> map_get("data")
      |> case do
        nil -> content |> map_get(:data)
        data -> data
      end

    case segments do
      transcript_segments when is_list(transcript_segments) ->
        segment_entries =
          transcript_segments
          |> Enum.map(&segment_from_transcript/1)
          |> Enum.reject(&is_nil/1)

        %{
          segments: segment_entries,
          words: build_word_entries(segment_entries)
        }

      _ ->
        %{segments: [], words: []}
    end
  end

  defp build_transcript_index(_), do: %{segments: [], words: []}

  defp segment_from_transcript(segment) when is_map(segment) do
    words =
      segment
      |> map_get("words")
      |> case do
        nil -> map_get(segment, :words)
        value -> value
      end

    cond do
      not is_list(words) ->
        nil

      true ->
        text =
          words
          |> Enum.map_join(" ", fn word ->
            map_get(word, "text") || map_get(word, :text) || ""
          end)
          |> String.trim()

        if text == "" do
          nil
        else
          %{
            normalized: normalize_text(text),
            seconds: segment_seconds(segment, words),
            words: build_segment_words(words)
          }
        end
    end
  end

  defp segment_from_transcript(_), do: nil

  defp build_segment_words(words) do
    words
    |> Enum.flat_map(fn word ->
      text = map_get(word, "text") || map_get(word, :text) || ""

      seconds =
        extract_seconds(map_get(word, "start_timestamp") || map_get(word, :start_timestamp))

      tokenize_with_timestamp(text, seconds)
    end)
  end

  defp build_word_entries(segment_entries) do
    segment_entries
    |> Enum.flat_map(&Map.get(&1, :words, []))
  end

  defp segment_seconds(segment, words) do
    word_seconds =
      Enum.find_value(words, fn word ->
        seconds =
          extract_seconds(map_get(word, "start_timestamp") || map_get(word, :start_timestamp))

        if is_number(seconds) and seconds > 0 do
          seconds
        end
      end)

    case word_seconds do
      seconds when is_number(seconds) ->
        seconds

      _ ->
        extract_seconds(map_get(segment, "start_timestamp") || map_get(segment, :start_timestamp))
    end
  end

  defp resolve_timestamp(ai_timestamp, context, value, transcript_index) do
    context_query = normalize_text(context)
    value_query = normalize_text(value)

    resolved_seconds =
      [
        find_phrase_seconds(transcript_index, value_query),
        find_phrase_seconds(transcript_index, context_query),
        find_segment_seconds(transcript_index, value_query),
        find_segment_seconds(transcript_index, context_query)
      ]
      |> Enum.filter(&is_number/1)
      |> Enum.max(fn -> nil end)

    cond do
      is_number(resolved_seconds) ->
        format_mmss(resolved_seconds)

      true ->
        normalize_timestamp(ai_timestamp)
    end
  end

  defp find_segment_seconds(%{segments: segments}, query) when is_binary(query),
    do: find_segment_seconds(segments, query)

  defp find_segment_seconds(segments, query) when is_list(segments) and is_binary(query) do
    case String.trim(query) do
      "" ->
        nil

      normalized_query ->
        Enum.find_value(segments, fn segment ->
          if String.contains?(segment.normalized, normalized_query), do: segment.seconds
        end)
    end
  end

  defp find_segment_seconds(_, _), do: nil

  defp find_phrase_seconds(%{words: words}, query) when is_list(words) and is_binary(query) do
    tokens = tokenize(query)

    case tokens do
      [] ->
        nil

      _ ->
        words
        |> Enum.with_index()
        |> Enum.find_value(fn {%{token: token, seconds: seconds}, index} ->
          if token == hd(tokens) and phrase_matches_at?(words, index, tokens) do
            matched_seconds(words, index, length(tokens), seconds)
          end
        end)
    end
  end

  defp find_phrase_seconds(_, _), do: nil

  defp phrase_matches_at?(words, start_index, tokens) do
    words
    |> Enum.drop(start_index)
    |> Enum.take(length(tokens))
    |> Enum.map(& &1.token) == tokens
  end

  defp matched_seconds(words, start_index, token_count, fallback_seconds) do
    words
    |> Enum.drop(start_index)
    |> Enum.take(token_count)
    |> Enum.find_value(fn %{seconds: seconds} ->
      if is_number(seconds) and seconds > 0, do: seconds
    end) || fallback_seconds
  end

  defp normalize_timestamp(timestamp) when is_binary(timestamp) do
    case String.split(String.trim(timestamp), ":") do
      [minutes, seconds] ->
        with {minutes, ""} <- Integer.parse(minutes),
             {seconds, ""} <- Integer.parse(seconds) do
          format_mmss(minutes * 60 + seconds)
        else
          _ -> timestamp
        end

      _ ->
        timestamp
    end
  end

  defp normalize_timestamp(_), do: nil

  defp format_mmss(seconds) when is_number(seconds) do
    total_seconds = max(trunc(seconds), 0)
    minutes = div(total_seconds, 60)
    secs = rem(total_seconds, 60)

    "#{String.pad_leading(Integer.to_string(minutes), 2, "0")}:#{String.pad_leading(Integer.to_string(secs), 2, "0")}"
  end

  defp suggestion_id(field, index, timestamp, new_value) do
    hash = :erlang.phash2({field, timestamp, new_value, index})
    "sf-suggestion-#{index}-#{hash}"
  end

  defp extract_seconds(%{} = value) do
    relative = map_get(value, "relative") || map_get(value, :relative)

    cond do
      is_number(relative) -> relative
      true -> 0
    end
  end

  defp extract_seconds(value) when is_number(value), do: value
  defp extract_seconds(_), do: 0

  defp normalize_text(nil), do: ""

  defp normalize_text(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp maybe_downcase_email(nil, _field), do: nil
  defp maybe_downcase_email(value, "email"), do: String.downcase(value)
  defp maybe_downcase_email(value, _field), do: value

  defp tokenize(value) do
    value
    |> normalize_text()
    |> case do
      "" -> []
      normalized -> String.split(normalized, " ", trim: true)
    end
  end

  defp tokenize_with_timestamp(text, seconds) do
    text
    |> tokenize()
    |> Enum.map(fn token -> %{token: token, seconds: seconds} end)
  end

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

  defp normalize_for_compare(nil), do: nil

  defp normalize_for_compare(value) do
    value = normalize_for_display(value)

    case Decimal.parse(value) do
      {decimal, ""} ->
        {:numeric, decimal |> Decimal.normalize() |> Decimal.to_string(:normal)}

      _ ->
        {:text, value}
    end
  end

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) ||
      case key do
        atom when is_atom(atom) ->
          Map.get(map, Atom.to_string(atom))

        binary when is_binary(binary) ->
          case safe_to_existing_atom(binary) do
            {:ok, atom_key} -> Map.get(map, atom_key)
            :error -> nil
          end

        _ ->
          nil
      end
  end

  defp map_get(_, _), do: nil

  defp safe_to_existing_atom(key) when is_binary(key) do
    try do
      {:ok, String.to_existing_atom(key)}
    rescue
      ArgumentError -> :error
    end
  end
end
