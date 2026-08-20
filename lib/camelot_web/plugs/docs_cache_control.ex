defmodule CamelotWeb.Plugs.DocsCacheControl do
  @moduledoc """
  Sets long-lived, CDN-friendly cache headers on public docs responses.

  Docs content only changes on deploy, so we let a CDN (CloudFront) cache
  aggressively at the edge while serving stale content during background
  revalidation and origin outages. Paired with the cookie-free `:docs`
  router pipeline so responses stay cacheable.
  """

  import Plug.Conn

  @cache_control "public, max-age=0, s-maxage=86400, " <>
                   "stale-while-revalidate=604800, stale-if-error=86400"

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts), do: put_resp_header(conn, "cache-control", @cache_control)
end
