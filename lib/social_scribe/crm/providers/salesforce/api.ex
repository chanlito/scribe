defmodule SocialScribe.CRM.Providers.Salesforce.Api do
  @moduledoc """
  Salesforce CRM API client for Contact operations.
  """

  @behaviour SocialScribe.CRM.ApiBehaviour
  @behaviour SocialScribe.CRM.DescribeFieldsBehaviour

  alias SocialScribe.Accounts.UserCredential
  alias SocialScribe.SalesforceTokenRefresher

  require Logger

  @api_version "v61.0"
  @contact_fields [
    "Id",
    "FirstName",
    "LastName",
    "Email",
    "Phone",
    "MobilePhone",
    "Title",
    "Department",
    "MailingStreet",
    "MailingCity",
    "MailingState",
    "MailingPostalCode",
    "MailingCountry"
  ]

  @field_mapping %{
    "firstname" => "FirstName",
    "lastname" => "LastName",
    "email" => "Email",
    "phone" => "Phone",
    "mobilephone" => "MobilePhone",
    "title" => "Title",
    "department" => "Department",
    "mailingstreet" => "MailingStreet",
    "mailingcity" => "MailingCity",
    "mailingstate" => "MailingState",
    "mailingpostalcode" => "MailingPostalCode",
    "mailingcountry" => "MailingCountry"
  }

  @salesforce_standard_fields Map.values(@field_mapping)

  defp client(instance_url, access_token) do
    Tesla.client([
      {Tesla.Middleware.BaseUrl, instance_url},
      Tesla.Middleware.JSON,
      {Tesla.Middleware.Headers,
       [
         {"Authorization", "Bearer #{access_token}"},
         {"Content-Type", "application/json"}
       ]}
    ])
  end

  @impl true
  def search_contacts(%UserCredential{} = credential, query) when is_binary(query) do
    with_token_refresh(credential, fn cred, instance_url ->
      with {:ok, owner_id} <- extract_salesforce_user_id(cred) do
        soql = build_search_soql(query, owner_id)
        url = "/services/data/#{@api_version}/query"

        case Tesla.get(client(instance_url, cred.token), url, query: [q: squish(soql)]) do
          {:ok, %Tesla.Env{status: 200, body: %{"records" => records}}} ->
            {:ok, Enum.map(records, &format_contact/1)}

          {:ok, %Tesla.Env{status: status, body: body}} ->
            {:error, {:api_error, status, body}}

          {:error, reason} ->
            {:error, {:http_error, reason}}
        end
      end
    end)
  end

  @impl true
  def get_contact(%UserCredential{} = credential, contact_id) when is_binary(contact_id) do
    with_token_refresh(credential, fn cred, instance_url ->
      url = "/services/data/#{@api_version}/sobjects/Contact/#{contact_id}"

      case Tesla.get(client(instance_url, cred.token), url) do
        {:ok, %Tesla.Env{status: 200, body: record}} when is_map(record) ->
          {:ok, format_contact(record)}

        {:ok, %Tesla.Env{status: 404}} ->
          {:error, :not_found}

        {:ok, %Tesla.Env{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end)
  end

  @impl true
  def describe_contact_fields(%UserCredential{} = credential) do
    with_token_refresh(credential, fn cred, instance_url ->
      describe_contact_fields_internal(cred, instance_url)
    end)
  end

  @impl true
  def update_contact(%UserCredential{} = credential, contact_id, updates)
      when is_binary(contact_id) and is_map(updates) do
    with_token_refresh(credential, fn cred, instance_url ->
      with {:ok, describe_fields} <- describe_contact_fields_internal(cred, instance_url) do
        field_types = build_field_type_map(describe_fields)

        case to_salesforce_updates(updates, field_types) do
          {:error, errors} ->
            {:error, {:invalid_updates, errors}}

          {:ok, api_updates} ->
            url = "/services/data/#{@api_version}/sobjects/Contact/#{contact_id}"

            if map_size(api_updates) == 0 do
              {:ok, :no_updates}
            else
              case Tesla.patch(client(instance_url, cred.token), url, api_updates) do
                {:ok, %Tesla.Env{status: status}} when status in [204, 200] ->
                  get_contact(cred, contact_id)

                {:ok, %Tesla.Env{status: 404}} ->
                  {:error, :not_found}

                {:ok, %Tesla.Env{status: status, body: body}} ->
                  {:error, {:api_error, status, body}}

                {:error, reason} ->
                  {:error, {:http_error, reason}}
              end
            end
        end
      end
    end)
  end

  @impl true
  def apply_updates(%UserCredential{} = credential, contact_id, updates_list)
      when is_list(updates_list) do
    updates_map =
      updates_list
      |> Enum.filter(fn update -> update[:apply] == true end)
      |> Enum.reduce(%{}, fn update, acc ->
        field = to_string(update.field)

        if Map.has_key?(@field_mapping, field) or custom_field_name?(field) do
          Map.put(acc, update.field, update.new_value)
        else
          acc
        end
      end)

    if map_size(updates_map) > 0 do
      update_contact(credential, contact_id, updates_map)
    else
      {:ok, :no_updates}
    end
  end

  defp to_salesforce_updates(updates, field_types) do
    {api_updates, errors} =
      Enum.reduce(updates, {%{}, []}, fn {key, value}, {acc_updates, acc_errors} ->
        key = to_string(key)

        case resolve_api_field_name(key) do
          nil ->
            {acc_updates, acc_errors}

          api_field ->
            salesforce_type = Map.get(field_types, api_field)

            case coerce_update_value(value, salesforce_type, api_field) do
              {:ok, normalized_value} ->
                {Map.put(acc_updates, api_field, normalized_value), acc_errors}

              {:error, message} ->
                error = %{
                  field: api_field,
                  type: salesforce_type,
                  value: value,
                  message: message
                }

                {acc_updates, [error | acc_errors]}
            end
        end
      end)

    case errors do
      [] -> {:ok, api_updates}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp resolve_api_field_name(key) when is_binary(key) do
    cond do
      Map.has_key?(@field_mapping, key) ->
        Map.fetch!(@field_mapping, key)

      key in @salesforce_standard_fields ->
        key

      custom_field_name?(key) ->
        key

      true ->
        nil
    end
  end

  defp format_contact(record) do
    %{
      id: record["Id"],
      firstname: record["FirstName"],
      lastname: record["LastName"],
      email: record["Email"],
      phone: record["Phone"],
      mobilephone: record["MobilePhone"],
      title: record["Title"],
      department: record["Department"],
      mailingstreet: record["MailingStreet"],
      mailingcity: record["MailingCity"],
      mailingstate: record["MailingState"],
      mailingpostalcode: record["MailingPostalCode"],
      mailingcountry: record["MailingCountry"],
      fields: Map.drop(record, ["attributes"]),
      display_name: format_display_name(record)
    }
  end

  defp format_display_name(properties) do
    firstname = properties["FirstName"] || ""
    lastname = properties["LastName"] || ""
    email = properties["Email"] || ""

    name = String.trim("#{firstname} #{lastname}")

    if name == "", do: email, else: name
  end

  defp with_token_refresh(%UserCredential{} = credential, api_call) do
    with {:ok, credential} <- SalesforceTokenRefresher.ensure_valid_token(credential),
         {:ok, instance_url} <- SalesforceTokenRefresher.instance_url(credential) do
      case api_call.(credential, instance_url) do
        {:error, {:api_error, status, body}} when status in [400, 401] ->
          if is_token_error?(body) do
            Logger.info("Salesforce token expired, refreshing and retrying...")
            retry_with_fresh_token(credential, api_call)
          else
            {:error, {:api_error, status, body}}
          end

        result ->
          result
      end
    end
  end

  defp retry_with_fresh_token(credential, api_call) do
    case SalesforceTokenRefresher.refresh_credential(credential) do
      {:ok, refreshed_credential} ->
        with {:ok, instance_url} <- SalesforceTokenRefresher.instance_url(refreshed_credential) do
          api_call.(refreshed_credential, instance_url)
        end

      {:error, refresh_error} ->
        Logger.error("Failed to refresh Salesforce token: #{inspect(refresh_error)}")
        {:error, {:token_refresh_failed, refresh_error}}
    end
  end

  defp is_token_error?(body) when is_list(body) do
    Enum.any?(body, fn
      %{"errorCode" => "INVALID_SESSION_ID"} -> true
      _ -> false
    end)
  end

  defp is_token_error?(%{"errorCode" => "INVALID_SESSION_ID"}), do: true

  defp is_token_error?(%{"message" => message}) when is_binary(message) do
    String.contains?(String.downcase(message), ["session", "expired", "invalid"])
  end

  defp is_token_error?(_), do: false

  defp escape_soql_literal(value) do
    String.replace(value, "'", "\\'")
  end

  @doc false
  def build_search_soql(query, owner_id) when is_binary(query) and is_binary(owner_id) do
    query = String.trim(query)
    owner_id = escape_soql_literal(String.trim(owner_id))

    if query == "" do
      """
      SELECT #{Enum.join(@contact_fields, ", ")}
      FROM Contact
      WHERE OwnerId = '#{owner_id}'
      ORDER BY LastModifiedDate DESC
      LIMIT 20
      """
    else
      like = "%" <> escape_soql_literal(query) <> "%"

      """
      SELECT #{Enum.join(@contact_fields, ", ")}
      FROM Contact
      WHERE OwnerId = '#{owner_id}' AND (
        Name LIKE '#{like}' OR
        Email LIKE '#{like}' OR
        Phone LIKE '#{like}' OR
        MobilePhone LIKE '#{like}'
      )
      ORDER BY LastModifiedDate DESC
      LIMIT 20
      """
    end
  end

  @doc false
  def extract_salesforce_user_id(%UserCredential{metadata: metadata}) do
    metadata = normalize_metadata(metadata)
    identity_url = metadata["identity_url"] || metadata["id_url"]

    with identity when is_binary(identity) and identity != "" <- identity_url,
         %URI{path: path} <- URI.parse(identity),
         true <- is_binary(path) and path != "",
         [_id, _org_id, user_id] <- path |> String.trim("/") |> String.split("/", trim: true),
         true <- user_id != "" do
      {:ok, user_id}
    else
      _ ->
        {:error,
         {:reconnect_required,
          "Salesforce identity is missing. Please reconnect Salesforce to search only contacts you own."}}
    end
  end

  defp squish(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_metadata(nil), do: %{}
  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_), do: %{}

  defp custom_field_name?(field_name) when is_binary(field_name) do
    Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_]*__c\z/, field_name)
  end

  defp describe_contact_fields_internal(credential, instance_url) do
    url = "/services/data/#{@api_version}/sobjects/Contact/describe"

    case Tesla.get(client(instance_url, credential.token), url) do
      {:ok, %Tesla.Env{status: 200, body: %{"fields" => fields}}} ->
        normalized_fields =
          fields
          |> Enum.filter(&is_map/1)
          |> Enum.map(fn field ->
            %{
              name: field["name"],
              label: field["label"] || field["name"],
              type: field["type"],
              picklist_values: normalize_picklist_values(field["picklistValues"]),
              createable: field["createable"] == true,
              updateable: field["updateable"] == true
            }
          end)
          |> Enum.filter(fn field -> field.name && (field.createable || field.updateable) end)

        {:ok, normalized_fields}

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp build_field_type_map(describe_fields) do
    Enum.reduce(describe_fields, %{}, fn field, acc ->
      Map.put(acc, field.name, field.type)
    end)
  end

  defp normalize_picklist_values(values) when is_list(values) do
    values
    |> Enum.filter(&is_map/1)
    |> Enum.filter(fn value -> Map.get(value, "active") != false end)
    |> Enum.map(fn value ->
      picklist_value = Map.get(value, "value")
      picklist_label = Map.get(value, "label") || picklist_value

      if is_binary(picklist_value) and String.trim(picklist_value) != "" do
        %{value: picklist_value, label: picklist_label}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_picklist_values(_), do: []

  @doc false
  def normalize_update_value(value, salesforce_type) do
    case coerce_update_value(value, salesforce_type, "") do
      {:ok, normalized} -> normalized
      {:error, _} -> value
    end
  end

  defp coerce_update_value(nil, _type, _field), do: {:ok, nil}

  defp coerce_update_value(value, type, field) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        {:ok, nil}

      field == "Email" or type == "email" ->
        {:ok, String.downcase(value)}

      type in ["currency", "double", "percent"] ->
        parse_decimal_string(value)

      type in ["int", "integer", "long"] ->
        parse_integer_string(value)

      type == "boolean" ->
        parse_boolean_string(value)

      type == "date" ->
        parse_date_string(value)

      type in ["datetime", "time"] ->
        parse_datetime_string(value)

      true ->
        {:ok, value}
    end
    |> with_error_context(type, field)
  end

  defp coerce_update_value(value, type, _field) when type in ["currency", "double", "percent"] do
    if is_number(value), do: {:ok, value * 1.0}, else: {:error, "must be a number"}
  end

  defp coerce_update_value(value, type, _field) when type in ["int", "integer", "long"] do
    if is_integer(value), do: {:ok, value}, else: {:error, "must be an integer"}
  end

  defp coerce_update_value(value, "boolean", _field) when is_boolean(value), do: {:ok, value}

  defp coerce_update_value(%Date{} = value, "date", _field), do: {:ok, Date.to_iso8601(value)}

  defp coerce_update_value(%DateTime{} = value, type, _field) when type in ["datetime", "time"] do
    {:ok, DateTime.to_iso8601(value)}
  end

  defp coerce_update_value(%NaiveDateTime{} = value, type, _field)
       when type in ["datetime", "time"] do
    case DateTime.from_naive(value, "Etc/UTC") do
      {:ok, datetime} -> {:ok, DateTime.to_iso8601(datetime)}
      {:error, _} -> {:error, "must be a valid datetime"}
    end
  end

  defp coerce_update_value(value, _type, _field), do: {:ok, value}

  defp with_error_context({:ok, value}, _type, _field), do: {:ok, value}

  defp with_error_context({:error, message}, type, field) do
    type = type || "string"

    if field == "" do
      {:error, message}
    else
      {:error, "expected #{type} value (#{message})"}
    end
  end

  defp parse_decimal_string(value) do
    sanitized =
      value
      |> String.replace(~r/[,$%\s]/, "")
      |> normalize_parentheses_negative()

    case Float.parse(sanitized) do
      {number, ""} -> {:ok, number}
      _ -> {:error, "must be a number"}
    end
  end

  defp parse_integer_string(value) do
    sanitized =
      value
      |> String.replace(~r/[,$\s]/, "")
      |> normalize_parentheses_negative()

    case Integer.parse(sanitized) do
      {number, ""} -> {:ok, number}
      _ -> {:error, "must be an integer"}
    end
  end

  defp normalize_parentheses_negative(value) do
    case Regex.run(~r/^\((.+)\)$/, value, capture: :all_but_first) do
      [inner] -> "-" <> inner
      _ -> value
    end
  end

  defp parse_boolean_string(value) do
    downcased = String.downcase(value)

    case downcased do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      "yes" -> {:ok, true}
      "no" -> {:ok, false}
      "1" -> {:ok, true}
      "0" -> {:ok, false}
      _ -> {:error, "must be true/false"}
    end
  end

  defp parse_date_string(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        {:ok, Date.to_iso8601(date)}

      _ ->
        case Regex.run(~r/^\s*(\d{1,2})\/(\d{1,2})\/(\d{4})\s*$/, value, capture: :all_but_first) do
          [month, day, year] ->
            with {month, ""} <- Integer.parse(month),
                 {day, ""} <- Integer.parse(day),
                 {year, ""} <- Integer.parse(year),
                 {:ok, date} <- Date.new(year, month, day) do
              {:ok, Date.to_iso8601(date)}
            else
              _ -> {:error, "must be YYYY-MM-DD or MM/DD/YYYY"}
            end

          _ ->
            {:error, "must be YYYY-MM-DD or MM/DD/YYYY"}
        end
    end
  end

  defp parse_datetime_string(value) do
    value = String.trim(value)
    normalized = normalize_datetime_input(value)

    case DateTime.from_iso8601(normalized) do
      {:ok, datetime, _offset} ->
        {:ok, DateTime.to_iso8601(datetime)}

      {:error, _} ->
        case NaiveDateTime.from_iso8601(normalized) do
          {:ok, naive_datetime} ->
            case DateTime.from_naive(naive_datetime, "Etc/UTC") do
              {:ok, datetime} -> {:ok, DateTime.to_iso8601(datetime)}
              {:error, _} -> {:error, "must be an ISO datetime"}
            end

          {:error, _} ->
            {:error, "must be an ISO datetime"}
        end
    end
  end

  defp normalize_datetime_input(value) do
    value
    |> String.replace(" ", "T")
    |> ensure_seconds_for_datetime()
  end

  defp ensure_seconds_for_datetime(value) do
    case Regex.run(~r/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})(Z|[+-]\d{2}:\d{2})?$/, value) do
      [_, base] -> base <> ":00"
      [_, base, tz] -> base <> ":00" <> tz
      _ -> value
    end
  end
end
