defmodule CamelotWeb.Components.MembersEditor do
  @moduledoc """
  Lists a project's `Camelot.Projects.Membership` rows and, when
  `can_invite?`, lets an admin or the project's owner add a new
  member by email — existing or brand-new — via `Membership.:invite`.

      <.live_component
        module={CamelotWeb.Components.MembersEditor}
        id="project-members"
        project_id={@project.id}
        current_user={@current_user}
        can_invite?={@can_invite?}
      />
  """
  use CamelotWeb, :live_component

  alias Camelot.Projects.Membership

  require Ash.Query

  @roles [:member, :owner]

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(memberships: list_memberships(assigns.project_id), roles: @roles)
     |> assign_new(:form, fn -> to_form(blank_params()) end)
     |> assign_new(:error, fn -> nil end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-4">
      <h2 class="text-lg font-semibold">Team</h2>

      <.table id={"members-#{@id}"} rows={@memberships}>
        <:col :let={membership} label="Email">
          {membership.user.email}
          <span :if={membership.user_id == @current_user.id} class="badge badge-ghost">
            you
          </span>
        </:col>
        <:col :let={membership} label="Role">
          {membership.role}
        </:col>
      </.table>

      <.simple_form
        :if={@can_invite?}
        for={@form}
        id={"invite-form-#{@id}"}
        phx-submit="invite_member"
        phx-target={@myself}
      >
        <p :if={@error} class="text-sm text-error">{@error}</p>

        <div class="flex flex-wrap gap-3 items-end">
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            placeholder="teammate@example.com"
          />
          <.input field={@form[:role]} type="select" label="Role" options={@roles} />
          <.button phx-disable-with="Inviting..." class="btn btn-primary btn-sm">
            Invite
          </.button>
        </div>
      </.simple_form>
    </section>
    """
  end

  @impl true
  def handle_event("invite_member", %{"email" => email, "role" => role}, socket) do
    actor = socket.assigns.current_user

    attrs = %{
      project_id: socket.assigns.project_id,
      email: email,
      role: parse_role(role)
    }

    Membership
    |> Ash.Changeset.for_create(:invite, attrs, actor: actor)
    |> Ash.create()
    |> case do
      {:ok, _membership} ->
        {:noreply,
         assign(socket,
           memberships: list_memberships(socket.assigns.project_id),
           form: to_form(blank_params()),
           error: nil
         )}

      {:error, error} ->
        {:noreply, assign(socket, error: format_error(error))}
    end
  end

  defp parse_role("owner"), do: :owner
  defp parse_role(_), do: :member

  defp format_error(%Ash.Error.Invalid{errors: [%{message: msg} | _]}) when is_binary(msg), do: msg
  defp format_error(_), do: "Could not invite that user."

  defp list_memberships(project_id) do
    Membership
    |> Ash.Query.filter(project_id == ^project_id)
    |> Ash.Query.load(:user)
    |> Ash.Query.sort(:role)
    |> Ash.read!(authorize?: false)
  end

  defp blank_params, do: %{"email" => "", "role" => "member"}
end
