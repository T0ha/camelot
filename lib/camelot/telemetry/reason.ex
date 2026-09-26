defmodule Camelot.Telemetry.Reason do
  @moduledoc """
  Turns error terms into a **bounded** `{reason, http_status}` pair.

  Product analytics needs failure branches it can group by, and an
  `inspect/1` string is unbounded cardinality: one PostHog property
  value per failing changeset. Every error shape this application can
  produce is therefore folded onto one of `t:reason/0` here, and
  anything unrecognised becomes `:unknown` rather than leaking a
  string. The same pair feeds `Logger` metadata, so an event and its
  log line agree on the cause.
  """

  @typedoc "Bounded failure causes reported to PostHog and the logs."
  @type reason ::
          :missing_state
          | :not_authenticated
          | :actor_mismatch
          | :invalid_state
          | :expired_state
          | :invalid_installation_id
          | :not_configured
          | :no_installation
          | :repo_not_in_installation
          | :not_found
          | :forbidden
          | :rate_limited
          | :http_error
          | :transport_error
          | :upsert_failed
          | :link_failed
          | :invalid_json
          | :invalid_integer
          | :unknown

  @typedoc "A classified failure: its cause and, for HTTP, the status."
  @type t :: {reason(), non_neg_integer() | nil}

  @known [
    :missing_state,
    :not_authenticated,
    :actor_mismatch,
    :invalid_installation_id,
    :not_configured,
    :no_installation,
    :repo_not_in_installation,
    :not_found,
    :forbidden,
    :rate_limited,
    :upsert_failed,
    :link_failed,
    :invalid_json,
    :invalid_integer
  ]

  @doc "Every reason `classify/1` can return."
  @spec reasons() :: [reason()]
  def reasons do
    @known ++ [:invalid_state, :expired_state, :http_error, :transport_error, :unknown]
  end

  @doc """
  Classifies an error term into `{reason, http_status}`.

  HTTP failures keep their status, and the statuses that mean
  something specific to a user (404/403/401/429) get their own reason
  so "the repo isn't in your installation" is distinguishable from
  "GitHub is down".
  """
  @spec classify(term()) :: t()
  def classify({:error, reason}), do: classify(reason)
  def classify({:http_error, status, _body}), do: {http_reason(status), status}
  def classify({:upsert_failed, _reason}), do: {:upsert_failed, nil}
  def classify({:link_failed, _reason}), do: {:link_failed, nil}
  def classify(%Req.TransportError{}), do: {:transport_error, nil}
  def classify(%Req.Response{status: status}), do: {http_reason(status), status}
  def classify(:invalid), do: {:invalid_state, nil}
  def classify(:expired), do: {:expired_state, nil}

  def classify(reason) when reason in @known, do: {reason, nil}

  def classify(_reason), do: {:unknown, nil}

  @doc """
  Summarises validation errors as the form fields that failed and the
  short names of the error types — never their messages, which embed
  user input.
  """
  @spec changeset_summary(term()) :: %{
          error_fields: [String.t()],
          error_codes: [String.t()]
        }
  def changeset_summary(error) do
    errors = collect_errors(error)

    %{
      error_fields: errors |> Enum.flat_map(&error_fields/1) |> uniq_sorted(),
      error_codes: errors |> Enum.map(&error_code/1) |> uniq_sorted()
    }
  end

  @spec http_reason(non_neg_integer()) :: reason()
  defp http_reason(404), do: :not_found
  defp http_reason(403), do: :forbidden
  defp http_reason(401), do: :forbidden
  defp http_reason(429), do: :rate_limited
  defp http_reason(_status), do: :http_error

  defp collect_errors(%{errors: errors}) when is_list(errors), do: errors
  defp collect_errors(errors) when is_list(errors), do: errors

  defp collect_errors(error) do
    case Ash.Error.to_error_class(error) do
      %{errors: errors} when is_list(errors) -> errors
      _other -> []
    end
  end

  defp error_fields(%{fields: fields}) when is_list(fields) and fields != [] do
    Enum.map(fields, &to_string/1)
  end

  defp error_fields(%{field: field}) when not is_nil(field), do: [to_string(field)]
  defp error_fields(_error), do: []

  # `Ash.Error.Changes.Required` → "required": the struct name is a
  # stable, bounded label; the message is not.
  defp error_code(%module{}) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp error_code(_error), do: "unknown"

  defp uniq_sorted(values), do: values |> Enum.uniq() |> Enum.sort()
end
