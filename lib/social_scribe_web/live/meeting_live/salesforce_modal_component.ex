defmodule SocialScribeWeb.MeetingLive.SalesforceModalComponent do
  use SocialScribeWeb, :live_component

  import SocialScribeWeb.ModalComponents

  alias SocialScribe.SalesforceSuggestions

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :patch, ~p"/dashboard/meetings/#{assigns.meeting}")
    assigns = assign_new(assigns, :modal_id, fn -> "salesforce-modal-wrapper" end)
    assigns = assign(assigns, :requires_account_selection, length(assigns.credentials) > 1)
    assigns = assign(assigns, :credential_select_id, "#{assigns.modal_id}-credential-select")

    ~H"""
    <div class="space-y-6">
      <div>
        <h2 id={"#{@modal_id}-title"} class="text-xl font-medium tracking-tight text-slate-900">
          Update in Salesforce
        </h2>
        <p id={"#{@modal_id}-description"} class="mt-2 text-base font-light leading-7 text-slate-500">
          Here are suggested updates to sync with your integrations based on this
          <span class="block">meeting</span>
        </p>
      </div>

      <div :if={@requires_account_selection} class="space-y-1">
        <label for={@credential_select_id} class="block text-sm font-medium text-slate-700">
          Select Salesforce Account
        </label>
        <select
          id={@credential_select_id}
          class="w-full bg-white border border-hubspot-input rounded-lg py-2 px-3 text-sm focus:border-indigo-500 focus:ring-2 focus:ring-indigo-500"
          phx-change="select_salesforce_account"
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
      />

      <%= if @selected_contact do %>
        <.suggestions_section
          suggestions={@suggestions}
          loading={@loading}
          updating={@updating}
          myself={@myself}
          patch={@patch}
          mapping_fields={@mapping_fields}
          selected_contact={@selected_contact}
          form_error={@form_error}
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
  attr :selected_contact, :map, default: nil
  attr :form_error, :string, default: nil

  defp suggestions_section(assigns) do
    assigns =
      assign(assigns, :selected_count, Enum.count(assigns.suggestions, &(&1.apply == true)))
      |> assign(:selected_updates_summary, selected_updates_summary(assigns.suggestions))
      |> assign(:show_generation_loading, assigns.loading && Enum.empty?(assigns.suggestions))

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
        <%= if Enum.empty?(@suggestions) do %>
          <.empty_state
            message="No update suggestions found from this meeting."
            submessage="The AI didn't detect any new contact information in the transcript."
          />
        <% else %>
          <form phx-submit="apply_updates" phx-change="toggle_suggestion" phx-target={@myself}>
            <.inline_error :if={@form_error} message={@form_error} class="mb-2" />

            <div class="space-y-4 max-h-[60vh] overflow-y-auto pr-2">
              <.salesforce_suggestion_card
                :for={suggestion <- @suggestions}
                suggestion={suggestion}
                mapping_fields={@mapping_fields}
                myself={@myself}
              />
            </div>

            <.modal_footer
              cancel_patch={if @updating, do: nil, else: @patch}
              submit_text="Update Salesforce"
              submit_class="bg-hubspot-button hover:bg-hubspot-button-hover"
              disabled={@selected_count == 0}
              loading={@updating}
              loading_text="Updating..."
              info_text={@selected_updates_summary}
            />
          </form>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :suggestion, :map, required: true
  attr :mapping_fields, :list, required: true
  attr :myself, :any, required: true

  defp salesforce_suggestion_card(assigns) do
    assigns =
      assigns
      |> assign(:details_id, "suggestion-details-#{assigns.suggestion.id}")
      |> assign(:current_value_id, "suggestion-current-value-#{assigns.suggestion.id}")
      |> assign(:new_value_id, "suggestion-new-value-#{assigns.suggestion.id}")
      |> assign(:mapped_field_id, "suggestion-mapped-field-#{assigns.suggestion.id}")
      |> assign(:current_value_label, "Current value for #{assigns.suggestion.mapped_label}")
      |> assign(:new_value_label, "New value for #{assigns.suggestion.mapped_label}")
      |> assign(
        :mapped_field_label,
        "Mapped Salesforce field for #{assigns.suggestion.mapped_label}"
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
          <div class="text-sm font-semibold text-slate-900 leading-5">{@suggestion.mapped_label}</div>
        </div>

        <div class="flex items-center gap-3">
          <button
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

            <input
              id={@new_value_id}
              type="text"
              name={"values[#{@suggestion.id}]"}
              value={@suggestion.new_value}
              phx-debounce="300"
              aria-label={@new_value_label}
              class="block w-full shadow-sm text-sm text-slate-900 bg-white border border-hubspot-input rounded-[7px] py-2 px-3 focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
            />
          </div>
        </div>

        <p :if={!@suggestion.has_change} class="text-xs text-amber-700 mt-2">
          No change detected for this mapped field.
        </p>

        <p :if={@suggestion.mapped_field == "mailingcountry"} class="text-xs text-destructive mt-2">
          * Mailing State/Province and Mailing Country/Territory depend on each other. Update both together.
        </p>

        <div class="mt-3 grid grid-cols-1 items-start gap-3 sm:grid-cols-[minmax(0,1fr)_32px_minmax(0,1fr)] sm:gap-6">
          <div class="justify-self-start min-w-0">
            <button
              type="button"
              phx-click="toggle_suggestion_mapping"
              phx-value-id={@suggestion.id}
              phx-target={@myself}
              class="inline-flex min-h-11 items-center rounded-md px-2 py-2 text-sm text-hubspot-link hover:text-hubspot-link-hover font-medium focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-1"
            >
              Update mapping
            </button>

            <div :if={@suggestion.mapping_open} class="mt-2">
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
                  {field.label}
                </option>
              </select>
            </div>
          </div>

          <span class="hidden sm:block"></span>

          <span
            :if={@suggestion[:timestamp]}
            class="text-xs text-slate-500 justify-self-start sm:text-right"
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
    credentials = Map.get(assigns, :credentials, socket.assigns[:credentials] || [])

    selected_credential =
      Map.get(
        assigns,
        :selected_credential,
        socket.assigns[:selected_credential] || default_credential(credentials)
      )

    socket =
      socket
      |> assign_new(:mapping_fields, fn -> SalesforceSuggestions.default_mapping_fields() end)
      |> assign_new(:form_error, fn -> nil end)
      |> assign(assigns)
      |> maybe_prepare_suggestions(assigns)
      |> assign_new(:step, fn -> :search end)
      |> assign_new(:query, fn -> "" end)
      |> assign_new(:contacts, fn -> [] end)
      |> assign_new(:selected_contact, fn -> nil end)
      |> assign_new(:suggestions, fn -> [] end)
      |> assign_new(:loading, fn -> false end)
      |> assign_new(:updating, fn -> false end)
      |> assign_new(:searching, fn -> false end)
      |> assign_new(:dropdown_open, fn -> false end)
      |> assign_new(:error, fn -> nil end)
      |> assign_new(:credentials, fn -> credentials end)
      |> assign_new(:selected_credential, fn -> selected_credential end)

    {:ok, socket}
  end

  defp default_credential([credential]), do: credential
  defp default_credential(_), do: nil

  defp maybe_prepare_suggestions(socket, %{suggestions: suggestions}) when is_list(suggestions) do
    prepared =
      suggestions
      |> Enum.with_index(1)
      |> Enum.map(fn {suggestion, idx} ->
        prepare_suggestion(
          suggestion,
          idx,
          socket.assigns.selected_contact,
          socket.assigns.mapping_fields
        )
      end)
      |> Enum.reject(&invalid_suggestion_row?/1)
      |> ensure_existing_contact_rows(
        socket.assigns.selected_contact,
        socket.assigns.mapping_fields
      )
      |> ensure_mailing_pair_rows(socket.assigns.selected_contact, socket.assigns.mapping_fields)

    {prepared, form_error} = apply_duplicate_validation(prepared)

    socket
    |> assign(:suggestions, prepared)
    |> assign(:form_error, form_error)
  end

  defp maybe_prepare_suggestions(socket, _assigns), do: socket

  defp ensure_existing_contact_rows(suggestions, nil, _mapping_fields), do: suggestions

  defp ensure_existing_contact_rows(suggestions, selected_contact, mapping_fields) do
    existing_fields =
      suggestions
      |> Enum.map(& &1.mapped_field)
      |> MapSet.new()

    additional_rows =
      mapping_fields
      |> Enum.reduce([], fn mapping_field, acc ->
        mapped_field =
          mapping_field
          |> Map.get(:name, Map.get(mapping_field, "name"))
          |> SalesforceSuggestions.normalize_field_key()

        mapped_label =
          Map.get(mapping_field, :label, Map.get(mapping_field, "label", mapped_field))

        cond do
          not is_binary(mapped_field) ->
            acc

          MapSet.member?(existing_fields, mapped_field) ->
            acc

          true ->
            current_value =
              selected_contact
              |> SalesforceSuggestions.contact_field_value(mapped_field)
              |> then(&SalesforceSuggestions.normalize_field_value(mapped_field, &1))
              |> then(&sanitize_suggestion_value(mapped_field, mapped_label, &1, :current))

            if include_existing_row?(mapped_field, mapped_label) and
                 present_existing_value?(current_value) do
              [
                %{
                  id: "sf-existing-#{mapped_field}",
                  field: mapped_field,
                  mapped_field: mapped_field,
                  label: mapped_label,
                  mapped_label: mapped_label,
                  current_value: current_value,
                  new_value: current_value,
                  context: nil,
                  timestamp: nil,
                  apply: false,
                  details_open: false,
                  mapping_open: false,
                  has_change: false
                }
                | acc
              ]
            else
              acc
            end
        end
      end)
      |> Enum.reverse()

    suggestions ++ additional_rows
  end

  defp prepare_suggestion(suggestion, idx, selected_contact, mapping_fields) do
    mapped_field =
      suggestion
      |> Map.get(:mapped_field, Map.get(suggestion, :field))
      |> SalesforceSuggestions.normalize_field_key()

    mapped_label = mapping_field_label(mapping_fields, mapped_field, suggestion)

    current_value =
      case Map.get(suggestion, :current_value) do
        nil ->
          selected_contact
          |> SalesforceSuggestions.contact_field_value(mapped_field)
          |> then(&SalesforceSuggestions.normalize_field_value(mapped_field, &1))
          |> then(&sanitize_suggestion_value(mapped_field, mapped_label, &1, :current))

        value ->
          SalesforceSuggestions.normalize_field_value(mapped_field, value)
          |> then(&sanitize_suggestion_value(mapped_field, mapped_label, &1, :current))
      end

    new_value =
      suggestion
      |> Map.get(:new_value, Map.get(suggestion, :value, ""))
      |> then(&SalesforceSuggestions.normalize_field_value(mapped_field, &1))
      |> then(&sanitize_suggestion_value(mapped_field, mapped_label, &1, :new))

    has_change = SalesforceSuggestions.changed?(current_value, new_value)

    suggestion
    |> Map.put_new(:id, "sf-suggestion-#{idx}")
    |> Map.put(:mapped_field, mapped_field)
    |> Map.put(:mapped_label, mapped_label)
    |> Map.put(:current_value, current_value)
    |> Map.put(:new_value, new_value)
    |> Map.put(:has_change, has_change)
    |> Map.put(:apply, has_change && Map.get(suggestion, :apply, true))
    |> Map.put_new(:details_open, true)
    |> Map.put_new(:mapping_open, false)
  end

  defp mapping_field_label(mapping_fields, mapped_field, suggestion) do
    case Enum.find(mapping_fields, fn field -> field.name == mapped_field end) do
      nil -> Map.get(suggestion, :mapped_label, Map.get(suggestion, :label, mapped_field))
      field -> field.label
    end
  end

  @impl true
  def handle_event("select_salesforce_account", %{"credential_id" => credential_id}, socket) do
    credential =
      Enum.find(socket.assigns.credentials, fn candidate ->
        to_string(candidate.id) == credential_id
      end)

    socket =
      socket
      |> assign(:selected_credential, credential)
      |> assign(:selected_contact, nil)
      |> assign(:contacts, [])
      |> assign(:query, "")
      |> assign(:suggestions, [])
      |> assign(:mapping_fields, SalesforceSuggestions.default_mapping_fields())
      |> assign(:dropdown_open, false)
      |> assign(:loading, false)
      |> assign(:updating, false)
      |> assign(:searching, false)
      |> assign(:error, nil)
      |> assign(:form_error, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("contact_search", %{"value" => query}, socket) do
    query = String.trim(query)

    cond do
      is_nil(socket.assigns.selected_credential) and length(socket.assigns.credentials) > 1 ->
        {:noreply, assign(socket, error: "Please select a Salesforce account first")}

      is_nil(socket.assigns.selected_credential) ->
        {:noreply, assign(socket, error: "Please connect Salesforce again to continue")}

      true ->
        socket = assign(socket, searching: true, error: nil, query: query, dropdown_open: true)
        send(self(), {:salesforce_search, query, socket.assigns.selected_credential})
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_contact_dropdown", _params, socket) do
    cond do
      is_nil(socket.assigns.selected_credential) and length(socket.assigns.credentials) > 1 ->
        {:noreply,
         assign(socket, dropdown_open: false, error: "Please select a Salesforce account first")}

      is_nil(socket.assigns.selected_credential) ->
        {:noreply,
         assign(socket,
           dropdown_open: false,
           error: "Please connect Salesforce again to continue"
         )}

      true ->
        socket =
          socket
          |> assign(dropdown_open: true, searching: true, error: nil, query: "")

        send(self(), {:salesforce_search, "", socket.assigns.selected_credential})
        {:noreply, socket}
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
      socket = assign(socket, dropdown_open: true, searching: true)

      query =
        "#{socket.assigns.selected_contact.firstname} #{socket.assigns.selected_contact.lastname}"

      send(self(), {:salesforce_search, query, socket.assigns.selected_credential})
      {:noreply, socket}
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
        {:generate_salesforce_suggestions, contact, socket.assigns.meeting,
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
       step: :search,
       selected_contact: nil,
       suggestions: [],
       mapping_fields: SalesforceSuggestions.default_mapping_fields(),
       form_error: nil,
       loading: false,
       updating: false,
       searching: false,
       dropdown_open: false,
       contacts: [],
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
    applied_rows = Map.get(params, "apply", %{})
    values = Map.get(params, "values", %{})
    mapped_fields = Map.get(params, "mapped_fields", %{})
    toggled_row_id = toggled_apply_row_id(params)
    previous_pair_apply = mailing_pair_apply_value(socket.assigns.suggestions)
    checked_rows = Map.keys(applied_rows)

    suggestions =
      apply_form_state(
        socket.assigns.suggestions,
        applied_rows,
        values,
        mapped_fields,
        socket.assigns.selected_contact,
        socket.assigns.mapping_fields
      )
      |> ensure_mailing_pair_rows(socket.assigns.selected_contact, socket.assigns.mapping_fields)
      |> sync_mailing_pair_apply(toggled_row_id, previous_pair_apply)
      |> maybe_uncheck_mailing_pair_from_toggle(toggled_row_id, checked_rows)
      |> maybe_clear_mailing_pair_apply(applied_rows)

    {suggestions, form_error} = apply_duplicate_validation(suggestions)

    {:noreply, assign(socket, suggestions: suggestions, form_error: form_error)}
  end

  @impl true
  def handle_event("apply_updates", params, socket) do
    applied_rows = Map.get(params, "apply", %{})
    values = Map.get(params, "values", %{})
    mapped_fields = Map.get(params, "mapped_fields", %{})

    suggestions =
      apply_form_state(
        socket.assigns.suggestions,
        applied_rows,
        values,
        mapped_fields,
        socket.assigns.selected_contact,
        socket.assigns.mapping_fields
      )
      |> ensure_mailing_pair_rows(socket.assigns.selected_contact, socket.assigns.mapping_fields)
      |> sync_mailing_pair_apply(nil, mailing_pair_apply_value(socket.assigns.suggestions))

    {suggestions, form_error} = apply_duplicate_validation(suggestions)

    cond do
      form_error ->
        {:noreply, assign(socket, suggestions: suggestions, form_error: form_error)}

      true ->
        updates =
          suggestions
          |> Enum.filter(&(&1.apply == true and &1.has_change == true))
          |> Enum.reduce(%{}, fn suggestion, acc ->
            Map.put(acc, suggestion.mapped_field, suggestion.new_value)
          end)

        if map_size(updates) == 0 do
          {:noreply,
           assign(socket,
             suggestions: suggestions,
             form_error: "Please select at least one changed field to update"
           )}
        else
          send(self(), {:salesforce_modal_lock, true})

          socket =
            assign(socket,
              suggestions: suggestions,
              updating: true,
              error: nil,
              form_error: nil
            )

          send(
            self(),
            {:apply_salesforce_updates, updates, socket.assigns.selected_contact,
             socket.assigns.selected_credential}
          )

          {:noreply, socket}
        end
    end
  end

  defp apply_form_state(
         suggestions,
         applied_rows,
         values,
         mapped_fields,
         selected_contact,
         mapping_fields
       ) do
    checked_rows = Map.keys(applied_rows)

    Enum.map(suggestions, fn suggestion ->
      row_id = suggestion.id

      mapped_field =
        mapped_fields
        |> Map.get(row_id, suggestion.mapped_field || suggestion.field)
        |> SalesforceSuggestions.normalize_field_key()

      mapped_label = mapping_field_label(mapping_fields, mapped_field, suggestion)

      current_value =
        selected_contact
        |> SalesforceSuggestions.contact_field_value(mapped_field)
        |> then(&SalesforceSuggestions.normalize_field_value(mapped_field, &1))
        |> then(&sanitize_suggestion_value(mapped_field, mapped_label, &1, :current))

      new_value =
        values
        |> Map.get(row_id, suggestion.new_value || "")
        |> then(&SalesforceSuggestions.normalize_field_value(mapped_field, &1))
        |> then(&sanitize_suggestion_value(mapped_field, mapped_label, &1, :new))

      has_change = SalesforceSuggestions.changed?(current_value, new_value)
      apply? = row_id in checked_rows

      suggestion
      |> Map.put(:mapped_field, mapped_field)
      |> Map.put(:mapped_label, mapped_label)
      |> Map.put(:current_value, current_value)
      |> Map.put(:new_value, new_value)
      |> Map.put(:has_change, has_change)
      |> Map.put(:apply, apply?)
      |> Map.put(:details_open, apply?)
    end)
  end

  defp sanitize_suggestion_value(field, label, value, :new) when is_binary(value) do
    if SalesforceSuggestions.identifier_like_value?(field, label, value) do
      nil
    else
      value
    end
  end

  defp sanitize_suggestion_value(field, label, value, :current) when is_binary(value) do
    if SalesforceSuggestions.identifier_like_value?(field, label, value) do
      nil
    else
      value
    end
  end

  defp sanitize_suggestion_value(_field, _label, value, _kind), do: value

  defp invalid_suggestion_row?(suggestion) do
    new_value = Map.get(suggestion, :new_value)

    is_nil(new_value) or (is_binary(new_value) and String.trim(new_value) == "")
  end

  defp present_existing_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_existing_value?(nil), do: false
  defp present_existing_value?(_), do: true

  defp include_existing_row?(mapped_field, mapped_label) do
    normalized_field = String.downcase(to_string(mapped_field || ""))
    normalized_label = String.downcase(to_string(mapped_label || ""))

    normalized_field != "ownerid" and normalized_label != "owner id"
  end

  defp apply_duplicate_validation(suggestions) do
    selected_suggestions = Enum.filter(suggestions, &(&1.apply == true))

    duplicates =
      selected_suggestions
      |> Enum.group_by(& &1.mapped_field)
      |> Enum.filter(fn {_field, mapped} -> length(mapped) > 1 end)

    case duplicates do
      [] ->
        {suggestions, nil}

      duplicate_groups ->
        duplicate_fields =
          duplicate_groups
          |> Enum.map(fn {_field, mapped} ->
            mapped
            |> List.first()
            |> Map.get(:mapped_label, "Unknown field")
          end)
          |> Enum.join(", ")

        {suggestions,
         "Each Salesforce field can only be updated once per submit. Duplicate mappings: #{duplicate_fields}"}
    end
  end

  defp toggled_apply_row_id(%{"_target" => ["apply", row_id]}) when is_binary(row_id), do: row_id
  defp toggled_apply_row_id(_params), do: nil

  defp mailing_pair_present?(suggestions) do
    Enum.any?(suggestions, fn suggestion ->
      suggestion.mapped_field in ["mailingstate", "mailingcountry"]
    end)
  end

  defp ensure_mailing_pair_rows(suggestions, selected_contact, mapping_fields) do
    if mailing_pair_present?(suggestions) do
      suggestions
      |> maybe_add_missing_pair_row("mailingstate", selected_contact, mapping_fields)
      |> maybe_add_missing_pair_row("mailingcountry", selected_contact, mapping_fields)
      |> order_mailing_pair_rows()
    else
      suggestions
    end
  end

  defp maybe_add_missing_pair_row(suggestions, field, selected_contact, mapping_fields) do
    if Enum.any?(suggestions, &(&1.mapped_field == field)) do
      suggestions
    else
      suggestions ++ [build_missing_pair_row(field, selected_contact, mapping_fields)]
    end
  end

  defp build_missing_pair_row(field, selected_contact, mapping_fields) do
    mapped_label =
      mapping_field_label(mapping_fields, field, %{mapped_label: field, label: field})

    current_value =
      selected_contact
      |> SalesforceSuggestions.contact_field_value(field)
      |> then(&SalesforceSuggestions.normalize_field_value(field, &1))
      |> then(&sanitize_suggestion_value(field, mapped_label, &1, :current))

    %{
      id: "sf-paired-#{field}",
      field: field,
      mapped_field: field,
      label: mapped_label,
      mapped_label: mapped_label,
      current_value: current_value,
      new_value: current_value,
      context: nil,
      timestamp: nil,
      apply: false,
      details_open: true,
      mapping_open: false,
      has_change: SalesforceSuggestions.changed?(current_value, current_value)
    }
  end

  defp order_mailing_pair_rows(suggestions) do
    state_row = Enum.find(suggestions, &(&1.mapped_field == "mailingstate"))
    country_row = Enum.find(suggestions, &(&1.mapped_field == "mailingcountry"))

    case {state_row, country_row} do
      {%{} = state_row, %{} = country_row} ->
        {reversed, inserted?} =
          Enum.reduce(suggestions, {[], false}, fn suggestion, {acc, inserted?} ->
            if suggestion.mapped_field in ["mailingstate", "mailingcountry"] do
              if inserted? do
                {acc, inserted?}
              else
                {[country_row, state_row | acc], true}
              end
            else
              {[suggestion | acc], inserted?}
            end
          end)

        if inserted?, do: Enum.reverse(reversed), else: suggestions

      _ ->
        suggestions
    end
  end

  defp sync_mailing_pair_apply(suggestions, toggled_row_id, previous_pair_apply) do
    state_row = Enum.find(suggestions, &(&1.mapped_field == "mailingstate"))
    country_row = Enum.find(suggestions, &(&1.mapped_field == "mailingcountry"))

    case {state_row, country_row} do
      {%{id: state_id, apply: state_apply}, %{id: country_id, apply: country_apply}} ->
        cond do
          state_apply == country_apply ->
            suggestions

          toggled_row_id == state_id ->
            Enum.map(suggestions, &set_pair_apply(&1, state_apply))

          toggled_row_id == country_id ->
            Enum.map(suggestions, &set_pair_apply(&1, country_apply))

          true ->
            mirror_apply =
              case previous_pair_apply do
                true -> false
                false -> true
                _ -> state_apply or country_apply
              end

            Enum.map(suggestions, &set_pair_apply(&1, mirror_apply))
        end

      _ ->
        suggestions
    end
  end

  defp set_pair_apply(%{mapped_field: mapped_field} = suggestion, apply?)
       when mapped_field in ["mailingstate", "mailingcountry"] do
    Map.put(suggestion, :apply, apply?)
  end

  defp set_pair_apply(suggestion, _apply?), do: suggestion

  defp maybe_clear_mailing_pair_apply(suggestions, applied_rows)
       when map_size(applied_rows) == 0 do
    Enum.map(suggestions, &set_pair_apply(&1, false))
  end

  defp maybe_clear_mailing_pair_apply(suggestions, _applied_rows), do: suggestions

  defp maybe_uncheck_mailing_pair_from_toggle(suggestions, toggled_row_id, checked_rows) do
    if is_binary(toggled_row_id) and toggled_row_id not in checked_rows do
      case Enum.find(suggestions, &(&1.id == toggled_row_id)) do
        %{mapped_field: mapped_field} when mapped_field in ["mailingstate", "mailingcountry"] ->
          Enum.map(suggestions, &set_pair_apply(&1, false))

        _ ->
          suggestions
      end
    else
      suggestions
    end
  end

  defp mailing_pair_apply_value(suggestions) do
    state_apply =
      suggestions
      |> Enum.find(&(&1.mapped_field == "mailingstate"))
      |> case do
        %{apply: apply?} -> apply?
        _ -> nil
      end

    country_apply =
      suggestions
      |> Enum.find(&(&1.mapped_field == "mailingcountry"))
      |> case do
        %{apply: apply?} -> apply?
        _ -> nil
      end

    if state_apply in [true, false] and country_apply in [true, false] and
         state_apply == country_apply do
      state_apply
    else
      nil
    end
  end

  defp selected_updates_summary(suggestions) do
    selected_count = Enum.count(suggestions, &(&1.apply == true))
    field_label = if selected_count == 1, do: "field", else: "fields"
    "1 contact, #{selected_count} #{field_label} selected for update"
  end
end
