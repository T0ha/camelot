defmodule Camelot.Runtime.Runner.RegistryClient do
  @moduledoc """
  Resolves the current digest an image tag points to by
  querying its OCI registry directly over HTTPS.

  We cannot lean on the Docker daemon for this: the app talks
  to Docker through a socket-proxy that only exposes
  `/services`, `/tasks` and `POST`, and — unlike the `docker`
  CLI — the raw `POST /services/{id}/update` API does **not**
  re-resolve a bare tag to a digest. So to pick up a freshly
  published image under a floating tag we ask the registry
  ourselves and send Swarm a fully digest-pinned reference.

  Implements the standard token flow: an unauthenticated
  `GET /v2/<repo>/manifests/<ref>` answered with `401` carries a
  `WWW-Authenticate: Bearer realm=…,service=…,scope=…`
  challenge; we fetch a bearer token from `realm` and retry. The
  returned `Docker-Content-Digest` is the manifest-list/index
  digest — exactly what Swarm pins into a service spec.

  Anonymous pulls only (the runner image is public); a private
  registry would need credentials threaded into the token
  request, which is out of scope here.
  """

  alias Camelot.Runtime.Runner.ImageRef

  require Logger

  @default_registry "registry-1.docker.io"

  # Accept both OCI and Docker media types, indexes and single
  # manifests, so the registry answers with a digest for any of them.
  @manifest_accept Enum.join(
                     [
                       "application/vnd.oci.image.index.v1+json",
                       "application/vnd.docker.distribution.manifest.list.v2+json",
                       "application/vnd.oci.image.manifest.v1+json",
                       "application/vnd.docker.distribution.manifest.v2+json"
                     ],
                     ", "
                   )

  @timeout_ms 8_000

  @doc """
  The digest the image's tag currently resolves to, e.g.
  `{:ok, "sha256:a745…"}`. `{:error, reason}` on any network or
  registry failure — callers treat it as "leave the service as
  is".
  """
  @spec current_digest(String.t()) :: {:ok, String.t()} | {:error, term()}
  def current_digest(image) when is_binary(image) do
    %{name: name, tag: tag} = ImageRef.parse(image)
    {host, repo} = split_host_repo(name)
    url = "https://#{host}/v2/#{repo}/manifests/#{tag || "latest"}"
    fetch_digest(url)
  end

  @doc """
  The image reference to actually run: a floating tag (`latest` or no
  tag) resolved to `name:tag@sha256:…`, anything already pinned left
  untouched.

  Used both when a task service is created and by the boot sweep, so a
  service starts life on an explicit digest — otherwise the daemon
  stores the bare tag verbatim, the sweep sees "no digest" on the next
  boot, and the container is rolled even though the image never moved.

  Best-effort: a registry that is unreachable or answers with an error
  yields the original reference, exactly as before this resolution
  existed. `resolver` exists so the decision can be tested without a
  registry.
  """
  @spec pinned_ref(String.t() | nil, (String.t() -> {:ok, String.t()} | {:error, term()})) ::
          String.t() | nil
  def pinned_ref(image, resolver \\ &current_digest/1)

  def pinned_ref(nil, _resolver), do: nil

  def pinned_ref(image, resolver) when is_binary(image) do
    if ImageRef.floating?(image) do
      resolve_or_keep(image, resolver)
    else
      image
    end
  end

  defp resolve_or_keep(image, resolver) do
    case resolver.(image) do
      {:ok, digest} ->
        ImageRef.pin(image, digest)

      {:error, reason} ->
        Logger.warning(
          "RegistryClient: could not resolve #{image} to a digest " <>
            "(#{inspect(reason)}); using the floating tag"
        )

        image
    end
  end

  defp fetch_digest(url) do
    case manifest_request(url, []) do
      {:ok, %Req.Response{status: 200} = resp} -> digest_header(resp)
      {:ok, %Req.Response{status: 401} = resp} -> authenticated_fetch(url, resp)
      {:ok, %Req.Response{status: status}} -> {:error, {:manifest_status, status}}
      {:error, _} = err -> err
    end
  end

  defp authenticated_fetch(url, challenge_resp) do
    with {:ok, token} <- token_from_challenge(challenge_resp),
         {:ok, %Req.Response{status: 200} = resp} <-
           manifest_request(url, [{"authorization", "Bearer #{token}"}]) do
      digest_header(resp)
    else
      {:ok, %Req.Response{status: status}} -> {:error, {:manifest_status, status}}
      {:error, _} = err -> err
    end
  end

  defp manifest_request(url, extra_headers) do
    Req.get(url,
      headers: [{"accept", @manifest_accept} | extra_headers],
      decode_body: false,
      retry: false,
      receive_timeout: @timeout_ms
    )
  end

  defp digest_header(%Req.Response{} = resp) do
    case Req.Response.get_header(resp, "docker-content-digest") do
      [digest | _] -> {:ok, digest}
      _ -> {:error, :no_digest_header}
    end
  end

  defp token_from_challenge(%Req.Response{} = resp) do
    with [header | _] <- Req.Response.get_header(resp, "www-authenticate"),
         %{"realm" => realm} = params <- parse_bearer_challenge(header) do
      request_token(realm, params)
    else
      _ -> {:error, :unparseable_challenge}
    end
  end

  defp request_token(realm, params) do
    query = Map.take(params, ["service", "scope"])

    case Req.get(realm, params: query, retry: false, receive_timeout: @timeout_ms) do
      {:ok, %Req.Response{status: 200, body: %{"token" => token}}} -> {:ok, token}
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token}}} -> {:ok, token}
      {:ok, %Req.Response{status: status}} -> {:error, {:token_status, status}}
      {:error, _} = err -> err
    end
  end

  @doc false
  # Public only so the challenge parsing can be asserted on in
  # tests. Turns `Bearer realm="…",service="…",scope="…"` into a
  # map of its key="value" pairs.
  @spec parse_bearer_challenge(String.t()) :: %{optional(String.t()) => String.t()}
  def parse_bearer_challenge(header) when is_binary(header) do
    ~r/(\w+)="([^"]*)"/
    |> Regex.scan(header)
    |> Map.new(fn [_, k, v] -> {k, v} end)
  end

  @doc false
  # Public only for tests. Splits an image name into its registry
  # host and repository path. A first segment that looks like a host
  # (contains `.` or `:`, or is `localhost`) is the registry;
  # otherwise the default registry is assumed and a bare name is
  # prefixed with `library/` (Docker Hub convention).
  @spec split_host_repo(String.t()) :: {String.t(), String.t()}
  def split_host_repo(name) when is_binary(name) do
    case String.split(name, "/", parts: 2) do
      [maybe_host, repo] -> host_or_default(maybe_host, repo, name)
      [single] -> {@default_registry, "library/#{single}"}
    end
  end

  defp host_or_default(maybe_host, repo, name) do
    if registry_host?(maybe_host) do
      {maybe_host, repo}
    else
      {@default_registry, name}
    end
  end

  defp registry_host?(segment) do
    String.contains?(segment, ".") or String.contains?(segment, ":") or segment == "localhost"
  end
end
