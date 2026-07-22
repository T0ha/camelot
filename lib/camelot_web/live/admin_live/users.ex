defmodule CamelotWeb.AdminLive.Users do
  @moduledoc """
  Admin-only view for listing users and adding new ones with a role.
  Mounted via `:live_admin_required` which gates access to admins.
  """
  use CamelotWeb, :live_view

  alias Camelot.Accounts.User
  alias Camelot.Runtime.Runner.DockerApi
  alias Phoenix.LiveView.Socket

  require Ash.Query

  @roles [:admin, :user]

  @impl true
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(node_labels: DockerApi.list_node_labels_or_empty()) |> load()}
  end

  @impl true
  def handle_event("create_user", %{"user" => params}, socket) do
    actor = socket.assigns.current_user

    attrs = %{
      email: params["email"],
      role: parse_role(params["role"])
    }

    User
    |> Ash.Changeset.for_create(:create_user, attrs, actor: actor)
    |> Ash.create()
    |> case do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Added #{user.role} #{user.email}")
         |> load()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_error(error))}
    end
  end

  def handle_event("set_role", %{"user" => %{"id" => id, "role" => role}}, socket) do
    actor = socket.assigns.current_user

    if id == actor.id do
      {:noreply, put_flash(socket, :error, "You can't change your own role.")}
    else
      User
      |> Ash.get!(id, actor: actor)
      |> Ash.Changeset.for_update(:set_role, %{role: parse_role(role)}, actor: actor)
      |> Ash.update()
      |> case do
        {:ok, user} ->
          {:noreply,
           socket
           |> put_flash(:info, "#{user.email} is now #{user.role}")
           |> load()}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, format_error(error))}
      end
    end
  end

  def handle_event("set_node_label", %{"node" => %{"id" => id, "swarm_node_label" => label}}, socket) do
    actor = socket.assigns.current_user

    User
    |> Ash.get!(id, actor: actor)
    |> Ash.Changeset.for_update(
      :set_swarm_node_label,
      %{swarm_node_label: blank_to_nil(label)},
      actor: actor
    )
    |> Ash.update()
    |> case do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{user.email} pinned to #{user.swarm_node_label || "no node"}")
         |> load()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_error(error))}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp node_pin_class([]), do: "input input-bordered input-sm w-32"
  defp node_pin_class(_node_labels), do: "select select-bordered select-sm w-32"

  defp load(socket) do
    users =
      User
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(actor: socket.assigns.current_user)

    assign(socket,
      page_title: "Users",
      users: users,
      roles: @roles,
      user_form: empty_form()
    )
  end

  defp empty_form do
    to_form(%{"email" => "", "role" => "user"}, as: "user")
  end

  defp parse_role("admin"), do: :admin
  defp parse_role(_), do: :user

  defp format_error(%Ash.Error.Invalid{errors: [%{message: msg} | _]}) when is_binary(msg), do: msg

  defp format_error(_), do: "Could not save changes."

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-bold">Users</h1>

      <section class="rounded border p-4 space-y-3">
        <h2 class="text-lg font-semibold">Add user</h2>

        <p class="text-sm text-base-content/60">
          The new user gets an invitation email at this address and can
          sign in themselves with a magic link whenever they're ready.
        </p>

        <.form
          for={@user_form}
          phx-submit="create_user"
          class="flex flex-wrap items-end gap-2"
        >
          <div class="flex-1 min-w-[16rem]">
            <label class="label text-sm font-medium" for="user_email">Email</label>
            <input
              type="email"
              name="user[email]"
              id="user_email"
              required
              autocomplete="off"
              class="input input-bordered w-full"
            />
          </div>

          <div>
            <label class="label text-sm font-medium" for="user_role">Role</label>
            <select name="user[role]" id="user_role" class="select select-bordered">
              <option :for={r <- @roles} value={r}>{r}</option>
            </select>
          </div>

          <button type="submit" class="btn btn-primary">Add user</button>
        </.form>
      </section>

      <section class="rounded border p-4 space-y-3">
        <h2 class="text-lg font-semibold">Existing users</h2>

        <table class="w-full text-sm">
          <thead>
            <tr class="text-left">
              <th class="py-1">Email</th>
              <th class="py-1">Role</th>
              <th class="py-1">Node pin</th>
              <th class="py-1">Confirmed</th>
              <th class="py-1">Added</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={u <- @users} class="border-t" id={"user-#{u.id}"}>
              <td class="py-2">{u.email}</td>
              <td class="py-2">
                <span :if={u.id == @current_user.id} title="You can't change your own role">
                  {u.role}
                </span>
                <form :if={u.id != @current_user.id} phx-change="set_role">
                  <input type="hidden" name="user[id]" value={u.id} />
                  <select
                    name="user[role]"
                    class="select select-bordered select-sm"
                  >
                    <option :for={r <- @roles} value={r} selected={u.role == r}>
                      {r}
                    </option>
                  </select>
                </form>
              </td>
              <td class="py-2">
                <form phx-change="set_node_label">
                  <input type="hidden" name="node[id]" value={u.id} />
                  <.node_label_pin
                    name="node[swarm_node_label]"
                    value={u.swarm_node_label}
                    node_labels={@node_labels}
                    class={node_pin_class(@node_labels)}
                  />
                </form>
              </td>
              <td class="py-2">
                <span :if={u.confirmed_at}>
                  {Calendar.strftime(u.confirmed_at, "%Y-%m-%d")}
                </span>
                <span :if={is_nil(u.confirmed_at)} class="text-base-content/60">
                  pending
                </span>
              </td>
              <td class="py-2">{Calendar.strftime(u.inserted_at, "%Y-%m-%d")}</td>
            </tr>
          </tbody>
        </table>
      </section>
    </div>
    """
  end
end
