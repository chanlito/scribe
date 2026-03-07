defmodule SocialScribe.Repo.Migrations.AddMetadataToUserCredentials do
  use Ecto.Migration

  def change do
    alter table(:user_credentials) do
      add :metadata, :map
    end
  end
end
