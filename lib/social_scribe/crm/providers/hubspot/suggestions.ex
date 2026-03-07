defmodule SocialScribe.CRM.Providers.Hubspot.Suggestions do
  @moduledoc """
  Generates and formats HubSpot contact update suggestions by combining
  AI-extracted data with existing HubSpot contact information.
  """

  alias SocialScribe.AIContentGeneratorApi
  alias SocialScribe.Accounts.UserCredential
  alias SocialScribe.CRM.Providers.Hubspot.Api
  alias SocialScribe.CRM.SuggestionsHelpers

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
        type: "text",
        options: []
      }
    end)
  end

  @doc """
  Builds a mapping_fields list from the HubSpot Properties API response,
  restricted to the allowed field list. Falls back to default_mapping_fields
  on error or empty response.
  """
  def build_mapping_fields(credential) do
    case api_impl().describe_contact_fields(credential) do
      {:ok, fields} when is_list(fields) and fields != [] ->
        fields
        |> Enum.filter(fn field ->
          name = Map.get(field, :name) || Map.get(field, "name")
          allowed_field?(normalize_field_key(name))
        end)
        |> Enum.map(fn field ->
          name = normalize_field_key(Map.get(field, :name) || Map.get(field, "name"))
          label = Map.get(field, :label) || Map.get(field, "label") || Map.get(@field_labels, name, name)
          type = Map.get(field, :type) || Map.get(field, "type") || "text"
          options = Map.get(field, :options) || Map.get(field, "options") || []
          %{name: name, label: label, type: type, options: options}
        end)
        |> case do
          [] -> default_mapping_fields()
          mapped -> mapped
        end

      _ ->
        default_mapping_fields()
    end
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
    transcript_index = SuggestionsHelpers.build_transcript_index(meeting)

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
    transcript_index = SuggestionsHelpers.build_transcript_index(meeting)

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

      has_change = SuggestionsHelpers.changed?(current_value, new_value)
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
    |> SuggestionsHelpers.dedupe_suggestions()
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
    |> SuggestionsHelpers.normalize_for_display()
    |> then(fn
      nil -> nil
      normalized -> String.downcase(normalized)
    end)
  end

  def normalize_field_value(_field, value), do: SuggestionsHelpers.normalize_for_display(value)

  defdelegate changed?(current_value, new_value), to: SuggestionsHelpers

  def contact_field_value(contact, field) when is_map(contact) and is_binary(field) do
    case get_standard_contact_field(contact, field) do
      nil -> SuggestionsHelpers.map_get(contact, field)
      value -> value
    end
  end

  def contact_field_value(_, _), do: nil

  # ---------------------------------------------------------------------------
  # Private pipeline
  # ---------------------------------------------------------------------------

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
        timestamp:
          SuggestionsHelpers.resolve_timestamp(
            ai_timestamp,
            context,
            value,
            transcript_index
          ),
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
    |> SuggestionsHelpers.dedupe_suggestions()
  end

  defp valid_suggestion?(%{field: field, new_value: value, label: label}) do
    allowed_field?(field) and is_binary(value) and value != "" and
      not SuggestionsHelpers.identifier_like_value?(field, label, value)
  end

  defp valid_suggestion?(_), do: false

  defp suggestion_id(field, index, timestamp, new_value) do
    hash = :erlang.phash2({field, timestamp, new_value, index})
    "hubspot-suggestion-#{index}-#{hash}"
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

  defp api_impl do
    Application.get_env(:social_scribe, :hubspot_api, Api)
  end
end
