defmodule SocialScribe.AIContentGenerator do
  @moduledoc "Generates content using Google Gemini."

  @behaviour SocialScribe.AIContentGeneratorApi

  alias SocialScribe.Meetings
  alias SocialScribe.Automations

  @default_gemini_model "gemini-2.5-flash-lite"
  @gemini_api_base_url "https://generativelanguage.googleapis.com/v1beta/models"

  @impl SocialScribe.AIContentGeneratorApi
  def generate_follow_up_email(meeting) do
    case Meetings.generate_prompt_for_meeting(meeting) do
      {:error, reason} ->
        {:error, reason}

      {:ok, meeting_prompt} ->
        prompt = """
        Based on the following meeting transcript, please draft a concise and professional follow-up email.
        The email should summarize the key discussion points and clearly list any action items assigned, including who is responsible if mentioned.
        Keep the tone friendly and action-oriented.

        #{meeting_prompt}
        """

        call_gemini(prompt)
    end
  end

  @impl SocialScribe.AIContentGeneratorApi
  def generate_automation(automation, meeting) do
    case Meetings.generate_prompt_for_meeting(meeting) do
      {:error, reason} ->
        {:error, reason}

      {:ok, meeting_prompt} ->
        prompt = """
        #{Automations.generate_prompt_for_automation(automation)}

        #{meeting_prompt}
        """

        call_gemini(prompt)
    end
  end

  @impl SocialScribe.AIContentGeneratorApi
  def generate_hubspot_suggestions(meeting) do
    case Meetings.generate_prompt_for_meeting(meeting) do
      {:error, reason} ->
        {:error, reason}

      {:ok, meeting_prompt} ->
        prompt = """
        You are an AI assistant that extracts contact information updates from meeting transcripts.

        Analyze the following meeting transcript and extract any information that could be used to update a CRM contact record.

        Look for mentions of:
        - Phone numbers (phone, mobilephone)
        - Email addresses (email)
        - Company name (company)
        - Job title/role (jobtitle)
        - Physical address details (address, city, state, zip, country)
        - Website URLs (website)
        - LinkedIn profile (linkedin_url)
        - Twitter handle (twitter_handle)

        IMPORTANT: Only extract information that is EXPLICITLY mentioned in the transcript. Do not infer or guess.

        The transcript includes timestamps in [MM:SS] format at the start of each line.

        Return your response as a JSON array of objects. Each object should have:
        - "field": the CRM field name (use exactly: firstname, lastname, email, phone, mobilephone, company, jobtitle, address, city, state, zip, country, website, linkedin_url, twitter_handle)
        - "value": the extracted value
        - "context": a brief quote of where this was mentioned
        - "timestamp": the timestamp in MM:SS format where this was mentioned

        If no contact information updates are found, return an empty array: []

        Example response format:
        [
          {"field": "phone", "value": "555-123-4567", "context": "John mentioned 'you can reach me at 555-123-4567'", "timestamp": "01:23"},
          {"field": "company", "value": "Acme Corp", "context": "Sarah said she just joined Acme Corp", "timestamp": "05:47"}
        ]

        ONLY return valid JSON, no other text.

        Meeting transcript:
        #{meeting_prompt}
        """

        case call_gemini(prompt) do
          {:ok, response} ->
            parse_hubspot_suggestions(response)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl SocialScribe.AIContentGeneratorApi
  def generate_salesforce_suggestions(meeting) do
    generate_salesforce_suggestions(meeting, [])
  end

  @impl SocialScribe.AIContentGeneratorApi
  def generate_salesforce_suggestions(meeting, custom_fields) when is_list(custom_fields) do
    case Meetings.generate_prompt_for_meeting(meeting) do
      {:error, reason} ->
        {:error, reason}

      {:ok, meeting_prompt} ->
        custom_field_lines =
          custom_fields
          |> Enum.map(fn field ->
            name = Map.get(field, :name) || Map.get(field, "name")
            label = Map.get(field, :label) || Map.get(field, "label") || name
            "- #{name} (#{label})"
          end)
          |> Enum.join("\n")

        custom_field_instructions =
          if custom_field_lines == "" do
            "No custom Salesforce Contact fields were provided."
          else
            """
            Additional custom Contact fields available in this org:
            #{custom_field_lines}
            """
          end

        prompt = """
        You are an AI assistant that extracts Salesforce Contact field updates from meeting transcripts.

        Analyze the transcript and extract updates for Salesforce Contact fields only.

        Allowed fields:
        - firstname
        - lastname
        - email
        - phone
        - mobilephone
        - title
        - department
        - mailingstreet
        - mailingcity
        - mailingstate
        - mailingpostalcode
        - mailingcountry
        - plus any custom Contact API field names provided below (usually ending in __c)

        #{custom_field_instructions}

        IMPORTANT:
        - Only extract values that are explicitly stated in the transcript.
        - Do not infer, normalize, or guess values.
        - Ignore company/account level updates.
        - Use lowercase standard field keys above for standard fields.
        - Use exact API names (case-sensitive) for custom fields.
        - The "field" is the Salesforce field identifier. The "value" is the actual transcript value to write into Salesforce.
        - Never repeat a field name, API name, or label in "value" unless the speaker literally said that exact text.
        - For custom fields, choose the correct field identifier, then return the spoken number/text as "value".
        - For money/numeric values, NEVER split one spoken amount into multiple suggestions.
        - If the speaker says one amount (for example "four hundred and twelve thousand dollars"), return exactly ONE value for that field (for example "$412000"), not "$400000" plus "$12000".
        - Do not decompose a single figure into additive parts, components, or ranges unless the speaker explicitly gave multiple distinct amounts.

        Return a JSON array where each object includes:
        - "field": one of the allowed field names above
        - "value": extracted value
        - "context": a short quote showing where this appears
        - "timestamp": MM:SS

        Example:
        [
          {"field": "mobilephone", "value": "8885550000", "context": "My mobile phone is 8885550000", "timestamp": "00:42"},
          {"field": "Account_Value__c", "value": "$137,201.43", "context": "Our account value is now $137,201.43", "timestamp": "05:14"},
          {"field": "Budget__c", "value": "$412000", "context": "Our budget is four hundred and twelve thousand dollars", "timestamp": "08:03"}
        ]

        If no updates are found, return [].
        Return valid JSON only.

        Meeting transcript:
        #{meeting_prompt}
        """

        case call_gemini(prompt) do
          {:ok, response} ->
            parse_salesforce_suggestions(response, custom_fields)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp parse_hubspot_suggestions(response) do
    # Clean up the response - remove markdown code blocks if present
    cleaned =
      response
      |> String.trim()
      |> String.replace(~r/^```json\n?/, "")
      |> String.replace(~r/\n?```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, suggestions} when is_list(suggestions) ->
        formatted =
          suggestions
          |> Enum.filter(&is_map/1)
          |> Enum.map(fn s ->
            %{
              field: s["field"],
              value: s["value"],
              context: s["context"],
              timestamp: s["timestamp"]
            }
          end)
          |> Enum.filter(fn s -> s.field != nil and s.value != nil end)

        {:ok, formatted}

      {:ok, _} ->
        {:ok, []}

      {:error, _} ->
        # If JSON parsing fails, return empty suggestions
        {:ok, []}
    end
  end

  defp parse_salesforce_suggestions(response, custom_fields) do
    cleaned =
      response
      |> String.trim()
      |> String.replace(~r/^```json\n?/, "")
      |> String.replace(~r/\n?```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, suggestions} when is_list(suggestions) ->
        standard_fields = [
          "firstname",
          "lastname",
          "email",
          "phone",
          "mobilephone",
          "title",
          "department",
          "mailingstreet",
          "mailingcity",
          "mailingstate",
          "mailingpostalcode",
          "mailingcountry"
        ]

        custom_field_names =
          Enum.map(custom_fields, fn field ->
            Map.get(field, :name) || Map.get(field, "name")
          end)
          |> Enum.filter(&is_binary/1)

        allowed_fields = MapSet.new(standard_fields ++ custom_field_names)

        formatted =
          suggestions
          |> Enum.filter(&is_map/1)
          |> Enum.map(fn s ->
            %{
              field: s["field"],
              value: s["value"],
              context: s["context"],
              timestamp: s["timestamp"]
            }
          end)
          |> Enum.filter(fn s ->
            s.field != nil and s.value != nil and MapSet.member?(allowed_fields, s.field)
          end)

        {:ok, formatted}

      {:ok, _} ->
        {:ok, []}

      {:error, _} ->
        {:ok, []}
    end
  end

  defp call_gemini(prompt_text) do
    api_key = Application.get_env(:social_scribe, :gemini_api_key)
    model = Application.get_env(:social_scribe, :gemini_model, @default_gemini_model)

    if is_nil(api_key) or api_key == "" do
      {:error, {:config_error, "Gemini API key is missing - set GEMINI_API_KEY env var"}}
    else
      path = "/#{model}:generateContent?key=#{api_key}"

      payload = %{
        contents: [
          %{
            parts: [%{text: prompt_text}]
          }
        ]
      }

      case Tesla.post(client(), path, payload) do
        {:ok, %Tesla.Env{status: 200, body: body}} ->
          text_path = [
            "candidates",
            Access.at(0),
            "content",
            "parts",
            Access.at(0),
            "text"
          ]

          case get_in(body, text_path) do
            nil -> {:error, {:parsing_error, "No text content found in Gemini response", body}}
            text_content -> {:ok, text_content}
          end

        {:ok, %Tesla.Env{status: status, body: error_body}} ->
          {:error, {:api_error, status, error_body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end
  end

  defp client do
    Tesla.client([
      {Tesla.Middleware.BaseUrl, @gemini_api_base_url},
      Tesla.Middleware.JSON
    ])
  end
end
