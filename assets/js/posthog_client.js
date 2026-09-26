import posthog from "posthog-js"

// PostHog browser tracking. Only initialized when the server rendered a
// config (i.e. POSTHOG_API_KEY is set) — pages without it make no
// PostHog network calls at all.
export function initPostHog({autoPageview}) {
  const posthogConfig = document.getElementById("posthog-config")?.dataset

  if (!posthogConfig?.apiKey) {
    return
  }

  posthog.init(posthogConfig.apiKey, {
    api_host: posthogConfig.apiHost,
    person_profiles: "identified_only",
    capture_pageview: autoPageview,
  })

  // Super-properties, so autocaptured events — $pageview and the
  // $exception volume nothing else tags — carry the same environment
  // and internal-traffic flags the server puts on its own captures.
  // Without these, prod and the test cluster are indistinguishable in
  // a shared PostHog project.
  posthog.register({
    environment: posthogConfig.environment,
    is_internal: posthogConfig.isInternal === "true",
  })

  if (posthogConfig.distinctId) {
    posthog.identify(posthogConfig.distinctId, {
      email: posthogConfig.email,
      environment: posthogConfig.environment,
      is_internal: posthogConfig.isInternal === "true",
    })
  }

  window.posthog = posthog

  // LiveViews push this to attach page-scoped context (a task id, say)
  // to everything captured while that page is open, including
  // autocaptured exceptions. Cleared on navigation by the next page's
  // own registration.
  window.addEventListener("phx:posthog:register", event => {
    window.posthog?.register(event.detail || {})
  })

  if (autoPageview) {
    return
  }

  posthog.capture("$pageview")

  // The first phx:page-loading-stop corresponds to the page already
  // captured above, so skip double-counting it.
  let skipNextPageviewCapture = true

  window.addEventListener("phx:page-loading-stop", _info => {
    if (skipNextPageviewCapture) {
      skipNextPageviewCapture = false
    } else {
      window.posthog?.capture("$pageview")
    }
  })
}
