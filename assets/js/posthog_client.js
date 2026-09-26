import posthog from "posthog-js"

// Keys registered for one page only (a task id, say). `posthog.register`
// writes into PostHog's own persistence, which outlives both the page and
// the browser session, so the list of what we put there has to outlive
// this module too — a hard reload elsewhere in the app would otherwise
// keep tagging events with the last task the browser happened to open.
const PAGE_PROPERTIES_KEY = "camelot:posthog:page_properties"

function readPageProperties() {
  try {
    return JSON.parse(window.localStorage.getItem(PAGE_PROPERTIES_KEY)) || []
  } catch (_error) {
    return []
  }
}

function writePageProperties(keys) {
  try {
    window.localStorage.setItem(PAGE_PROPERTIES_KEY, JSON.stringify(keys))
  } catch (_error) {
    // Private mode, quota, no storage at all: page context is a nice to
    // have, never a reason to break the page it describes.
  }
}

function clearPageProperties() {
  readPageProperties().forEach(key => window.posthog?.unregister(key))
  writePageProperties([])
}

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

  window.posthog = posthog

  // Whatever the previous page left behind describes a page that is no
  // longer open, and this load has not been told about a new one yet.
  clearPageProperties()

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

  // A LiveView pushes this to attach its own context — a task id, say —
  // to everything captured while that page is open, autocaptured
  // exceptions included.
  let navigation = 0
  let registeredAt = 0

  window.addEventListener("phx:posthog:register", event => {
    const properties = event.detail || {}

    clearPageProperties()
    posthog.register(properties)
    writePageProperties(Object.keys(properties))
    registeredAt = navigation
  })

  // Leaving the page takes its context off again. A live redirect
  // dispatches phx:navigate *after* the events of the view it navigated
  // to, so "was anything registered since the last navigation?" is what
  // separates the context of the page being left from the context of the
  // page being entered — comparing hrefs would not, and neither order of
  // the two events breaks this one. A patch stays inside the same
  // LiveView, so it leaves the context alone.
  window.addEventListener("phx:navigate", event => {
    if (event.detail?.patch) {
      return
    }

    if (registeredAt !== navigation) {
      clearPageProperties()
    }

    navigation += 1
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
