defmodule SocialScribe.CRM.SuggestionsHelpers do
  @moduledoc """
  Shared utilities for CRM suggestion generation across all providers.

  Covers:
  - Value normalization and comparison
  - Text/identifier processing
  - Suggestion deduplication
  - Transcript indexing and phrase lookup
  - Timestamp resolution
  - Low-level map and parsing utilities
  """

  # ---------------------------------------------------------------------------
  # Value normalization
  # ---------------------------------------------------------------------------

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

  def normalize_for_compare(nil), do: nil

  def normalize_for_compare(value) do
    value = normalize_for_display(value)

    case Decimal.parse(value) do
      {decimal, ""} ->
        {:numeric, decimal |> Decimal.normalize() |> Decimal.to_string(:normal)}

      _ ->
        {:text, value}
    end
  end

  def normalize_value(value) do
    case normalize_for_compare(value) do
      {:numeric, normalized} -> {:numeric, normalized}
      {:text, normalized} -> {:text, String.downcase(normalized)}
      nil -> nil
    end
  end

  def changed?(current_value, new_value),
    do: normalize_for_compare(current_value) != normalize_for_compare(new_value)

  # ---------------------------------------------------------------------------
  # Text and identifier processing
  # ---------------------------------------------------------------------------

  def normalize_text(nil), do: ""

  def normalize_text(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  def compact_text(nil), do: ""

  def compact_text(value) do
    value
    |> normalize_text()
    |> String.replace(" ", "")
  end

  def tokenize(value) do
    value
    |> normalize_text()
    |> case do
      "" -> []
      normalized -> String.split(normalized, " ", trim: true)
    end
  end

  def tokenize_with_timestamp(text, seconds) do
    text
    |> tokenize()
    |> Enum.map(fn token -> %{token: token, seconds: seconds} end)
  end

  # Strips camelCase boundaries, `__c` Salesforce suffixes, and non-alphanumerics
  # before comparing, so "JobTitle", "job_title", and "jobtitle__c" all collapse
  # to the same string.
  def collapse_identifier(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
    |> String.downcase()
    |> String.replace(~r/__c$/, "")
    |> String.replace(~r/[^a-z0-9]+/, "")
  end

  def collapse_identifier(_), do: nil

  @doc """
  Returns true when `value` collapses to the same identifier as `field` or
  `label`, which indicates the AI returned the field name itself as a value
  rather than a real value.
  """
  def identifier_like_value?(field, label, value) do
    normalized_value = collapse_identifier(value)

    normalized_value != "" and
      normalized_value in Enum.reject(
        [collapse_identifier(field), collapse_identifier(label)],
        &(&1 in [nil, ""])
      )
  end

  # ---------------------------------------------------------------------------
  # Deduplication
  # ---------------------------------------------------------------------------

  @doc """
  Deduplicates suggestions by `{mapped_field, normalized_value}` key, keeping
  the most recent (latest timestamp) when duplicates exist.
  """
  def dedupe_suggestions(suggestions) do
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

  def suggestion_key(suggestion) do
    {
      Map.get(suggestion, :mapped_field) || Map.get(suggestion, :field),
      normalize_value(Map.get(suggestion, :new_value))
    }
  end

  def more_recent?(left, right), do: timestamp_seconds(left) >= timestamp_seconds(right)

  def timestamp_seconds(%{timestamp: timestamp}) when is_binary(timestamp) do
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

  def timestamp_seconds(_), do: -1

  # ---------------------------------------------------------------------------
  # Transcript indexing
  # ---------------------------------------------------------------------------

  def build_transcript_index(%{meeting_transcript: %{content: content}}) when is_map(content) do
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

  def build_transcript_index(_), do: %{segments: [], words: []}

  def segment_from_transcript(segment) when is_map(segment) do
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

  def segment_from_transcript(_), do: nil

  def build_segment_words(words) do
    words
    |> Enum.flat_map(fn word ->
      text = map_get(word, "text") || map_get(word, :text) || ""

      seconds =
        extract_seconds(map_get(word, "start_timestamp") || map_get(word, :start_timestamp))

      tokenize_with_timestamp(text, seconds)
    end)
  end

  def build_word_entries(segment_entries),
    do: Enum.flat_map(segment_entries, &Map.get(&1, :words, []))

  def segment_seconds(segment, words) do
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

  # ---------------------------------------------------------------------------
  # Timestamp resolution
  # ---------------------------------------------------------------------------

  # Strategy:
  # 1. Collect ALL matching timestamps from phrase and segment lookups (ignoring
  #    0-second results, which indicate a word was found but carries no timing data).
  # 2. If matches exist and the AI provided a timestamp hint, pick the occurrence
  #    nearest to it.
  # 3. If matches exist and the AI has no timestamp, pick the latest occurrence.
  # 4. If no matches exist but the transcript has timing data, return nil (don't
  #    trust AI timestamp).
  # 5. If the transcript has no timing data at all, fall back to the AI-provided
  #    timestamp.
  def resolve_timestamp(ai_timestamp, context, value, transcript_index) do
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

  def transcript_has_timing?(%{words: words}) when is_list(words) do
    Enum.any?(words, fn %{seconds: s} -> is_number(s) and s > 0 end)
  end

  def transcript_has_timing?(_), do: false

  def parse_ai_timestamp_seconds(nil), do: nil

  def parse_ai_timestamp_seconds(timestamp) when is_binary(timestamp) do
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

  def parse_ai_timestamp_seconds(_), do: nil

  def find_all_segment_seconds(%{segments: segments}, query) when is_binary(query),
    do: find_all_segment_seconds(segments, query)

  def find_all_segment_seconds(segments, query) when is_list(segments) and is_binary(query) do
    case String.trim(query) do
      "" ->
        []

      normalized_query ->
        segments
        |> Enum.filter(fn segment -> String.contains?(segment.normalized, normalized_query) end)
        |> Enum.map(& &1.seconds)
    end
  end

  def find_all_segment_seconds(_, _), do: []

  def find_all_phrase_seconds(%{words: words}, query) when is_list(words) and is_binary(query) do
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

  def find_all_phrase_seconds(_, _), do: []

  def phrase_matches_at?(words, start_index, tokens) do
    words
    |> Enum.drop(start_index)
    |> Enum.take(length(tokens))
    |> Enum.map(& &1.token) == tokens
  end

  def matched_seconds(words, start_index, token_count, fallback_seconds) do
    words
    |> Enum.drop(start_index)
    |> Enum.take(token_count)
    |> Enum.find_value(fn %{seconds: seconds} ->
      if is_number(seconds) and seconds > 0, do: seconds
    end) || fallback_seconds
  end

  def normalize_timestamp(timestamp) when is_binary(timestamp) do
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

  def normalize_timestamp(_), do: nil

  def format_mmss(seconds) when is_number(seconds) do
    total_seconds = max(trunc(seconds), 0)
    minutes = div(total_seconds, 60)
    secs = rem(total_seconds, 60)

    "#{String.pad_leading(Integer.to_string(minutes), 2, "0")}:#{String.pad_leading(Integer.to_string(secs), 2, "0")}"
  end

  # ---------------------------------------------------------------------------
  # Low-level utilities
  # ---------------------------------------------------------------------------

  def extract_seconds(%{} = value) do
    relative = map_get(value, "relative") || map_get(value, :relative)
    seconds = map_get(value, "seconds") || map_get(value, :seconds)
    secs = map_get(value, "secs") || map_get(value, :secs)

    parse_seconds(relative) || parse_seconds(seconds) || parse_seconds(secs) || 0
  end

  def extract_seconds(value) when is_number(value), do: value
  def extract_seconds(value) when is_binary(value), do: parse_seconds(value) || 0
  def extract_seconds(_), do: 0

  def parse_seconds(value) when is_integer(value) or is_float(value), do: value

  def parse_seconds(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Float.parse(trimmed) do
      {seconds, ""} -> seconds
      _ -> nil
    end
  end

  def parse_seconds(_), do: nil

  def map_get(map, key) when is_map(map) do
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

  def map_get(_, _), do: nil

  def safe_to_existing_atom(key) when is_binary(key) do
    try do
      {:ok, String.to_existing_atom(key)}
    rescue
      ArgumentError -> :error
    end
  end
end
