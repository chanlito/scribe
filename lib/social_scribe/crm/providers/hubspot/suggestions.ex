defmodule SocialScribe.CRM.Providers.Hubspot.Suggestions do
  @moduledoc """
  Generates and formats HubSpot contact update suggestions by combining
  AI-extracted data with existing HubSpot contact information.
  """

  alias SocialScribe.AIContentGeneratorApi
  alias SocialScribe.Accounts.UserCredential
  alias SocialScribe.CRM.Providers.Hubspot.Api

  @allowed_fields ~w(
    firstname
    lastname
    email
    phone
    mobilephone
    company
    jobtitle
    address
    city
    state
    zip
    country
    website
    linkedin_url
    twitter_handle
  )

  @field_labels %{
    "firstname" => "First Name",
    "lastname" => "Last Name",
    "email" => "Email",
    "phone" => "Phone",
    "mobilephone" => "Mobile Phone",
    "company" => "Company",
    "jobtitle" => "Job Title",
    "address" => "Address",
    "city" => "City",
    "state" => "State",
    "zip" => "ZIP Code",
    "country" => "Country",
    "website" => "Website",
    "linkedin_url" => "LinkedIn",
    "twitter_handle" => "Twitter"
  }

  def allowed_fields, do: @allowed_fields

  def default_mapping_fields do
    Enum.map(@allowed_fields, fn field ->
      %{
        name: field,
        label: Map.get(@field_labels, field, field),
        type: "string",
        options: []
      }
    end)
  end

  @doc """
  Generates suggested updates for a HubSpot contact based on a meeting transcript.

  Returns a list of suggestion maps, each containing:
  - field: the HubSpot field name
  - label: human-readable field label
  - current_value: the existing value in HubSpot (or nil)
  - new_value: the AI-suggested value
  - context: explanation of where this was found in the transcript
  - apply: boolean indicating whether to apply this update (default false)
  """
  def generate_suggestions(%UserCredential{} = credential, contact_id, meeting) do
    transcript_index = build_transcript_index(meeting)

    with {:ok, contact} <- api_impl().get_contact(credential, contact_id),
         {:ok, ai_suggestions} <- AIContentGeneratorApi.generate_hubspot_suggestions(meeting) do
      suggestions =
        ai_suggestions
        |> prepare_ai_suggestions(transcript_index)
        |> merge_with_contact(contact)

      {:ok, %{contact: contact, suggestions: suggestions}}
    end
  end

  @doc """
  Generates suggestions without fetching contact data.
  Useful when contact hasn't been selected yet.
  """
  def generate_suggestions_from_meeting(meeting) do
    transcript_index = build_transcript_index(meeting)

    case AIContentGeneratorApi.generate_hubspot_suggestions(meeting) do
      {:ok, ai_suggestions} ->
        suggestions = prepare_ai_suggestions(ai_suggestions, transcript_index)

        {:ok, suggestions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Merges AI suggestions with contact data to show current vs suggested values.
  """
  def merge_with_contact(suggestions, contact) when is_list(suggestions) do
    suggestions
    |> Enum.map(fn suggestion ->
      field = Map.get(suggestion, :mapped_field) || Map.get(suggestion, :field)
      label = Map.get(suggestion, :mapped_label) || Map.get(suggestion, :label) || field

      current_value =
        contact
        |> contact_field_value(field)
        |> then(&normalize_field_value(field, &1))

      new_value =
        suggestion
        |> Map.get(:new_value, Map.get(suggestion, :value))
        |> then(&normalize_field_value(field, &1))

      has_change = changed?(current_value, new_value)
      timestamp = Map.get(suggestion, :timestamp)
      computed_id = Map.get(suggestion, :id, suggestion_id(field, 0, timestamp, new_value))

      suggestion
      |> Map.put(:id, computed_id)
      |> Map.put(:field, field)
      |> Map.put(:mapped_field, field)
      |> Map.put(:label, label)
      |> Map.put(:mapped_label, label)
      |> Map.put(:current_value, current_value)
      |> Map.put(:new_value, new_value)
      |> Map.put(:has_change, has_change)
      |> Map.put(:apply, has_change)
      |> Map.put_new(:details_open, true)
      |> Map.put_new(:mapping_open, false)
    end)
    |> Enum.filter(& &1.has_change)
    |> dedupe_suggestions()
  end

  def normalize_field_key(field) when is_binary(field) do
    field
    |> String.trim()
    |> String.downcase()
  end

  def normalize_field_key(_), do: nil

  def allowed_field?(field) when is_binary(field), do: field in @allowed_fields
  def allowed_field?(_), do: false

  def normalize_field_value("email", value) do
    value
    |> normalize_for_display()
    |> then(fn
      nil -> nil
      normalized -> String.downcase(normalized)
    end)
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

  def changed?(current_value, new_value),
    do: normalize_for_compare(current_value) != normalize_for_compare(new_value)

  def identifier_like_value?(field, label, value) do
    normalized_value = collapse_identifier(value)

    normalized_value != "" and
      normalized_value in Enum.reject(
        [collapse_identifier(field), collapse_identifier(label)],
        &(&1 in [nil, ""])
      )
  end

  def contact_field_value(contact, field) when is_map(contact) and is_binary(field) do
    case get_standard_contact_field(contact, field) do
      nil ->
        map_get(contact, field)

      value ->
        value
    end
  end

  def contact_field_value(_, _), do: nil

  defp prepare_ai_suggestions(ai_suggestions, transcript_index) do
    ai_suggestions
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn suggestion ->
      field =
        suggestion
        |> Map.get(:field, Map.get(suggestion, "field"))
        |> normalize_field_key()

      value = Map.get(suggestion, :value, Map.get(suggestion, "value"))
      context = Map.get(suggestion, :context, Map.get(suggestion, "context"))
      ai_timestamp = Map.get(suggestion, :timestamp, Map.get(suggestion, "timestamp"))
      label = Map.get(@field_labels, field, field)

      %{
        field: field,
        mapped_field: field,
        label: label,
        mapped_label: label,
        current_value: nil,
        new_value: normalize_field_value(field, value),
        context: context,
        timestamp: resolve_timestamp(ai_timestamp, context, value, transcript_index),
        apply: true,
        details_open: true,
        mapping_open: false
      }
    end)
    |> Enum.filter(&valid_suggestion?/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {suggestion, idx} ->
      suggestion
      |> Map.put(
        :id,
        suggestion_id(suggestion.field, idx, suggestion.timestamp, suggestion.new_value)
      )
      |> Map.put(:has_change, true)
    end)
    |> dedupe_suggestions()
  end

  defp valid_suggestion?(%{field: field, new_value: value, label: label}) do
    allowed_field?(field) and is_binary(value) and value != "" and
      not identifier_like_value?(field, label, value)
  end

  defp valid_suggestion?(_), do: false

  defp dedupe_suggestions(suggestions) do
    {order, suggestions_by_key} =
      Enum.reduce(suggestions, {[], %{}}, fn suggestion, {order, suggestions_by_key} ->
        key = suggestion_key(suggestion)

        case suggestions_by_key do
          %{^key => existing} ->
            chosen = if more_recent?(suggestion, existing), do: suggestion, else: existing
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

  defp more_recent?(left, right), do: timestamp_seconds(left) >= timestamp_seconds(right)

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
            compact: compact_text(text),
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

  defp build_word_entries(segment_entries),
    do: Enum.flat_map(segment_entries, &Map.get(&1, :words, []))

  defp segment_seconds(segment, words) do
    word_seconds =
      Enum.find_value(words, fn word ->
        seconds =
          extract_seconds(map_get(word, "start_timestamp") || map_get(word, :start_timestamp))

        if is_number(seconds) and seconds > 0, do: seconds
      end)

    case word_seconds do
      seconds when is_number(seconds) ->
        seconds

      _ ->
        extract_seconds(map_get(segment, "start_timestamp") || map_get(segment, :start_timestamp))
    end
  end

  # Timestamp resolution strategy:
  # 1. Collect ALL matching timestamps from phrase and segment lookups (ignoring 0-second results,
  #    which indicate a word was found but carries no timing data).
  # 2. If matches exist and the AI provided a timestamp hint, pick the occurrence nearest to it.
  # 3. If matches exist and the AI has no timestamp, pick the latest occurrence.
  # 4. If no matches exist but the transcript has timing data, return nil (don't trust AI timestamp).
  # 5. If the transcript has no timing data at all, fall back to the AI-provided timestamp.
  defp resolve_timestamp(ai_timestamp, context, value, transcript_index) do
    context_query = normalize_text(context)
    value_query = normalize_text(value)

    all_seconds =
      [
        find_all_phrase_seconds(transcript_index, value_query),
        find_all_phrase_seconds(transcript_index, context_query),
        find_all_segment_seconds(transcript_index, value_query),
        find_all_segment_seconds(transcript_index, context_query)
      ]
      |> List.flatten()
      |> Enum.filter(fn s -> is_number(s) and s > 0 end)

    case all_seconds do
      [] ->
        if transcript_has_timing?(transcript_index),
          do: nil,
          else: normalize_timestamp(ai_timestamp)

      seconds_list ->
        best =
          case parse_ai_timestamp_seconds(ai_timestamp) do
            nil -> Enum.max(seconds_list)
            ai_s -> Enum.min_by(seconds_list, fn s -> abs(s - ai_s) end)
          end

        format_mmss(best)
    end
  end

  defp transcript_has_timing?(%{words: words}) when is_list(words) do
    Enum.any?(words, fn %{seconds: s} -> is_number(s) and s > 0 end)
  end

  defp transcript_has_timing?(_), do: false

  defp parse_ai_timestamp_seconds(nil), do: nil

  defp parse_ai_timestamp_seconds(timestamp) when is_binary(timestamp) do
    case String.split(String.trim(timestamp), ":") do
      [minutes, seconds] ->
        with {m, ""} <- Integer.parse(minutes),
             {s, ""} <- Integer.parse(seconds) do
          m * 60 + s
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_ai_timestamp_seconds(_), do: nil

  defp find_all_segment_seconds(%{segments: segments}, query) when is_binary(query),
    do: find_all_segment_seconds(segments, query)

  defp find_all_segment_seconds(segments, query) when is_list(segments) and is_binary(query) do
    case String.trim(query) do
      "" ->
        []

      normalized_query ->
        segments
        |> Enum.filter(fn segment -> String.contains?(segment.normalized, normalized_query) end)
        |> Enum.map(& &1.seconds)
    end
  end

  defp find_all_segment_seconds(_, _), do: []

  defp find_all_phrase_seconds(%{words: words}, query) when is_list(words) and is_binary(query) do
    tokens = tokenize(query)

    case tokens do
      [] ->
        []

      _ ->
        words
        |> Enum.with_index()
        |> Enum.flat_map(fn {%{token: token, seconds: seconds}, index} ->
          if token == hd(tokens) and phrase_matches_at?(words, index, tokens) do
            case matched_seconds(words, index, length(tokens), seconds) do
              s when is_number(s) -> [s]
              _ -> []
            end
          else
            []
          end
        end)
    end
  end

  defp find_all_phrase_seconds(_, _), do: []

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
    "hubspot-suggestion-#{index}-#{hash}"
  end

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

  defp collapse_identifier(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "")
  end

  defp collapse_identifier(_), do: nil

  defp normalize_text(nil), do: ""

  defp normalize_text(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp compact_text(nil), do: ""

  defp compact_text(value) do
    value
    |> normalize_text()
    |> String.replace(" ", "")
  end

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

  defp get_standard_contact_field(contact, field) do
    case field do
      "firstname" -> Map.get(contact, :firstname)
      "lastname" -> Map.get(contact, :lastname)
      "email" -> Map.get(contact, :email)
      "phone" -> Map.get(contact, :phone)
      "mobilephone" -> Map.get(contact, :mobilephone)
      "company" -> Map.get(contact, :company)
      "jobtitle" -> Map.get(contact, :jobtitle)
      "address" -> Map.get(contact, :address)
      "city" -> Map.get(contact, :city)
      "state" -> Map.get(contact, :state)
      "zip" -> Map.get(contact, :zip)
      "country" -> Map.get(contact, :country)
      "website" -> Map.get(contact, :website)
      "linkedin_url" -> Map.get(contact, :linkedin_url)
      "twitter_handle" -> Map.get(contact, :twitter_handle)
      _ -> nil
    end
  end

  defp extract_seconds(%{} = value) do
    relative = map_get(value, "relative") || map_get(value, :relative)
    seconds = map_get(value, "seconds") || map_get(value, :seconds)
    secs = map_get(value, "secs") || map_get(value, :secs)

    parse_seconds(relative) || parse_seconds(seconds) || parse_seconds(secs) || 0
  end

  defp extract_seconds(value) when is_number(value), do: value
  defp extract_seconds(value) when is_binary(value), do: parse_seconds(value) || 0
  defp extract_seconds(_), do: 0

  defp parse_seconds(value) when is_integer(value) or is_float(value), do: value

  defp parse_seconds(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Float.parse(trimmed) do
      {seconds, ""} -> seconds
      _ -> nil
    end
  end

  defp parse_seconds(_), do: nil

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

  defp api_impl do
    Application.get_env(:social_scribe, :hubspot_api, Api)
  end
end
