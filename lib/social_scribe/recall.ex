defmodule SocialScribe.Recall do
  @moduledoc "The real implementation for the Recall.ai API client."
  @behaviour SocialScribe.RecallApi

  defp client do
    api_key = Application.fetch_env!(:social_scribe, :recall_api_key)
    recall_region = Application.fetch_env!(:social_scribe, :recall_region)

    Tesla.client([
      {Tesla.Middleware.BaseUrl, "https://#{recall_region}.recall.ai/api/v1"},
      {Tesla.Middleware.JSON, engine_opts: [keys: :atoms]},
      {Tesla.Middleware.Headers,
       [
         {"Authorization", "Token #{api_key}"},
         {"Content-Type", "application/json"},
         {"Accept", "application/json"}
       ]}
    ])
  end

  @impl SocialScribe.RecallApi
  def create_bot(meeting_url, join_at) do
    body = %{
      meeting_url: meeting_url,
      bot_name: "Social Scribe Bot",
      join_at: Timex.format!(join_at, "{ISO:Extended}"),
      recording_config: %{
        transcript: %{
          provider: %{
            meeting_captions: %{}
          }
        }
      }
    }

    Tesla.post(client(), "/bot", body)
  end

  @impl SocialScribe.RecallApi
  def update_bot(recall_bot_id, meeting_url, join_at) do
    body = %{
      meeting_url: meeting_url,
      join_at: Timex.format!(join_at, "{ISO:Extended}")
    }

    Tesla.patch(client(), "/bot/#{recall_bot_id}", body)
  end

  @impl SocialScribe.RecallApi
  def delete_bot(recall_bot_id) do
    Tesla.delete(client(), "/bot/#{recall_bot_id}")
  end

  @impl SocialScribe.RecallApi
  def get_bot(recall_bot_id) do
    Tesla.get(client(), "/bot/#{recall_bot_id}")
  end

  @impl SocialScribe.RecallApi
  def get_bot_transcript(recall_bot_id) do
    with {:ok, %{body: bot_info}} <- get_bot(recall_bot_id),
         [%{id: recording_id} | _] <- Map.get(bot_info, :recordings, []),
         {:ok, %{body: recording}} <- get_recording(recording_id),
         url when is_binary(url) <-
           get_in(recording, [:media_shortcuts, :transcript, :data, :download_url]) do
      Tesla.client([{Tesla.Middleware.JSON, engine_opts: [keys: :atoms]}])
      |> Tesla.get(url)
    else
      [] -> {:error, :no_recordings}
      nil -> {:error, :no_transcript_url}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_recording(recording_id) do
    Tesla.get(client(), "/recording/#{recording_id}")
  end

  @impl SocialScribe.RecallApi
  def get_bot_participants(recall_bot_id) do
    with {:ok, %{body: bot_info}} <- get_bot(recall_bot_id),
         [%{id: recording_id} | _] <- Map.get(bot_info, :recordings, []),
         {:ok, %{body: recording}} <- get_recording(recording_id),
         url when is_binary(url) <- get_participants_url(recording) do
      Tesla.client([{Tesla.Middleware.JSON, engine_opts: [keys: :atoms]}])
      |> Tesla.get(url)
    else
      [] -> {:error, :no_recordings}
      nil -> {:error, :no_participants_url}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_participants_url(recording) do
    # Try media_shortcuts first (newer API structure)
    # Fallback to direct participant_events (older structure)
    get_in(recording, [:media_shortcuts, :participant_events, :data, :participants_download_url]) ||
      get_in(recording, [:participant_events, :data, :participants_download_url])
  end
end
