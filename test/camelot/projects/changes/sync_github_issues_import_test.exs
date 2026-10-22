defmodule Camelot.Projects.Changes.SyncGithubIssuesImportTest do
  # async: false — installs the GitHub write stub in the global
  # application env.
  use Camelot.DataCase, async: false

  alias Camelot.Accounts.Credential
  alias Camelot.Agents.Agent
  alias Camelot.Board.Task
  alias Camelot.Projects.Changes.SyncGithubIssues
  alias Camelot.Projects.Membership
  alias Camelot.Projects.Project
  alias Camelot.Support.StubPullRequestApi

  require Ash.Query

  @owner_gh 1001
  @member_gh 1002
  @stranger_gh 1003

  setup do
    StubPullRequestApi.install()
    on_exit(&StubPullRequestApi.uninstall/0)

    owner = user!(%{github_user_id: "#{@owner_gh}"})
    member = user!(%{github_user_id: "#{@member_gh}"})
    github_installation!(owner, %{account_login: "acme-org"})

    project =
      Ash.create!(
        Project,
        %{
          name: "sync-#{System.unique_integer([:positive])}",
          path: "/tmp/sync",
          github_owner: "acme-org",
          github_repo: "widgets"
        },
        actor: owner
      )

    Ash.Seed.seed!(Membership, %{project_id: project.id, user_id: member.id, role: :member})

    project =
      Ash.load!(project, [owner_membership: [user: [:github_installations]]], authorize?: false)

    agent = test_agent!("alpha", [:generic])
    credential!(owner, :generic)

    %{project: project, owner: owner, agent: agent}
  end

  defp test_agent!(prefix, kinds) do
    Ash.create!(Agent, %{
      slug: "#{prefix}-#{System.unique_integer([:positive])}",
      name: prefix,
      executable: prefix,
      required_credential_kinds: kinds,
      available_models: ["model-a", "model-b"]
    })
  end

  defp credential!(user, kind) do
    Ash.create!(Credential, %{
      user_id: user.id,
      kind: kind,
      value: "secret-#{System.unique_integer([:positive])}"
    })
  end

  defp issue(labels, attrs \\ %{}) do
    Map.merge(
      %{
        "number" => 42,
        "title" => "Add widgets",
        "body" => "Build the widget page.",
        "user" => %{"id" => @owner_gh, "login" => "owner"},
        "labels" => Enum.map(["camelot" | labels], &%{"name" => &1})
      },
      attrs
    )
  end

  defp labeled(label, actor_id, created_at \\ "2026-10-01T10:00:00Z") do
    %{
      "event" => "labeled",
      "label" => %{"name" => label},
      "actor" => %{"id" => actor_id},
      "created_at" => created_at
    }
  end

  defp events_by(actor_id, labels) do
    Enum.map(["camelot" | labels], &labeled(&1, actor_id))
  end

  defp import!(project, issue, events, reactions \\ []) do
    SyncGithubIssues.import_issue(project, issue, events, reactions)
  end

  describe "import_issue/4 — attach" do
    test "a member's camelot label imports the issue", %{project: project} do
      assert {:ok, task} = import!(project, issue([]), events_by(@member_gh, []))

      assert task.issue_number == 42
      assert task.title == "GH#42: Add widgets"
      assert task.description == "Build the widget page."
      assert task.stage == :todo
    end

    test "a stranger's camelot label is ignored", %{project: project} do
      assert :untrusted = import!(project, issue([]), events_by(@stranger_gh, []))
      assert Ash.read!(Task) == []
    end

    test "a camelot label with no labeled event is ignored", %{project: project} do
      assert :untrusted = import!(project, issue([]), [])
    end

    test "the latest camelot labeled event decides", %{project: project} do
      events = [
        labeled("camelot", @member_gh, "2026-10-01T10:00:00Z"),
        labeled("camelot", @stranger_gh, "2026-10-02T10:00:00Z")
      ]

      assert :untrusted = import!(project, issue([]), events)
    end

    test "falls back to the alphabetically-first agent", %{project: project} do
      assert {:ok, task} = import!(project, issue([]), events_by(@owner_gh, []))

      first =
        Agent
        |> Ash.Query.sort(:slug)
        |> Ash.Query.limit(1)
        |> Ash.read_one!()

      assert task.agent_id == first.id
    end
  end

  describe "import_issue/4 — agent and model labels" do
    test "honours a trusted agent and model label", %{project: project, agent: agent} do
      labels = ["camelot:agent:#{agent.slug}", "camelot:model:model-b"]

      assert {:ok, task} = import!(project, issue(labels), events_by(@member_gh, labels))

      assert task.agent_id == agent.id
      assert task.next_model == "model-b"
    end

    test "ignores an agent label applied by a stranger", %{project: project} do
      # Sorts last, so it can't also be the alphabetical default.
      agent = test_agent!("zzz", [:generic])
      labels = ["camelot:agent:#{agent.slug}"]
      events = [labeled("camelot", @owner_gh), labeled(hd(labels), @stranger_gh)]

      assert {:ok, task} = import!(project, issue(labels), events)
      refute task.agent_id == agent.id
    end

    test "an unknown agent slug comments, labels and creates nothing", %{project: project, agent: agent} do
      labels = ["camelot:agent:nope"]

      assert {:invalid, _problems} = import!(project, issue(labels), events_by(@owner_gh, labels))

      assert_receive {:create_issue_comment, "acme-org", "widgets", 42, body, _opts}
      assert body =~ "nope"
      assert body =~ agent.slug
      assert_receive {:add_issue_labels, "acme-org", "widgets", 42, ["camelot:invalid-config"], _opts}
      assert Ash.read!(Task) == []
    end

    test "an unavailable model comments with the valid model ids", %{project: project, agent: agent} do
      labels = ["camelot:agent:#{agent.slug}", "camelot:model:model-z"]

      assert {:invalid, _} = import!(project, issue(labels), events_by(@owner_gh, labels))

      assert_receive {:create_issue_comment, _, _, 42, body, _opts}
      assert body =~ "model-z"
      assert body =~ "model-a"
      assert body =~ "model-b"
      assert Ash.read!(Task) == []
    end

    test "missing credentials for the agent comment and create nothing", %{project: project} do
      needy = test_agent!("needy", [:openai_api_key])
      labels = ["camelot:agent:#{needy.slug}"]

      assert {:invalid, _} = import!(project, issue(labels), events_by(@owner_gh, labels))

      assert_receive {:create_issue_comment, _, _, 42, body, _opts}
      assert body =~ "openai_api_key"
      assert Ash.read!(Task) == []
    end

    test "an issue already flagged invalid is not commented on again", %{project: project} do
      labels = ["camelot:agent:nope", "camelot:invalid-config"]

      assert {:invalid, _} = import!(project, issue(labels), events_by(@owner_gh, labels))

      refute_receive {:create_issue_comment, _, _, _, _, _}
      refute_receive {:add_issue_labels, _, _, _, _, _}
    end

    test "a fixed issue imports and drops the invalid-config label", %{project: project, agent: agent} do
      labels = ["camelot:agent:#{agent.slug}", "camelot:invalid-config"]

      assert {:ok, _task} = import!(project, issue(labels), events_by(@owner_gh, labels))

      assert_receive {:remove_issue_label, "acme-org", "widgets", 42, "camelot:invalid-config", _opts}
    end
  end

  describe "import_issue/4 — skip planning" do
    test "a trusted skip-plan label starts in executing with the body as plan", %{project: project} do
      labels = ["camelot:skip-plan"]

      assert {:ok, task} = import!(project, issue(labels), events_by(@member_gh, labels))

      assert task.stage == :executing
      assert task.state == :queued
      assert task.plan == "Build the widget page."
    end

    test "a stranger-authored issue is planned despite skip-plan", %{project: project} do
      labels = ["camelot:skip-plan"]
      stranger_issue = issue(labels, %{"user" => %{"id" => @stranger_gh}})

      assert {:ok, task} = import!(project, stranger_issue, events_by(@member_gh, labels))

      assert task.stage == :todo
      assert is_nil(task.plan)
    end

    test "an owner's 👍 on a stranger's issue lets skip-plan through", %{project: project} do
      labels = ["camelot:skip-plan"]
      stranger_issue = issue(labels, %{"user" => %{"id" => @stranger_gh}})
      reactions = [%{"content" => "+1", "user" => %{"id" => @owner_gh}, "created_at" => "2026-10-01T09:00:00Z"}]

      assert {:ok, task} =
               import!(project, stranger_issue, events_by(@member_gh, labels), reactions)

      assert task.stage == :executing
    end

    test "a member's 👍 on a stranger's issue is not enough", %{project: project} do
      labels = ["camelot:skip-plan"]
      stranger_issue = issue(labels, %{"user" => %{"id" => @stranger_gh}})
      reactions = [%{"content" => "+1", "user" => %{"id" => @member_gh}, "created_at" => "2026-10-01T09:00:00Z"}]

      assert {:ok, task} =
               import!(project, stranger_issue, events_by(@member_gh, labels), reactions)

      assert task.stage == :todo
    end
  end

  describe "imported?/2" do
    test "finds a task by project and issue number", %{project: project} do
      assert {:ok, _task} = import!(project, issue([]), events_by(@owner_gh, []))

      assert SyncGithubIssues.imported?(project, issue([]))
      refute SyncGithubIssues.imported?(project, issue([], %{"number" => 43}))
    end

    test "falls back to the legacy title match", %{project: project, owner: owner} do
      Ash.Seed.seed!(Task, %{
        title: "GH#42: Add widgets",
        project_id: project.id,
        creator_id: owner.id,
        stage: :todo,
        state: :queued
      })

      assert SyncGithubIssues.imported?(project, issue([]))
    end
  end
end
