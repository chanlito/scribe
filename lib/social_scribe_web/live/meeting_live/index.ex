defmodule SocialScribeWeb.MeetingLive.Index do
  use SocialScribeWeb, :live_view

  import SocialScribeWeb.PlatformLogo

  alias SocialScribe.Meetings
  alias SocialScribeWeb.DateTimeFormat

  @impl true
  def mount(_params, _session, socket) do
    meetings = Meetings.list_user_meetings(socket.assigns.current_user)

    socket =
      socket
      |> assign(:page_title, "Past Meetings")
      |> assign(:timezone, DateTimeFormat.timezone_from_socket(socket))
      |> assign(:meetings, meetings)

    {:ok, socket}
  end

  defp format_duration(nil), do: "N/A"

  defp format_duration(seconds) when is_integer(seconds) do
    minutes = div(seconds, 60)
    "#{minutes} min"
  end

  defp format_recorded_at(datetime, timezone) do
    DateTimeFormat.format_in_timezone(datetime, timezone)
  end
end
