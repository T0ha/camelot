import {test, describe} from "node:test"
import assert from "node:assert/strict"

import {
  EXCEPTION_CAPTURE,
  buildPostHogOptions,
  createOutageThrottle,
  liveViewErrorProperties,
  wrapHooks,
} from "./posthog_options.mjs"

describe("buildPostHogOptions", () => {
  const config = {apiKey: "phc_test", apiHost: "https://eu.i.posthog.com"}

  test("keeps the existing host, profile and pageview options", () => {
    const options = buildPostHogOptions(config, {autoPageview: false})

    assert.equal(options.api_host, "https://eu.i.posthog.com")
    assert.equal(options.person_profiles, "identified_only")
    assert.equal(options.capture_pageview, false)
    assert.equal(
      buildPostHogOptions(config, {autoPageview: true}).capture_pageview,
      true,
    )
  })

  test("turns on errors, rejections and console errors explicitly", () => {
    assert.deepEqual(
      buildPostHogOptions(config, {autoPageview: false}).capture_exceptions,
      {
        capture_unhandled_errors: true,
        capture_unhandled_rejections: true,
        capture_console_errors: true,
      },
    )
    assert.deepEqual(EXCEPTION_CAPTURE, {
      capture_unhandled_errors: true,
      capture_unhandled_rejections: true,
      capture_console_errors: true,
    })
  })

  test("records console logs and masks inputs in session replay", () => {
    const options = buildPostHogOptions(config, {autoPageview: false})

    assert.equal(options.enable_recording_console_log, true)
    assert.deepEqual(options.session_recording, {maskAllInputs: true})
  })

  test("never puts the api key into the options", () => {
    const options = buildPostHogOptions(config, {autoPageview: false})

    assert.ok(!Object.values(options).includes("phc_test"))
  })
})

describe("liveViewErrorProperties", () => {
  test("keeps the error kind, a string reason and the path", () => {
    const detail = {
      kind: "error",
      errorKind: "server",
      unstructuredError: {reason: "join crashed"},
    }

    assert.deepEqual(liveViewErrorProperties(detail, "/tasks/1"), {
      error_kind: "server",
      reason: "join crashed",
      path: "/tasks/1",
    })
  })

  test("reads a join error's top-level reason", () => {
    assert.equal(
      liveViewErrorProperties({errorKind: "client", reason: "timeout"}, "/")
        .reason,
      "timeout",
    )
  })

  test("drops a reason that is not a string", () => {
    const detail = {errorKind: "client", unstructuredError: {reason: {a: 1}}}

    assert.equal(liveViewErrorProperties(detail, "/").reason, undefined)
  })

  test("falls back to an unknown kind", () => {
    assert.equal(liveViewErrorProperties(undefined, "/").error_kind, "unknown")
  })
})

describe("createOutageThrottle", () => {
  const clock = start => {
    let time = start
    return {now: () => time, advance: ms => (time += ms)}
  }

  test("reports the first error of an outage only", () => {
    const {now} = clock(0)
    const throttle = createOutageThrottle({intervalMs: 1000, now})

    assert.equal(throttle.shouldReport(), true)
    assert.equal(throttle.shouldReport(), false)
    assert.equal(throttle.shouldReport(), false)
  })

  test("reports again once the page has recovered", () => {
    const time = clock(0)
    const throttle = createOutageThrottle({intervalMs: 1000, now: time.now})

    assert.equal(throttle.shouldReport(), true)
    throttle.recover()
    time.advance(1000)
    assert.equal(throttle.shouldReport(), true)
  })

  test("stays quiet on a crash loop faster than the interval", () => {
    const time = clock(0)
    const throttle = createOutageThrottle({intervalMs: 1000, now: time.now})

    assert.equal(throttle.shouldReport(), true)
    throttle.recover()
    time.advance(10)
    assert.equal(throttle.shouldReport(), false)

    // Still the same outage, even after the interval has passed.
    time.advance(5000)
    assert.equal(throttle.shouldReport(), false)
  })
})

describe("wrapHooks", () => {
  test("reports a throwing callback with the hook and callback name", () => {
    const reports = []
    const error = new Error("boom")
    const hooks = wrapHooks(
      {Broken: {mounted() { throw error }}},
      (reported, properties) => reports.push([reported, properties]),
    )

    assert.doesNotThrow(() => hooks.Broken.mounted.call({}))
    assert.deepEqual(reports, [
      [error, {liveview_hook: "Broken", liveview_callback: "mounted"}],
    ])
  })

  test("keeps `this` and return values of a working callback", () => {
    const hooks = wrapHooks(
      {Fine: {updated() { return this.el }, helper: 42}},
      () => assert.fail("nothing should be reported"),
    )

    assert.equal(hooks.Fine.updated.call({el: "el"}), "el")
    assert.equal(hooks.Fine.helper, 42)
  })

  test("leaves class-based hooks alone", () => {
    class Hook {}
    const hooks = wrapHooks({Classy: Hook}, () => {})

    assert.equal(hooks.Classy, Hook)
  })
})
