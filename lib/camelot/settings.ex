defmodule Camelot.Settings do
  @moduledoc """
  Domain for instance-wide configuration.
  """
  use Ash.Domain

  alias Camelot.Settings.SystemSetting

  resources do
    resource(SystemSetting)
  end

  @doc """
  Reads the global default swarm node pin, or `nil` when no
  admin has set one yet (or the singleton row does not exist).
  """
  @spec default_swarm_node_label() :: String.t() | nil
  def default_swarm_node_label do
    case Ash.read_one(SystemSetting, authorize?: false) do
      {:ok, %{default_swarm_node_label: label}} -> label
      _ -> nil
    end
  end
end
