defmodule Camelot.Repo.Migrations.AddRetryFields do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add(:max_retries, :integer, default: 3, null: false)
    end

    alter table(:sessions) do
      add(:retry_number, :integer, default: 0, null: false)
    end
  end
end
