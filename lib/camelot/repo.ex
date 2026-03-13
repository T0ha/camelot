defmodule Camelot.Repo do
  use Ecto.Repo,
    otp_app: :camelot,
    adapter: Ecto.Adapters.Postgres
end
