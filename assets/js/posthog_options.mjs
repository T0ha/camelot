// Pure pieces of the PostHog browser setup: no DOM, no posthog-js
// import, so `node --test` can load them without a browser.

// Explicit rather than left to the project's remote toggles: with
// `capture_exceptions` unset, posthog-js only autocaptures exceptions
// when the PostHog project happens to have it switched on, and never
// console errors. The object form is the only way to get
// `console.error` too, which is how LiveView reports its own failures
// (an unknown hook, a hook that failed to construct, a bad patch).
export const EXCEPTION_CAPTURE = {
  capture_unhandled_errors: true,
  capture_unhandled_rejections: true,
  capture_console_errors: true,
}

// posthog-js init options for the `#posthog-config` dataset.
//
// Session replay itself stays a project setting — it records only
// when the PostHog project has replay enabled — but when it does, the
// console panel is populated and typed input never leaves the browser.
export function buildPostHogOptions(config, {autoPageview}) {
  return {
    api_host: config.apiHost,
    person_profiles: "identified_only",
    capture_pageview: autoPageview,
    capture_exceptions: EXCEPTION_CAPTURE,
    enable_recording_console_log: true,
    session_recording: {maskAllInputs: true},
  }
}

// Properties of a `liveview_error` capture for the detail of a
// `phx:page-loading-start{kind: "error"}`. LiveView dispatches that
// when the main view crashes or cannot join — `errorKind` is "server"
// while the socket is up, "client" when the connection itself is gone.
// Only a string reason is kept: anything else is an arbitrary server
// payload, not a bounded value.
export function liveViewErrorProperties(detail, path) {
  const reason = detail?.unstructuredError?.reason ?? detail?.reason

  return {
    error_kind: detail?.errorKind ?? "unknown",
    reason: typeof reason === "string" ? reason : undefined,
    path,
  }
}

// A dropped connection fires `phx:page-loading-start{kind: "error"}`
// on every reconnect attempt, and a crashing view on every rejoin. One
// outage is one event: after reporting, stay quiet until the page has
// loaded again (`recover`), and even then report at most once per
// `intervalMs`, so a view stuck in a crash loop cannot flood PostHog.
export function createOutageThrottle({intervalMs, now = () => Date.now()}) {
  let inOutage = false
  let lastReportedAt = -Infinity

  return {
    shouldReport() {
      if (inOutage || now() - lastReportedAt < intervalMs) {
        inOutage = true
        return false
      }

      inOutage = true
      lastReportedAt = now()
      return true
    },

    recover() {
      inOutage = false
    },
  }
}

// Wraps every lifecycle callback of each LiveView hook so an error
// thrown inside one is reported with the hook it came from — an
// uncaught error from a hook otherwise reaches PostHog as a bare
// stack with no hint of which hook or callback threw. The error is
// handed to `report` instead of rethrown, so a broken hook no longer
// aborts the rest of the DOM patch it was called from.
export const HOOK_CALLBACKS = [
  "mounted",
  "beforeUpdate",
  "updated",
  "destroyed",
  "disconnected",
  "reconnected",
]

export function wrapHooks(hooks, report) {
  return Object.fromEntries(
    Object.entries(hooks).map(([name, hook]) => [name, wrapHook(name, hook, report)]),
  )
}

// A class-based hook (`class extends ViewHook`) keeps its callbacks on
// the prototype, which a spread would drop; it is left as it is and
// its errors reach PostHog through exception autocapture instead.
function wrapHook(name, hook, report) {
  if (typeof hook === "function") {
    return hook
  }

  const wrapped = {...hook}

  HOOK_CALLBACKS
    .filter(callback => typeof hook[callback] === "function")
    .forEach(callback => {
      const original = hook[callback]

      wrapped[callback] = function(...args) {
        try {
          return original.apply(this, args)
        } catch (error) {
          report(error, {liveview_hook: name, liveview_callback: callback})
        }
      }
    })

  return wrapped
}
