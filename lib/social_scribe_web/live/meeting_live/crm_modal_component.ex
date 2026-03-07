defmodule SocialScribeWeb.MeetingLive.CrmModalComponent do
  use SocialScribeWeb, :live_component

  import SocialScribeWeb.ModalComponents

  @page_size 20

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :patch, ~p"/dashboard/meetings/#{assigns.meeting}")
    assigns = assign(assigns, :modal_id, assigns.modal_id || "crm-modal-wrapper")
    assigns = assign(assigns, :provider_name, assigns.provider.display_name())
    assigns = assign(assigns, :provider_button_class, assigns.provider.button_class())
    assigns = assign(assigns, :capabilities, assigns.provider.capabilities())

    assigns =
      assign(
        assigns,
        :requires_account_selection,
        Map.get(assigns.capabilities, :account_selection, false) &&
          length(assigns.credentials) > 1
      )

    assigns = assign(assigns, :credential_select_id, "#{assigns.modal_id}-credential-select")

    ~H"""
    <div class="space-y-6">
      <div>
        <h2 id={"#{@modal_id}-title"} class="text-xl font-medium tracking-tight text-slate-900">
          Update in {@provider_name}
        </h2>
        <p id={"#{@modal_id}-description"} class="mt-2 text-base font-light leading-7 text-slate-500">
          Here are suggested updates to sync with your integrations based on this
          <span class="block">meeting</span>
        </p>
      </div>

      <div :if={@requires_account_selection} class="space-y-1">
        <label for={@credential_select_id} class="block text-sm font-medium text-slate-700">
          {@provider.account_select_label()}
        </label>
        <select
          id={@credential_select_id}
          class="w-full bg-white border border-hubspot-input rounded-lg py-2 px-3 text-sm focus:border-indigo-500 focus:ring-2 focus:ring-indigo-500"
          phx-change="select_account"
          phx-target={@myself}
          name="credential_id"
        >
          <option value="">Choose an account...</option>
          <option
            :for={credential <- @credentials}
            value={credential.id}
            selected={
              @selected_credential && to_string(@selected_credential.id) == to_string(credential.id)
            }
          >
            {credential.email || credential.uid}
          </option>
        </select>
      </div>

      <.contact_select
        selected_contact={@selected_contact}
        contacts={@contacts}
        loading={@searching}
        open={@dropdown_open}
        query={@query}
        target={@myself}
        error={@error}
        has_more={not is_nil(@next_cursor)}
      />

      <%= if @selected_contact do %>
        <.suggestions_section
          suggestions={@suggestions}
          loading={@loading}
          updating={@updating}
          myself={@myself}
          patch={@patch}
          mapping_fields={@mapping_fields}
          form_error={@form_error}
          notice={@notice}
          provider_name={@provider_name}
          provider_button_class={@provider_button_class}
          capabilities={@capabilities}
        />
      <% end %>
    </div>
    """
  end

  attr :suggestions, :list, required: true
  attr :loading, :boolean, required: true
  attr :updating, :boolean, required: true
  attr :myself, :any, required: true
  attr :patch, :string, required: true
  attr :mapping_fields, :list, required: true
  attr :form_error, :string, default: nil
  attr :notice, :atom, default: nil
  attr :provider_name, :string, required: true
  attr :provider_button_class, :string, required: true
  attr :capabilities, :map, required: true

  defp suggestions_section(assigns) do
    selected_count = Enum.count(assigns.suggestions, &(&1.apply == true))
    field_label = if selected_count == 1, do: "field", else: "fields"

    ai_suggestions = Enum.reject(assigns.suggestions, &existing_row?/1)
    existing_rows = Enum.filter(assigns.suggestions, &existing_row?/1)

    assigns =
      assigns
      |> assign(:selected_count, selected_count)
      |> assign(
        :selected_updates_summary,
        "1 contact, #{selected_count} #{field_label} selected for update"
      )
      |> assign(:show_generation_loading, assigns.loading && Enum.empty?(assigns.suggestions))
      |> assign(:ai_suggestions, ai_suggestions)
      |> assign(:existing_rows, existing_rows)
      |> assign(:existing_section_id, "existing-rows-#{assigns.myself.cid}")

    ~H"""
    <div class="space-y-4">
      <%= if @show_generation_loading do %>
        <div
          class="text-center py-8 text-slate-500"
          role="status"
          aria-live="polite"
          aria-atomic="true"
        >
          <.icon name="hero-arrow-path" class="h-6 w-6 animate-spin mx-auto mb-2" />
          <p>Generating suggestions...</p>
        </div>
      <% else %>
        <form phx-submit="apply_updates" phx-change="toggle_suggestion" phx-target={@myself}>
          <.inline_error :if={@form_error} message={@form_error} class="mb-2" />

          <.suggestion_notice :if={@notice} notice={@notice} provider_name={@provider_name} />

          <div class="space-y-4 max-h-[60vh] overflow-y-auto pr-2">
            <.crm_suggestion_card
              :for={suggestion <- @ai_suggestions}
              suggestion={suggestion}
              mapping_fields={@mapping_fields}
              myself={@myself}
              capabilities={@capabilities}
              provider_name={@provider_name}
            />
          </div>

          <div :if={@existing_rows != []}>
            <div class="flex justify-center my-2">
              <button
                type="button"
                phx-click={
                  JS.toggle(to: "##{@existing_section_id}")
                  |> JS.toggle(to: "##{@existing_section_id}-show-label")
                  |> JS.toggle(to: "##{@existing_section_id}-hide-label")
                }
                class="inline-flex items-center gap-1 px-2 py-1 text-xs font-medium text-slate-400 hover:text-slate-600 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-1 rounded"
              >
                <span id={"#{@existing_section_id}-show-label"}>Show existing fields</span>
                <span id={"#{@existing_section_id}-hide-label"} class="hidden">
                  Hide existing fields
                </span>
                <.icon name="hero-chevron-down" class="h-3.5 w-3.5" />
              </button>
            </div>

            <div id={@existing_section_id} class="hidden mt-2 space-y-4 max-h-[40vh] overflow-y-auto pr-2">
              <.crm_suggestion_card
                :for={suggestion <- @existing_rows}
                suggestion={suggestion}
                mapping_fields={@mapping_fields}
                myself={@myself}
                capabilities={@capabilities}
                provider_name={@provider_name}
              />
            </div>
          </div>

          <.modal_footer
            cancel_patch={if @updating, do: nil, else: @patch}
            submit_text={"Update #{@provider_name}"}
            submit_class={@provider_button_class}
            disabled={@selected_count == 0}
            loading={@updating}
            loading_text="Updating..."
            info_text={@selected_updates_summary}
          />
        </form>
      <% end %>
    </div>
    """
  end

  defp existing_row?(%{id: id}) when is_binary(id), do: String.contains?(id, "-existing-")
  defp existing_row?(_), do: false

  attr :notice, :atom, required: true
  attr :provider_name, :string, required: true

  defp suggestion_notice(%{notice: :no_ai_suggestions} = assigns) do
    ~H"""
    <div class="rounded-xl bg-slate-50 border border-slate-200 px-4 py-3 mb-2">
      <p class="text-sm font-medium text-slate-700">Nothing to suggest</p>
      <p class="text-sm text-slate-500 mt-0.5">
        The AI reviewed the transcript but couldn't find any new contact information. You can still manually update any field below.
      </p>
    </div>
    """
  end

  defp suggestion_notice(%{notice: :all_up_to_date} = assigns) do
    ~H"""
    <div class="rounded-xl bg-slate-50 border border-slate-200 px-4 py-3 mb-2">
      <p class="text-sm font-medium text-slate-700">All fields are up to date</p>
      <p class="text-sm text-slate-500 mt-0.5">
        The AI found some information, but it already matches what's in {@provider_name}. You can still manually update any field below.
      </p>
    </div>
    """
  end

  defp suggestion_notice(assigns), do: ~H""

  attr :suggestion, :map, required: true
  attr :mapping_fields, :list, required: true
  attr :myself, :any, required: true
  attr :capabilities, :map, required: true
  attr :provider_name, :string, required: true

  defp crm_suggestion_card(assigns) do
    mapping_toggle? = Map.get(assigns.capabilities, :mapping_toggle, false)
    details_toggle? = Map.get(assigns.capabilities, :details_toggle, false)

    field_meta =
      Enum.find(assigns.mapping_fields, fn f ->
        f.name == assigns.suggestion.mapped_field
      end)

    field_type = if field_meta, do: Map.get(field_meta, :type), else: nil
    field_options = if field_meta, do: Map.get(field_meta, :options, []), else: []
    field_type_label = field_type_label(field_type)

    assigns =
      assigns
      |> assign(:mapping_toggle, mapping_toggle?)
      |> assign(:details_toggle, details_toggle?)
      |> assign(:field_type_label, field_type_label)
      |> assign(:field_options, field_options)
      |> assign(:details_id, "suggestion-details-#{assigns.suggestion.id}")
      |> assign(:current_value_id, "suggestion-current-value-#{assigns.suggestion.id}")
      |> assign(:new_value_id, "suggestion-new-value-#{assigns.suggestion.id}")
      |> assign(:mapped_field_id, "suggestion-mapped-field-#{assigns.suggestion.id}")
      |> assign(:current_value_label, "Current value for #{assigns.suggestion.mapped_label}")
      |> assign(:new_value_label, "New value for #{assigns.suggestion.mapped_label}")
      |> assign(
        :mapped_field_label,
        "Mapped #{assigns.provider_name} field for #{assigns.suggestion.mapped_label}"
      )

    ~H"""
    <div class="bg-hubspot-card rounded-2xl p-6 mb-4">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <label
            for={"suggestion-apply-#{@suggestion.id}"}
            class="inline-flex min-h-11 min-w-11 items-center justify-center cursor-pointer rounded-md"
          >
            <input
              id={"suggestion-apply-#{@suggestion.id}"}
              type="checkbox"
              name={"apply[#{@suggestion.id}]"}
              value="1"
              checked={@suggestion.apply}
              class="h-5 w-5 rounded-[3px] border-slate-300 text-hubspot-checkbox accent-hubspot-checkbox focus:ring-2 focus:ring-indigo-500 focus:ring-offset-1 cursor-pointer"
            />
          </label>
          <div>
            <div class="text-sm font-semibold text-slate-900 leading-5">
              {@suggestion.mapped_label}
            </div>
            <div :if={@field_type_label} class="text-xs text-slate-400 mt-0.5">
              {@field_type_label}
            </div>
          </div>
        </div>

        <div class="flex items-center gap-3">
          <button
            :if={@details_toggle}
            type="button"
            phx-click="toggle_suggestion_details"
            phx-value-id={@suggestion.id}
            phx-target={@myself}
            aria-label={if @suggestion.details_open, do: "Hide details", else: "Show details"}
            aria-expanded={to_string(@suggestion.details_open)}
            aria-controls={@details_id}
            class="inline-flex min-h-11 min-w-11 items-center justify-center rounded-md text-hubspot-hide hover:text-hubspot-hide-hover focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-1"
          >
            <.icon
              name={if @suggestion.details_open, do: "hero-chevron-up", else: "hero-chevron-down"}
              class="h-5 w-5"
            />
          </button>
        </div>
      </div>

      <input
        :if={!@suggestion.mapping_open}
        type="hidden"
        name={"mapped_fields[#{@suggestion.id}]"}
        value={@suggestion.mapped_field}
      />

      <div :if={@suggestion.details_open} id={@details_id} class="mt-3">
        <div class="mt-1">
          <div class="grid grid-cols-1 items-center gap-3 sm:grid-cols-[minmax(0,1fr)_32px_minmax(0,1fr)] sm:gap-6">
            <input
              id={@current_value_id}
              type="text"
              readonly
              value={@suggestion.current_value || ""}
              placeholder="No existing value"
              aria-label={@current_value_label}
              class={[
                "block w-full shadow-sm text-sm bg-white border border-hubspot-input rounded-[7px] py-2 px-3",
                if(@suggestion.current_value && @suggestion.current_value != "",
                  do: "line-through text-slate-500",
                  else: "text-slate-500"
                )
              ]}
            />

            <div class="hidden w-8 justify-center text-hubspot-arrow sm:flex">
              <.icon name="hero-arrow-long-right" class="h-7 w-7" />
            </div>

            <%= if Enum.any?(@field_options) do %>
              <select
                id={@new_value_id}
                name={"values[#{@suggestion.id}]"}
                aria-label={@new_value_label}
                class="block w-full shadow-sm text-sm text-slate-900 bg-white border border-hubspot-input rounded-[7px] py-2 px-3 focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
              >
                <option value="">— select —</option>
                <option
                  :for={opt <- @field_options}
                  value={opt.value}
                  selected={opt.value == @suggestion.new_value}
                >
                  {opt.label}
                </option>
              </select>
            <% else %>
              <input
                id={@new_value_id}
                type="text"
                name={"values[#{@suggestion.id}]"}
                value={@suggestion.new_value}
                phx-debounce="300"
                aria-label={@new_value_label}
                class="block w-full shadow-sm text-sm text-slate-900 bg-white border border-hubspot-input rounded-[7px] py-2 px-3 focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
              />
            <% end %>
          </div>
        </div>

        <p :if={!@suggestion.has_change} class="text-xs text-amber-700 mt-2">
          No change detected for this mapped field.
        </p>

        <p :if={@suggestion[:pair_warning]} class="text-xs text-destructive mt-2">
          {@suggestion[:pair_warning]}
        </p>

        <div class="mt-3 grid grid-cols-1 items-start gap-3 sm:grid-cols-[minmax(0,1fr)_32px_minmax(0,1fr)] sm:gap-6">
          <div class="justify-self-start min-w-0">
            <button
              :if={@mapping_toggle}
              type="button"
              phx-click="toggle_suggestion_mapping"
              phx-value-id={@suggestion.id}
              phx-target={@myself}
              class="inline-flex min-h-11 items-center rounded-md px-2 py-2 text-sm text-hubspot-link hover:text-hubspot-link-hover font-medium focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-1"
            >
              Update mapping
            </button>

            <div :if={@mapping_toggle && @suggestion.mapping_open} class="mt-2">
              <select
                id={@mapped_field_id}
                name={"mapped_fields[#{@suggestion.id}]"}
                aria-label={@mapped_field_label}
                class="w-full min-w-0 sm:min-w-56 bg-white border border-hubspot-input rounded-lg py-2 px-3 text-sm focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
              >
                <option
                  :for={field <- @mapping_fields}
                  value={field.name}
                  selected={field.name == @suggestion.mapped_field}
                >
                  {mapping_field_option_label(field)}
                </option>
              </select>
            </div>
          </div>

          <span class="hidden sm:block"></span>

          <span
            :if={@suggestion[:timestamp]}
            class="text-xs text-slate-500 justify-self-end text-right"
          >
            Found in transcript<span
              class="text-hubspot-link hover:underline cursor-help"
              title={@suggestion[:context]}
            >
              ({@suggestion[:timestamp]})
            </span>
          </span>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    provider = Map.get(assigns, :provider, socket.assigns[:provider])

    credentials = Map.get(assigns, :credentials, socket.assigns[:credentials] || [])

    selected_credential =
      Map.get(
        assigns,
        :selected_credential,
        socket.assigns[:selected_credential] || provider.default_credential(credentials)
      )

    socket =
      socket
      |> assign_new(:form_error, fn -> nil end)
      |> assign(assigns)
      |> assign(:provider, provider)
      |> assign(:credentials, credentials)
      |> assign(:selected_credential, selected_credential)
      |> assign_new(:mapping_fields, fn -> provider.default_mapping_fields() end)
      |> maybe_paginate_contacts(assigns)
      |> maybe_prepare_suggestions(assigns)
      |> assign_new(:query, fn -> "" end)
      |> assign_new(:contacts, fn -> [] end)
      |> assign_new(:contacts_full, fn -> [] end)
      |> assign_new(:next_cursor, fn -> nil end)
      |> assign_new(:selected_contact, fn -> nil end)
      |> assign_new(:suggestions, fn -> [] end)
      |> assign_new(:notice, fn -> nil end)
      |> assign_new(:loading, fn -> false end)
      |> assign_new(:updating, fn -> false end)
      |> assign_new(:searching, fn -> false end)
      |> assign_new(:dropdown_open, fn -> false end)
      |> assign_new(:error, fn -> nil end)

    {:ok, socket}
  end

  defp maybe_prepare_suggestions(socket, %{suggestions: suggestions}) when is_list(suggestions) do
    {prepared, form_error} =
      socket.assigns.provider.prepare_suggestions(
        suggestions,
        socket.assigns.selected_contact,
        socket.assigns.mapping_fields
      )

    socket
    |> assign(:suggestions, prepared)
    |> assign(:form_error, form_error)
  end

  defp maybe_prepare_suggestions(socket, _assigns), do: socket

  defp maybe_paginate_contacts(socket, %{contacts_full: contacts}) when is_list(contacts) do
    {page, next_cursor} = paginate(contacts, nil)
    assign(socket, contacts: page, next_cursor: next_cursor)
  end

  defp maybe_paginate_contacts(socket, _assigns), do: socket

  @impl true
  def handle_event("select_account", %{"credential_id" => credential_id}, socket) do
    credential = Enum.find(socket.assigns.credentials, &(to_string(&1.id) == credential_id))

    {:noreply,
     socket
     |> assign(:selected_credential, credential)
     |> assign(:selected_contact, nil)
     |> assign(:contacts, [])
     |> assign(:contacts_full, [])
     |> assign(:next_cursor, nil)
     |> assign(:query, "")
     |> assign(:suggestions, [])
     |> assign(:notice, nil)
     |> assign(:mapping_fields, socket.assigns.provider.default_mapping_fields())
     |> assign(:dropdown_open, false)
     |> assign(:loading, false)
     |> assign(:updating, false)
     |> assign(:searching, false)
     |> assign(:error, nil)
     |> assign(:form_error, nil)}
  end

  @impl true
  def handle_event("contact_search", %{"value" => query}, socket) do
    query = String.trim(query)

    case ensure_credential(socket) do
      {:error, message, socket} ->
        {:noreply, assign(socket, error: message, searching: false, dropdown_open: false)}

      {:ok, credential, socket} ->
        socket = assign(socket, searching: true, error: nil, query: query, dropdown_open: true)
        send(self(), {:crm_search, socket.assigns.provider, query, credential})
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_contact_dropdown", _params, socket) do
    case ensure_credential(socket) do
      {:error, message, socket} ->
        {:noreply, assign(socket, dropdown_open: false, error: message, searching: false)}

      {:ok, credential, socket} ->
        socket = assign(socket, dropdown_open: true, searching: true, error: nil, query: "")
        send(self(), {:crm_list_contacts, socket.assigns.provider, credential})
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("load_more_contacts", _params, socket) do
    case socket.assigns.next_cursor do
      nil ->
        {:noreply, socket}

      cursor ->
        {page, next_cursor} = paginate(socket.assigns.contacts_full, cursor)

        {:noreply,
         assign(socket, contacts: socket.assigns.contacts ++ page, next_cursor: next_cursor)}
    end
  end

  @impl true
  def handle_event("close_contact_dropdown", _params, socket) do
    {:noreply, assign(socket, dropdown_open: false)}
  end

  @impl true
  def handle_event("toggle_contact_dropdown", _params, socket) do
    if socket.assigns.dropdown_open do
      {:noreply, assign(socket, dropdown_open: false)}
    else
      case ensure_credential(socket) do
        {:error, message, socket} ->
          {:noreply, assign(socket, dropdown_open: false, error: message, searching: false)}

        {:ok, credential, socket} ->
          socket = assign(socket, dropdown_open: true, searching: true, error: nil)

          query =
            "#{socket.assigns.selected_contact.firstname} #{socket.assigns.selected_contact.lastname}"

          send(self(), {:crm_search, socket.assigns.provider, query, credential})
          {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("select_contact", %{"id" => contact_id}, socket) do
    contact = Enum.find(socket.assigns.contacts, &(&1.id == contact_id))

    if contact do
      socket =
        assign(socket,
          loading: true,
          updating: false,
          selected_contact: contact,
          error: nil,
          form_error: nil,
          dropdown_open: false,
          query: "",
          suggestions: []
        )

      send(
        self(),
        {:crm_generate_suggestions, socket.assigns.provider, contact, socket.assigns.meeting,
         socket.assigns.selected_credential}
      )

      {:noreply, socket}
    else
      {:noreply, assign(socket, error: "Contact not found")}
    end
  end

  @impl true
  def handle_event("clear_contact", _params, socket) do
    {:noreply,
     assign(socket,
       selected_contact: nil,
       suggestions: [],
       notice: nil,
       mapping_fields: socket.assigns.provider.default_mapping_fields(),
       form_error: nil,
       loading: false,
       updating: false,
       searching: false,
       dropdown_open: false,
       contacts: [],
       contacts_full: [],
       next_cursor: nil,
       query: "",
       error: nil
     )}
  end

  @impl true
  def handle_event("toggle_suggestion_details", %{"id" => suggestion_id}, socket) do
    suggestions =
      Enum.map(socket.assigns.suggestions, fn suggestion ->
        if suggestion.id == suggestion_id do
          Map.update!(suggestion, :details_open, fn open? -> !open? end)
        else
          suggestion
        end
      end)

    {:noreply, assign(socket, suggestions: suggestions)}
  end

  @impl true
  def handle_event("toggle_suggestion_mapping", %{"id" => suggestion_id}, socket) do
    suggestions =
      Enum.map(socket.assigns.suggestions, fn suggestion ->
        if suggestion.id == suggestion_id do
          Map.update!(suggestion, :mapping_open, fn open? -> !open? end)
        else
          suggestion
        end
      end)

    {:noreply, assign(socket, suggestions: suggestions)}
  end

  @impl true
  def handle_event("toggle_suggestion", params, socket) do
    {suggestions, form_error} =
      socket.assigns.provider.apply_form_state(
        socket.assigns.suggestions,
        params,
        socket.assigns.selected_contact,
        socket.assigns.mapping_fields
      )

    {:noreply, assign(socket, suggestions: suggestions, form_error: form_error)}
  end

  @impl true
  def handle_event("apply_updates", params, socket) do
    {suggestions, form_error} =
      socket.assigns.provider.apply_form_state(
        socket.assigns.suggestions,
        params,
        socket.assigns.selected_contact,
        socket.assigns.mapping_fields
      )

    cond do
      form_error ->
        {:noreply, assign(socket, suggestions: suggestions, form_error: form_error)}

      true ->
        case socket.assigns.provider.build_updates(suggestions) do
          {:error, message} ->
            {:noreply, assign(socket, suggestions: suggestions, form_error: message)}

          {:ok, updates} ->
            if Map.get(socket.assigns.provider.capabilities(), :lock_on_submit, false) do
              send(self(), {:crm_modal_lock, true})
            end

            socket =
              assign(socket,
                suggestions: suggestions,
                updating: true,
                error: nil,
                form_error: nil
              )

            send(
              self(),
              {:crm_apply_updates, socket.assigns.provider, updates,
               socket.assigns.selected_contact, socket.assigns.selected_credential}
            )

            {:noreply, socket}
        end
    end
  end

  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp ensure_credential(socket) do
    provider = socket.assigns.provider
    credentials = socket.assigns.credentials

    cond do
      is_nil(socket.assigns.selected_credential) and length(credentials) > 1 and
          Map.get(provider.capabilities(), :account_selection, false) ->
        {:error, "Please select an account first", socket}

      is_nil(socket.assigns.selected_credential) ->
        {:error, "Please connect #{provider.display_name()} again to continue", socket}

      true ->
        {:ok, socket.assigns.selected_credential, socket}
    end
  end

  defp paginate(contacts, nil), do: paginate(contacts, "0")

  defp paginate(contacts, cursor) when is_binary(cursor) do
    offset =
      case Integer.parse(cursor) do
        {value, _} -> value
        :error -> 0
      end

    page = Enum.slice(contacts, offset, @page_size)
    next_offset = offset + length(page)

    next_cursor = if next_offset < length(contacts), do: Integer.to_string(next_offset), else: nil
    {page, next_cursor}
  end

  # Maps a CRM field type to a user-friendly display label.
  # Returns nil for plain text types to avoid noisy subtitles on simple fields.
  defp field_type_label(type) when is_binary(type) do
    case type do
      t when t in ["text", "string", "textarea", "phone_number"] -> nil
      "select" -> "Picklist"
      "radio" -> "Picklist"
      "picklist" -> "Picklist"
      "date" -> "Date"
      "datetime" -> "Date & Time"
      "number" -> "Number"
      "currency" -> "Currency"
      "percent" -> "Percentage"
      "boolean" -> "Yes / No"
      "checkbox" -> "Yes / No"
      "phone" -> "Phone"
      "url" -> "URL"
      "email" -> "Email"
      other -> String.capitalize(other)
    end
  end

  defp field_type_label(_), do: nil

  defp mapping_field_option_label(%{label: label}), do: label
  defp mapping_field_option_label(_), do: ""
end
