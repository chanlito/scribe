defmodule SocialScribeWeb.MeetingLive.Show do
  use SocialScribeWeb, :live_view

  import SocialScribeWeb.PlatformLogo
  import SocialScribeWeb.ClipboardButton
  import SocialScribeWeb.ModalComponents, only: [hubspot_modal: 1, salesforce_modal: 1]

  alias SocialScribe.Meetings
  alias SocialScribe.Automations
  alias SocialScribe.CRM.Providers.Hubspot.Provider, as: HubspotProvider
  alias SocialScribe.CRM.Providers.Salesforce.Provider, as: SalesforceProvider
  alias SocialScribeWeb.MeetingLive.CrmModalComponent

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
      hubspot_credentials = HubspotProvider.list_credentials(socket.assigns.current_user)
      salesforce_credentials = SalesforceProvider.list_credentials(socket.assigns.current_user)
      hubspot_credential = List.first(hubspot_credentials)

      socket =
        socket
        |> assign(:page_title, "Meeting Details: #{meeting.title}")
        |> assign(:meeting, meeting)
        |> assign(:automation_results, automation_results)
        |> assign(:user_has_automations, user_has_automations)
        |> assign(:hubspot_credential, hubspot_credential)
        |> assign(:hubspot_credentials, hubspot_credentials)
        |> assign(:salesforce_credentials, salesforce_credentials)
        |> assign(:salesforce_modal_locked, false)
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
  def handle_info({:crm_list_contacts, provider, credential}, socket) do
    case provider.list_contacts(credential, "") do
      {:ok, contacts} ->
        send_update(CrmModalComponent,
          id: modal_component_id(provider),
          contacts_full: contacts,
          searching: false
        )

      {:error, reason} ->
        send_update(CrmModalComponent,
          id: modal_component_id(provider),
          error: provider.format_search_error(reason),
          searching: false
        )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:crm_search, provider, query, credential}, socket) do
    case provider.list_contacts(credential, query) do
      {:ok, contacts} ->
        send_update(CrmModalComponent,
          id: modal_component_id(provider),
          contacts_full: contacts,
          searching: false
        )

      {:error, reason} ->
        send_update(CrmModalComponent,
          id: modal_component_id(provider),
          error: provider.format_search_error(reason),
          searching: false
        )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:crm_generate_suggestions, provider, contact, meeting, credential}, socket) do
    case provider.generate_suggestions(credential, contact, meeting) do
      {:ok,
       %{selected_contact: full_contact, suggestions: suggestions, mapping_fields: mapping_fields}} ->
        send_update(CrmModalComponent,
          id: modal_component_id(provider),
          selected_contact: full_contact,
          suggestions: suggestions,
          mapping_fields: mapping_fields,
          form_error: nil,
          loading: false
        )

      {:error, reason} ->
        send_update(CrmModalComponent,
          id: modal_component_id(provider),
          error: provider.format_suggestion_error(reason),
          loading: false
        )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:crm_apply_updates, provider, updates, contact, credential}, socket) do
    case apply_updates(provider, credential, contact.id, updates) do
      {:ok, _updated_contact} ->
        socket =
          socket
          |> assign(:salesforce_modal_locked, false)
          |> put_flash(
            :info,
            "Successfully updated #{map_size(updates)} field(s) in #{provider.display_name()}"
          )
          |> push_patch(to: ~p"/dashboard/meetings/#{socket.assigns.meeting}")

        {:noreply, socket}

      {:error, reason} ->
        send_update(CrmModalComponent,
          id: modal_component_id(provider),
          error: provider.format_update_error(reason),
          loading: false,
          updating: false
        )

        {:noreply, assign(socket, :salesforce_modal_locked, false)}
    end
  end

  @impl true
  def handle_info({:crm_modal_lock, locked?}, socket) when is_boolean(locked?) do
    {:noreply, assign(socket, :salesforce_modal_locked, locked?)}
  end

  defp modal_component_id(provider) do
    "#{provider.provider_id()}-modal"
  end

  defp apply_updates(SalesforceProvider, credential, contact_id, updates) do
    salesforce_api_impl().update_contact(credential, contact_id, updates)
  end

  defp apply_updates(HubspotProvider, credential, contact_id, updates) do
    hubspot_api_impl().update_contact(credential, contact_id, updates)
  end

  defp hubspot_api_impl do
    Application.get_env(
      :social_scribe,
      :hubspot_api,
      SocialScribe.CRM.Providers.Hubspot.Api
    )
  end

  defp salesforce_api_impl do
    Application.get_env(
      :social_scribe,
      :salesforce_api,
      SocialScribe.CRM.Providers.Salesforce.Api
    )
  end

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
