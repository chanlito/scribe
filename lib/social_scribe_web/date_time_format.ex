defmodule SocialScribeWeb.DateTimeFormat do
  @moduledoc false

  import Phoenix.LiveView, only: [get_connect_params: 1]

  @default_timezone "Etc/UTC"
  @default_format "%b %-d, %Y, %-I:%M %p"

  def timezone_from_socket(socket) do
    socket
    |> get_connect_params()
    |> case do
      params when is_map(params) -> Map.get(params, "timezone")
      _ -> nil
    end
    |> normalize_timezone()
  end

  def format_in_timezone(datetime, timezone, format \\ @default_format)

  def format_in_timezone(nil, timezone, format) do
    format_in_timezone(DateTime.utc_now(), timezone, format)
  end

  def format_in_timezone(%DateTime{} = datetime, timezone, format) when is_binary(format) do
    timezone
    |> normalize_timezone()
    |> then(&Timex.Timezone.convert(datetime, &1))
    |> Calendar.strftime(format)
  end

  defp normalize_timezone(timezone) when is_binary(timezone) do
    trimmed_timezone = String.trim(timezone)

    if Timex.Timezone.exists?(trimmed_timezone) do
      trimmed_timezone
    else
      @default_timezone
    end
  end

  defp normalize_timezone(_), do: @default_timezone
end
