defmodule Camelot.Agents.ModelLabel do
  @moduledoc """
  Humanizes a raw model id (as configured in `Agent.available_models`)
  into a readable dropdown label, keeping the id itself as the value
  submitted to the form/select.
  """

  @known_upcase ~w(gpt)

  @spec humanize(String.t()) :: String.t()
  def humanize(model_id) when is_binary(model_id) do
    model_id
    |> String.split("-")
    |> Enum.map_join(" ", &capitalize_part/1)
  end

  defp capitalize_part(part) do
    case Integer.parse(part) do
      {_, ""} -> part
      _ -> word_case(part)
    end
  end

  defp word_case(part) do
    if String.downcase(part) in @known_upcase do
      String.upcase(part)
    else
      String.capitalize(part)
    end
  end
end
