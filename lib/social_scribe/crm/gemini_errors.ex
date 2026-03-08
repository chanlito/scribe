defmodule SocialScribe.CRM.GeminiErrors do
  @moduledoc """
  Shared helpers for formatting Gemini API errors in CRM provider suggestion callbacks.
  """

  @doc """
  Formats a suggestion error into a structured error map.
  Handles Gemini rate-limit (429), config errors, and generic fallbacks.
  """
  def format_suggestion_error({:api_error, 429, body}) do
    retry_seconds = extract_retry_seconds(body)

    retry_hint =
      if retry_seconds do
        " Please retry in about #{retry_seconds} seconds."
      else
        " Please retry shortly."
      end

    message =
      "AI suggestion generation is rate-limited by Gemini quota." <>
        retry_hint <>
        " If this persists, check Gemini API quota/billing settings."

    %{title: "Rate limit reached", errors: [%{code: "RATE_LIMITED", message: message}]}
  end

  def format_suggestion_error({:config_error, message}) when is_binary(message) do
    %{
      title: "AI suggestions unavailable",
      errors: [%{code: nil, message: "AI suggestion generation is unavailable: #{message}"}]
    }
  end

  def format_suggestion_error(reason) do
    %{title: "Failed to generate suggestions", errors: [%{code: nil, message: inspect(reason)}]}
  end

  defp extract_retry_seconds(%{"error" => %{"details" => details}}) when is_list(details) do
    Enum.find_value(details, fn
      %{"@type" => "type.googleapis.com/google.rpc.RetryInfo", "retryDelay" => delay} ->
        parse_retry_delay_seconds(delay)

      _ ->
        nil
    end)
  end

  defp extract_retry_seconds(_), do: nil

  defp parse_retry_delay_seconds(delay) when is_binary(delay) do
    case Regex.run(~r/^(\d+(?:\.\d+)?)s$/, delay, capture: :all_but_first) do
      [seconds] ->
        case Float.parse(seconds) do
          {value, _} -> trunc(Float.ceil(value))
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_retry_delay_seconds(_), do: nil
end
