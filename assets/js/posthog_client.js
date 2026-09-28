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
  window.addEventListener("phx:posthog:register", event => {
    const properties = event.detail || {}

    clearPageProperties()
    posthog.register(properties)
    writePageProperties(Object.keys(properties))
  })

  // Leaving a page takes its context off again. The clear has to land
  // *before* the page being entered mounts, or it wipes the context that
  // page just registered — and phx:navigate is too late for that on a
  // link click or a server push_navigate, where LiveView dispatches it
  // only after the replacement view has joined. The two signals below
  // are both strictly earlier than the new view's mount:
  //
  //   * phx:page-loading-start{kind: "redirect"} — dispatched by
  //     historyRedirect before it swaps the main view;
  //   * phx:navigate{pop: true} — back/forward, dispatched from the
  //     popstate handler before the swap.
  //
  // A patch stays inside the same LiveView, so it leaves context alone.
  window.addEventListener("phx:page-loading-start", event => {
    if (event.detail?.kind === "redirect") {
      clearPageProperties()
    }
  })

  window.addEventListener("phx:navigate", event => {
    if (event.detail?.pop && !event.detail?.patch) {
      clearPageProperties()
    }
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
