defmodule CamelotWeb.Onboarding.Status do
  @moduledoc """
  A snapshot of how far a user has got through first-login
  setup.

  `steps` is an order-preserving keyword list of
  `{step, done?}` pairs — the order is the order the guide
  walks the user through. Steps that don't apply to the
  deployment (the GitHub one, when no GitHub App is
  configured) are simply absent, so `complete?` and the
  "N of M" counter need no special-casing.

  The struct carries keys and booleans only. Labels, icons
  and routes live in `CamelotWeb.OnboardingComponents`.
  """

  @typedoc "One checklist step of the first-login setup guide."
  @type step :: :github | :claude_token | :project | :task

  @type t :: %__MODULE__{
          steps: [{step(), boolean()}],
          complete?: boolean(),
          next: step() | nil
        }

  defstruct steps: [], complete?: false, next: nil

  @doc """
  Builds a status from an ordered `{step, done?}` list.
  """
  @spec new([{step(), boolean()}]) :: t()
  def new(steps) do
    %__MODULE__{
      steps: steps,
      complete?: Enum.all?(steps, &done?/1),
      next: next(steps)
    }
  end

  @doc "How many steps of the guide are already done."
  @spec done_count(t()) :: non_neg_integer()
  def done_count(%__MODULE__{steps: steps}), do: Enum.count(steps, &done?/1)

  @doc "How many steps this deployment asks the user for."
  @spec total_count(t()) :: non_neg_integer()
  def total_count(%__MODULE__{steps: steps}), do: length(steps)

  @doc """
  Whether `step` is still outstanding. An absent step counts
  as done — the deployment never asks for it.
  """
  @spec pending?(t(), step()) :: boolean()
  def pending?(%__MODULE__{steps: steps}, step) do
    Keyword.get(steps, step, true) == false
  end

  defp done?({_step, done?}), do: done?

  defp next(steps) do
    case Enum.find(steps, &(not done?(&1))) do
      {step, _done?} -> step
      nil -> nil
    end
  end
end
