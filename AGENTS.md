This is a web application built with Phoenix, Ash Framework, and PostgreSQL.

## Technology Stack

| Layer | Library |
|-------|---------|
| Data | Ash |
| Database | Ecto + AshPostgres + PostgreSQL |
| Web | AshPhoenix |
| Caching | Nebulex |
| Background jobs | AshOban |
| HTTP client | Req |
| JSON | Jason |
| Observability | OpenTelemetry |
| Metrics | Telemetry |
| Testing | ExUnit |
| Test coverage | Excoveralls |
| AI tooling | Tidewave (MCP dev server), AshAI |
| Linting | Credo, Styler |
| Static analysis | Dialyxir |
| Dep usage checks | usage_rules |

### Prohibited Libraries

- HTTPoison, Tesla, Mint — use Req
- Poison — use Jason
- Cachex — use Nebulex

## Coding Style

Follow the [Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide) and [OTP design principles](https://www.erlang.org/doc/system/design_principles.html).

- Use `with` for handling multiple operations that may fail
- Use pipe operator (`|>`) for chaining
- Prefer simple functions with pattern matching over complex ones
- Limit line length to 80 characters
- Prefer `case` statements for multi-branch conditionals
- Always create typespecs for public functions but avoid `any()` and `term()` types when possible
- Use descriptive function names with `?` suffix for boolean functions
- Use `@doc` and `@moduledoc` for inline documentation
- Put all `.md` files except `README` and `AGENTS` in `docs/` folder

## Feature Implementation Flow

1. Plan the feature and ask for feedback
2. Create a new branch from `main` for the feature
3. Implement tests first (TDD) and ask for approval
4. Implement the feature code
5. Make sure code is compilable by `mix compile` and has no warnings
6. Run all tests with `mix test` and ensure they pass
7. Make sure code runs in `iex -S mix phx.server` without errors
8. Check with `mix dialyzer` for type issues
9. Update documentation and AGENTS.md if needed
10. Run `mix format` to ensure code style compliance
11. Create a pull request and ask for review
12. Address any feedback from the review

## Project Guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included `:req` (`Req`) library for HTTP requests

### Phoenix v1.8 Guidelines

- **Always** begin LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file
- Fix `current_scope` errors by moving routes to the proper `live_session` and passing `current_scope` as needed
- Phoenix v1.8 moved `<.flash_group>` to the `Layouts` module — **never** call it outside `layouts.ex`
- **Always** use the `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for icons
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex`

### JS and CSS Guidelines

- Use Tailwind CSS v4 with the new import syntax in `app.css` (no `tailwind.config.js` needed)
- **Never** use `@apply` when writing raw CSS
- Only `app.js` and `app.css` bundles are supported — import vendor deps, never use external `src`/`href`
- **Never** write inline `<script>` tags within templates

<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir Guidelines

- Elixir lists **do not support index based access** — use `Enum.at`, pattern matching, or `List`
- You *must* bind the result of block expressions (`if`, `case`, `cond`) to a variable
- **Never** nest multiple modules in the same file
- **Never** use map access syntax (`changeset[:field]`) on structs — use `my_struct.field` or higher level APIs like `Ecto.Changeset.get_field/2`
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should end in `?` — reserve `is_` prefix for guards
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure (usually with `timeout: :infinity`)

## Mix Guidelines

- Read the docs before using tasks (`mix help task_name`)
- Debug test failures with `mix test test/my_test.exs` or `mix test --failed`
- `mix deps.clean --all` is **almost never needed**

## Test Guidelines

- **Always** use `start_supervised!/1` to start processes in tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests — use `Process.monitor/1` and assert on `DOWN` messages, or `:sys.get_state/1` to synchronize
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix Guidelines

- Remember `scope` blocks include an optional alias prefixed for all routes — be mindful to avoid duplicate module prefixes
- `Phoenix.View` is no longer included — don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload associations in queries when accessed in templates
- Remember `import Ecto.Query` in `seeds.exs`
- `Ecto.Schema` fields use `:string` type even for `:text` columns
- `Ecto.Changeset.validate_number/2` does not support `:allow_nil`
- Use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields set programmatically (e.g., `user_id`) must not be in `cast` calls
- **Always** use `mix ecto.gen.migration migration_name` to generate migrations
<!-- phoenix:ecto-end -->

<!-- phoenix:html-start -->
## Phoenix HTML Guidelines

- **Always** use `~H` or `.html.heex` files — **never** `~E`
- **Always** use `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` — **never** `Phoenix.HTML.form_for`
- **Always** use `to_form/2` for forms and access via `@form[:field]`
- **Always** add unique DOM IDs to key elements
- **Never** use `else if` or `elsif` — use `cond` or `case`
- Use `phx-no-curly-interpolation` for literal curly braces in HEEx
- HEEx class attrs: **always** use list `[...]` syntax for conditional classes
- **Never** use `<% Enum.each %>` — use `<%= for item <- @collection do %>`
- HEEx comments: `<%!-- comment --%>`
- Use `{...}` for attribute interpolation, `<%= ... %>` for block constructs in tag bodies
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView Guidelines

- **Never** use deprecated `live_redirect`/`live_patch` — use `<.link navigate={href}>` and `push_navigate`/`push_patch`
- **Avoid** LiveComponents unless strongly needed
- Name LiveViews with `Live` suffix (e.g., `AppWeb.WeatherLive`)

### LiveView Streams

- **Always** use streams for collections to avoid memory ballooning
- Set `phx-update="stream"` on the parent element with a DOM id
- Streams are not enumerable — refetch and re-stream with `reset: true` to filter
- Track counts via separate assigns; use Tailwind `hidden only:block` for empty states
- Re-stream items when updating assigns that affect streamed content
- **Never** use deprecated `phx-update="append"` or `phx-update="prepend"`

### LiveView JavaScript Interop

- Set `phx-update="ignore"` when a JS hook manages its own DOM
- **Always** provide a unique DOM id alongside `phx-hook`
- Use colocated JS hooks (`:type={Phoenix.LiveView.ColocatedHook}`) inside templates — names **must** start with `.`
- External hooks go in `assets/js/` and are passed to the `LiveSocket` constructor
- Use `push_event/3` to push events to client hooks; always return/rebind the socket

### LiveView Tests

- Use `Phoenix.LiveViewTest` and `LazyHTML` for assertions
- Drive form tests with `render_submit/2` and `render_change/2`
- **Always** reference key element IDs in tests — **never** test against raw HTML
- Test outcomes, not implementation details

### Form Handling

- **Always** use `to_form/2` assigned in the LiveView and `<.form for={@form}>` in the template
- **Never** pass a changeset directly to `<.form>` or access it in templates
- **Never** use `<.form let={f} ...>` — use `<.form for={@form} ...>`
<!-- phoenix:liveview-end -->

<!-- usage-rules-end -->
