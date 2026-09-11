defmodule Camelot.Runtime.Runner.AdoptPolicyTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.Runner.AdoptPolicy

  doctest AdoptPolicy

  describe "decide/4" do
    # The reconciler adopts a `:running` session after a restart by
    # re-attaching to the still-alive runner container and polling for
    # the exec-wrapper's completion marker. If the container was
    # *replaced* (Swarm reschedule / OOM on a tiny node) after the
    # session's exec began, the marker lived in the prior container's
    # /tmp and can never appear — polling must give up rather than hang
    # forever (the regression that stranded a task in `executing`).
    defp dt(iso), do: elem(DateTime.from_iso8601(iso), 1)

    test "keeps polling while the container predates the session exec" do
      # Container booted before the session started -> same container the
      # exec ran in; its marker is still recoverable.
      container = dt("2026-07-14T10:40:00Z")
      session = dt("2026-07-14T10:44:00Z")

      assert AdoptPolicy.decide(container, session, 0, 900_000) == :poll
    end

    test "gives up when the container was replaced after the session exec" do
      # The actual incident: container rescheduled at 12:47, session exec
      # began at 10:44 -> marker unrecoverable.
      container = dt("2026-07-14T12:47:00Z")
      session = dt("2026-07-14T10:44:00Z")

      assert AdoptPolicy.decide(container, session, 0, 900_000) ==
               {:give_up, :container_replaced}
    end

    test "gives up once the wall-clock budget is exhausted" do
      # Backstop for missing/again-skewed timestamps: never poll forever.
      assert AdoptPolicy.decide(nil, nil, 900_000, 900_000) ==
               {:give_up, :timeout}
    end

    test "polls within budget when timestamps are unavailable" do
      assert AdoptPolicy.decide(nil, nil, 1_000, 900_000) == :poll
    end
  end

  describe "container_replaced?/2" do
    defp t(iso), do: elem(DateTime.from_iso8601(iso), 1)

    test "true when the container started strictly after the session" do
      assert AdoptPolicy.container_replaced?(
               t("2026-07-14T12:47:00Z"),
               t("2026-07-14T10:44:00Z")
             )
    end

    test "false when the container started before the session" do
      refute AdoptPolicy.container_replaced?(
               t("2026-07-14T10:40:00Z"),
               t("2026-07-14T10:44:00Z")
             )
    end

    test "false when either timestamp is missing" do
      refute AdoptPolicy.container_replaced?(nil, t("2026-07-14T10:44:00Z"))
      refute AdoptPolicy.container_replaced?(t("2026-07-14T10:44:00Z"), nil)
    end
  end

  describe "budget_ms/0" do
    test "bounds the poll well above any real re-attach settle time" do
      assert AdoptPolicy.budget_ms() >= 60_000
    end
  end

  describe "reason_message/1" do
    test "explains a replaced container" do
      assert AdoptPolicy.reason_message(:container_replaced) =~ "replaced"
    end

    test "explains an exhausted budget" do
      assert AdoptPolicy.reason_message(:timeout) =~ "budget"
    end
  end
end
