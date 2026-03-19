defmodule Camelot.Repo.Migrations.AddErrorMessageToSessions do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add(:error_message, :text)
    end
  end
end
