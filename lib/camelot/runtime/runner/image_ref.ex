defmodule Camelot.Runtime.Runner.ImageRef do
  @moduledoc """
  Pure parsing of an OCI image reference into its
  `name` / `tag` / `digest` parts, plus the two questions
  the auto-update sweep asks of a runner image:

    * `floating?/1` — is the tag one that should track the
      newest published digest (`latest` or no tag), rather
      than a pinned version (`:1.19`) or a digest?
    * `without_digest/1` — the reference with any `@sha256:…`
      stripped, so a `POST /services/{id}/update` sends a bare
      tag and the Swarm daemon re-resolves it to the current
      digest.

  A `:` separates the tag only inside the final path segment,
  so a registry host with a port (`registry:5000/foo/bar`)
  is not mistaken for a tag.
  """

  @type t :: %{name: String.t(), tag: String.t() | nil, digest: String.t() | nil}

  @doc """
  Split an image reference into `%{name:, tag:, digest:}`.

  ## Examples

      iex> Camelot.Runtime.Runner.ImageRef.parse("ghcr.io/acme/runner:latest@sha256:abc")
      %{name: "ghcr.io/acme/runner", tag: "latest", digest: "sha256:abc"}

      iex> Camelot.Runtime.Runner.ImageRef.parse("registry:5000/acme/runner")
      %{name: "registry:5000/acme/runner", tag: nil, digest: nil}
  """
  @spec parse(String.t()) :: t()
  def parse(image) when is_binary(image) do
    {ref, digest} = split_digest(image)
    {name, tag} = split_tag(ref)
    %{name: name, tag: tag, digest: digest}
  end

  @doc """
  Whether the reference tracks a moving target: the `latest`
  tag (Swarm resolves it to a digest, but it is still floating)
  or a bare name with no tag and no digest (implicit `latest`).

  A deliberate pin returns `false`: an explicit version tag
  (`:1.19`) or a digest with no tag (`name@sha256:…`).
  """
  @spec floating?(String.t()) :: boolean()
  def floating?(image) when is_binary(image) do
    case parse(image) do
      %{tag: "latest"} -> true
      %{tag: nil, digest: nil} -> true
      _ -> false
    end
  end

  @doc """
  The reference with any `@digest` removed — `name` or
  `name:tag`. Sending this bare form back on a service update
  makes the daemon re-resolve the tag to the current digest.
  """
  @spec without_digest(String.t()) :: String.t()
  def without_digest(image) when is_binary(image) do
    {ref, _digest} = split_digest(image)
    ref
  end

  @doc """
  The reference pinned to `digest` — its current tag (if any) is
  kept and any prior digest replaced. This is the fully-resolved
  form (`name:tag@sha256:…`) sent to Swarm so every node runs the
  exact image.

  ## Examples

      iex> Camelot.Runtime.Runner.ImageRef.pin("ghcr.io/acme/runner:latest@sha256:old", "sha256:new")
      "ghcr.io/acme/runner:latest@sha256:new"
  """
  @spec pin(String.t(), String.t()) :: String.t()
  def pin(image, digest) when is_binary(image) and is_binary(digest) do
    without_digest(image) <> "@" <> digest
  end

  defp split_digest(image) do
    case String.split(image, "@", parts: 2) do
      [ref, digest] -> {ref, digest}
      [ref] -> {ref, nil}
    end
  end

  # A colon is a tag separator only in the last `/`-segment;
  # anything earlier (a registry `host:port`) stays in the name.
  defp split_tag(ref) do
    last = ref |> String.split("/") |> List.last()

    case String.split(last, ":", parts: 2) do
      [_name_part, tag] -> {String.replace_suffix(ref, ":" <> tag, ""), tag}
      [_name_part] -> {ref, nil}
    end
  end
end
