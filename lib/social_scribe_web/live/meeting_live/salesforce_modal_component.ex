defmodule SocialScribeWeb.MeetingLive.SalesforceModalComponent do
  use SocialScribeWeb, :live_component

  import SocialScribeWeb.ModalComponents

  alias SocialScribe.SalesforceSuggestions

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :patch, ~p"/dashboard/meetings/#{assigns.meeting}")
    assigns = assign_new(assigns, :modal_id, fn -> "salesforce-modal-wrapper" end)
    assigns = assign(assigns, :requires_account_selection, length(assigns.credentials) > 1)

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
        <label class="block text-sm font-medium text-slate-700">Select Salesforce Account</label>
        <select
          class="w-full bg-white border border-hubspot-input rounded-lg py-2 px-3 text-sm"
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
          myself={@myself}
          patch={@patch}
          mapping_fields={@mapping_fields}
          form_error={@form_error}
        />
      <% end %>
    </div>
    """
  end

  attr :suggestions, :list, required: true
  attr :loading, :boolean, required: true
  attr :myself, :any, required: true
  attr :patch, :string, required: true
  attr :mapping_fields, :list, required: true
  attr :form_error, :string, default: nil

  defp suggestions_section(assigns) do
    assigns =
      assign(assigns, :selected_count, Enum.count(assigns.suggestions, &(&1.apply == true)))

    ~H"""
    <div class="space-y-4">
      <%= if @loading do %>
        <div class="text-center py-8 text-slate-500">
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
              cancel_patch={@patch}
              submit_text="Update Salesforce"
              submit_class="bg-blue-600 hover:bg-blue-700"
              disabled={@selected_count == 0}
              loading={@loading}
              loading_text="Updating..."
              info_text={"1 object, #{@selected_count} fields in 1 integration selected to update"}
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
    ~H"""
    <div class="bg-hubspot-card rounded-2xl p-6 mb-4">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <div class="flex items-center">
            <input
              id={"suggestion-apply-#{@suggestion.id}"}
              type="checkbox"
              name={"apply[#{@suggestion.id}]"}
              value="1"
              checked={@suggestion.apply}
              disabled={!@suggestion.has_change}
              class="h-4 w-4 rounded-[3px] border-slate-300 text-hubspot-checkbox accent-hubspot-checkbox focus:ring-0 focus:ring-offset-0 cursor-pointer"
            />
          </div>
          <div class="text-sm font-semibold text-slate-900 leading-5">{@suggestion.mapped_label}</div>
        </div>

        <div class="flex items-center gap-3">
          <button
            type="button"
            phx-click="toggle_suggestion_details"
            phx-value-id={@suggestion.id}
            phx-target={@myself}
            aria-label={if @suggestion.details_open, do: "Hide details", else: "Show details"}
            class="text-hubspot-hide hover:text-hubspot-hide-hover"
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

      <div :if={@suggestion.details_open} class="mt-3">
        <div class="mt-1">
          <div class="grid grid-cols-[1fr_32px_1fr] items-center gap-6">
            <input
              type="text"
              readonly
              value={@suggestion.current_value || ""}
              placeholder="No existing value"
              class={[
                "block w-full shadow-sm text-sm bg-white border border-gray-300 rounded-[7px] py-1.5 px-2",
                if(@suggestion.current_value && @suggestion.current_value != "",
                  do: "line-through text-gray-500",
                  else: "text-gray-400"
                )
              ]}
            />

            <div class="w-8 flex justify-center text-hubspot-arrow">
              <.icon name="hero-arrow-long-right" class="h-7 w-7" />
            </div>

            <input
              type="text"
              name={"values[#{@suggestion.id}]"}
              value={@suggestion.new_value}
              class="block w-full shadow-sm text-sm text-slate-900 bg-white border border-hubspot-input rounded-[7px] py-1.5 px-2 focus:ring-blue-500 focus:border-blue-500"
            />
          </div>
        </div>

        <p :if={!@suggestion.has_change} class="text-xs text-amber-700 mt-2">
          No change detected for this mapped field.
        </p>

        <div class="mt-3 grid grid-cols-[1fr_32px_1fr] items-start gap-6">
          <div class="justify-self-start">
            <button
              type="button"
              phx-click="toggle_suggestion_mapping"
              phx-value-id={@suggestion.id}
              phx-target={@myself}
              class="text-xs text-hubspot-link hover:text-hubspot-link-hover font-medium"
            >
              Update mapping
            </button>

            <div :if={@suggestion.mapping_open} class="mt-2">
              <select
                name={"mapped_fields[#{@suggestion.id}]"}
                class="w-full min-w-56 bg-white border border-hubspot-input rounded-lg py-1.5 px-2 text-sm"
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

          <span></span>

          <span :if={@suggestion[:timestamp]} class="text-xs text-slate-500 justify-self-start">
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

    {prepared, form_error} = apply_duplicate_validation(prepared)

    socket
    |> assign(:suggestions, prepared)
    |> assign(:form_error, form_error)
  end

  defp maybe_prepare_suggestions(socket, _assigns), do: socket

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

    suggestions =
      apply_form_state(
        socket.assigns.suggestions,
        applied_rows,
        values,
        mapped_fields,
        socket.assigns.selected_contact,
        socket.assigns.mapping_fields
      )

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
          socket =
            assign(socket,
              suggestions: suggestions,
              loading: true,
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
      apply? = row_id in checked_rows and has_change

      suggestion
      |> Map.put(:mapped_field, mapped_field)
      |> Map.put(:mapped_label, mapped_label)
      |> Map.put(:current_value, current_value)
      |> Map.put(:new_value, new_value)
      |> Map.put(:has_change, has_change)
      |> Map.put(:apply, apply?)
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
end
