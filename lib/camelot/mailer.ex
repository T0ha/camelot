defmodule Camelot.Mailer do
  @moduledoc false
  use Swoosh.Mailer, otp_app: :camelot

  @spec from() :: {String.t(), String.t()}
  def from do
    config = Application.fetch_env!(:camelot, :mail)
    {Keyword.fetch!(config, :from_name), Keyword.fetch!(config, :from_address)}
  end
end
