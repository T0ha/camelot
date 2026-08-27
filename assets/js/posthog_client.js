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

  if (posthogConfig.distinctId) {
    posthog.identify(posthogConfig.distinctId, {email: posthogConfig.email})
  }

  window.posthog = posthog

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
