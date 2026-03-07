defmodule SocialScribeWeb.MeetingLive.Show do
  use SocialScribeWeb, :live_view

  import SocialScribeWeb.PlatformLogo
  import SocialScribeWeb.ClipboardButton
  import SocialScribeWeb.ModalComponents, only: [hubspot_modal: 1, salesforce_modal: 1]

  alias SocialScribe.Meetings
  alias SocialScribe.Automations
  alias SocialScribe.Accounts
  alias SocialScribe.HubspotApiBehaviour, as: HubspotApi
  alias SocialScribe.HubspotSuggestions
  alias SocialScribe.SalesforceApiBehaviour, as: SalesforceApi
  alias SocialScribe.SalesforceSuggestions

  @impl true
  def mount(%{"id" => meeting_id}, _session, socket) do
    meeting = Meetings.get_meeting_with_details(meeting_id)

    user_has_automations =
      Automations.list_active_user_automations(socket.assigns.current_user.id)
      |> length()
      |> Kernel.>(0)

    automation_results = Automations.list_automation_results_for_meeting(meeting_id)

    if meeting.calendar_event.user_id != socket.assigns.current_user.id do
      socket =
        socket
        |> put_flash(:error, "You do not have permission to view this meeting.")
        |> redirect(to: ~p"/dashboard/meetings")

      {:error, socket}
    else
      hubspot_credential = Accounts.get_user_hubspot_credential(socket.assigns.current_user.id)

      salesforce_credentials =
        Accounts.list_user_credentials(socket.assigns.current_user, provider: "salesforce")

      socket =
        socket
        |> assign(:page_title, "Meeting Details: #{meeting.title}")
        |> assign(:meeting, meeting)
        |> assign(:automation_results, automation_results)
        |> assign(:user_has_automations, user_has_automations)
        |> assign(:hubspot_credential, hubspot_credential)
        |> assign(:salesforce_credentials, salesforce_credentials)
        |> assign(
          :follow_up_email_form,
          to_form(%{
            "follow_up_email" => ""
          })
        )

      {:ok, socket}
    end
  end

  @impl true
  def handle_params(%{"automation_result_id" => automation_result_id}, _uri, socket) do
    automation_result = Automations.get_automation_result!(automation_result_id)
    automation = Automations.get_automation!(automation_result.automation_id)

    socket =
      socket
      |> assign(:automation_result, automation_result)
      |> assign(:automation, automation)

    {:noreply, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate-follow-up-email", params, socket) do
    socket =
      socket
      |> assign(:follow_up_email_form, to_form(params))

    {:noreply, socket}
  end

  @impl true
  def handle_info({:hubspot_search, query, credential}, socket) do
    case HubspotApi.search_contacts(credential, query) do
      {:ok, contacts} ->
        send_update(SocialScribeWeb.MeetingLive.HubspotModalComponent,
          id: "hubspot-modal",
          contacts: contacts,
          searching: false
        )

      {:error, reason} ->
        send_update(SocialScribeWeb.MeetingLive.HubspotModalComponent,
          id: "hubspot-modal",
          error: "Failed to search contacts: #{inspect(reason)}",
          searching: false
        )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:generate_suggestions, contact, meeting, _credential}, socket) do
    case HubspotSuggestions.generate_suggestions_from_meeting(meeting) do
      {:ok, suggestions} ->
        merged = HubspotSuggestions.merge_with_contact(suggestions, normalize_contact(contact))

        send_update(SocialScribeWeb.MeetingLive.HubspotModalComponent,
          id: "hubspot-modal",
          step: :suggestions,
          suggestions: merged,
          loading: false
        )

      {:error, reason} ->
        send_update(SocialScribeWeb.MeetingLive.HubspotModalComponent,
          id: "hubspot-modal",
          error: "Failed to generate suggestions: #{inspect(reason)}",
          loading: false
        )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:apply_hubspot_updates, updates, contact, credential}, socket) do
    case HubspotApi.update_contact(credential, contact.id, updates) do
      {:ok, _updated_contact} ->
        socket =
          socket
          |> put_flash(:info, "Successfully updated #{map_size(updates)} field(s) in HubSpot")
          |> push_patch(to: ~p"/dashboard/meetings/#{socket.assigns.meeting}")

        {:noreply, socket}

      {:error, reason} ->
        send_update(SocialScribeWeb.MeetingLive.HubspotModalComponent,
          id: "hubspot-modal",
          error: "Failed to update contact: #{inspect(reason)}",
          loading: false
        )

        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:salesforce_search, query, credential}, socket) do
    case SalesforceApi.search_contacts(credential, query) do
      {:ok, contacts} ->
        send_update(SocialScribeWeb.MeetingLive.SalesforceModalComponent,
          id: "salesforce-modal",
          contacts: contacts,
          searching: false
        )

      {:error, reason} ->
        send_update(SocialScribeWeb.MeetingLive.SalesforceModalComponent,
          id: "salesforce-modal",
          error: format_salesforce_search_error(reason),
          searching: false
        )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:generate_salesforce_suggestions, contact, meeting, credential}, socket) do
    case SalesforceSuggestions.generate_suggestions(credential, contact.id, meeting) do
      {:ok, %{suggestions: suggestions, mapping_fields: mapping_fields}} ->
        send_update(SocialScribeWeb.MeetingLive.SalesforceModalComponent,
          id: "salesforce-modal",
          step: :suggestions,
          suggestions: suggestions,
          mapping_fields: mapping_fields,
          form_error: nil,
          loading: false
        )

      {:error, reason} ->
        send_update(SocialScribeWeb.MeetingLive.SalesforceModalComponent,
          id: "salesforce-modal",
          error: format_suggestion_generation_error(reason),
          loading: false
        )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:apply_salesforce_updates, updates, contact, credential}, socket) do
    case SalesforceApi.update_contact(credential, contact.id, updates) do
      {:ok, _updated_contact} ->
        socket =
          socket
          |> put_flash(:info, "Successfully updated #{map_size(updates)} field(s) in Salesforce")
          |> push_patch(to: ~p"/dashboard/meetings/#{socket.assigns.meeting}")

        {:noreply, socket}

      {:error, reason} ->
        send_update(SocialScribeWeb.MeetingLive.SalesforceModalComponent,
          id: "salesforce-modal",
          error: format_salesforce_update_error(reason),
          loading: false
        )

        {:noreply, socket}
    end
  end

  defp normalize_contact(contact) do
    # Contact is already formatted with atom keys from HubspotApi.format_contact
    contact
  end

  defp format_suggestion_generation_error({:api_error, 429, body}) do
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

  defp format_suggestion_generation_error({:config_error, message}) when is_binary(message) do
    "AI suggestion generation is unavailable: #{message}"
  end

  defp format_suggestion_generation_error(reason) do
    "Failed to generate suggestions: #{inspect(reason)}"
  end

  defp format_salesforce_update_error({:invalid_updates, errors}) when is_list(errors) do
    details =
      errors
      |> Enum.map(fn error ->
        field = Map.get(error, :field, "unknown field")
        message = Map.get(error, :message, "invalid value")
        "#{field}: #{message}"
      end)
      |> Enum.join("; ")

    "Some values could not be validated for Salesforce: #{details}"
  end

  defp format_salesforce_update_error({:api_error, 400, body}) when is_list(body) do
    details =
      body
      |> Enum.map(fn entry ->
        code = Map.get(entry, "errorCode", "UNKNOWN")
        message = Map.get(entry, "message", "Unknown Salesforce error")
        "#{code}: #{message}"
      end)
      |> Enum.join("; ")

    "Salesforce rejected the update: #{details}"
  end

  defp format_salesforce_update_error(reason) do
    "Failed to update contact: #{inspect(reason)}"
  end

  defp format_salesforce_search_error({:reconnect_required, message}) when is_binary(message) do
    message
  end

  defp format_salesforce_search_error(reason) do
    "Failed to search contacts: #{inspect(reason)}"
  end

  defp extract_retry_seconds(%{"error" => %{"details" => details}}) when is_list(details) do
    details
    |> Enum.find_value(fn detail ->
      case detail do
        %{
          "@type" => "type.googleapis.com/google.rpc.RetryInfo",
          "retryDelay" => retry_delay
        } ->
          parse_retry_delay_seconds(retry_delay)

        _ ->
          nil
      end
    end)
  end

  defp extract_retry_seconds(_), do: nil

  defp parse_retry_delay_seconds(retry_delay) when is_binary(retry_delay) do
    case Regex.run(~r/^(\d+(?:\.\d+)?)s$/, retry_delay, capture: :all_but_first) do
      [seconds] ->
        seconds
        |> Float.parse()
        |> case do
          {value, _} -> trunc(Float.ceil(value))
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_retry_delay_seconds(_), do: nil

  defp format_duration(nil), do: "N/A"

  defp format_duration(seconds) when is_integer(seconds) do
    minutes = div(seconds, 60)
    remaining_seconds = rem(seconds, 60)

    cond do
      minutes > 0 && remaining_seconds > 0 -> "#{minutes} min #{remaining_seconds} sec"
      minutes > 0 -> "#{minutes} min"
      seconds > 0 -> "#{seconds} sec"
      true -> "Less than a second"
    end
  end

  attr :meeting_transcript, :map, required: true
  attr :meeting_participants, :list, default: []

  defp transcript_content(assigns) do
    has_transcript =
      assigns.meeting_transcript &&
        assigns.meeting_transcript.content &&
        Map.get(assigns.meeting_transcript.content, "data") &&
        Enum.any?(Map.get(assigns.meeting_transcript.content, "data"))

    assigns =
      assigns
      |> assign(:has_transcript, has_transcript)

    ~H"""
    <div class="bg-white shadow-xl rounded-lg p-6 md:p-8">
      <h2 class="text-2xl font-semibold mb-4 text-slate-700">
        Meeting Transcript
      </h2>
      <div class="prose prose-sm sm:prose max-w-none h-96 overflow-y-auto pr-2">
        <%= if @has_transcript do %>
          <div :for={segment <- @meeting_transcript.content["data"]} class="mb-3">
            <p>
              <span class="font-semibold text-indigo-600">
                {Meetings.resolve_transcript_speaker(segment, @meeting_participants)}:
              </span>
              {Enum.map_join(
                Meetings.transcript_segment_words(segment),
                " ",
                &Meetings.transcript_word_text/1
              )}
            </p>
          </div>
        <% else %>
          <p class="text-slate-500">
            Transcript not available for this meeting.
          </p>
        <% end %>
      </div>
    </div>
    """
  end
end
