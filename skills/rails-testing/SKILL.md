---
name: rails-testing
description: Apply Rails testing standards with Minitest, fixtures, and pragmatic coverage boundaries. Use when creating tests, reviewing test quality, or improving flaky and slow Rails test suites.
disable-model-invocation: true
---

# Rails Testing

Use for test-writing and test-review tasks. Patterns from Campfire and Fizzy test suites.

## Defaults

- Minitest + fixtures. No RSpec, no FactoryBot.
- Test behavior, not implementation details.
- Keep tests deterministic and fast; `parallelize(workers: :number_of_processors)`.
- Tests ship in the same commit/PR as the feature — not before, not later. Security fixes always include a regression test.
- Never add production complexity for testability (no test-induced design damage).

## Coverage Budget (where 37signals actually spends)

- **Heavy:** model tests (domain invariants, concerns) and controller/integration tests (full request cycle, auth, formats).
- **Light:** a few system tests for the critical happy paths (one smoke test can cover signup→use); job tests only for jobs with real logic.
- **None:** view tests, JS/Stimulus unit tests, exhaustive channel tests. UI behavior is covered indirectly by system tests.
- Don't duplicate the same behavior assertion at multiple layers.

**The budget is also the default seam list.** A seam is the public boundary a test observes without reaching inside. In Rails these are fixed by convention, so a test-first workflow need not re-negotiate them per test: model public methods and scopes (domain invariants), controller/integration requests (status, redirect, format, auth), and one system smoke path per critical flow. Ask only when a test would sit somewhere else (a private method, a view, a job's `perform`), since that is where the budget says not to spend.

**Run the right command for the layer.** `bin/rails test` runs everything *except* system tests (the task is described as "Run all tests in test folder except system ones"); system tests need `bin/rails test:system`. Changing a view, Turbo frame/stream, or Stimulus controller means running both. A passing `bin/rails test` says nothing about them.

## Fixtures

- Express relationships by label, not ID; use ERB for relative timestamps (`created_at: <%= 1.hour.ago %>`) and shared computed values (one bcrypt digest reused).
- Mirror `app/models` structure in `test/models`: `app/models/card/closeable.rb` ↔ `test/models/card/closeable_test.rb`; shared concerns under `test/models/concerns/`.
- UUID PKs break fixture ordering: generate deterministic, label-derived UUIDv7s in fixtures so `.first`/`.last` are stable and runtime records are always newer.
- Build rich-content fixtures with production code (`ActionText::Attachment.from_attachable(user).to_html`), not hand-written markup.

## Good Practices

- Use system/integration tests for user workflows; model tests for domain invariants.
- `travel_to` for time-based logic.
- Mock/stub only at boundaries (external APIs, network, time, `SecureRandom`); use VCR for external HTTP — auto-name cassettes from class+test name, normalize timestamps in matching.
- Test async side effects from model tests with `perform_enqueued_jobs(only: SpecificJob)` and `assert_enqueued_with` — not by unit-testing trivial job classes.
- Correlated count changes in one assertion: `assert_difference({ -> { card.assignees.count } => -1, -> { Event.count } => +1 })`.
- Test both response formats where controllers serve them: `as: :turbo_stream` (assert stream targets) and `as: :json` (status, Location header, body).
- Turbo/broadcast assertions by layer: `assert_turbo_stream_broadcasts` in model tests, `assert_turbo_stream action:, target:` in controller tests, `assert_no_turbo_stream_broadcasts` for negatives.
- Authorization tests assert the negative space: cross-tenant/role access returns 403/404, not just that allowed access works.
- Multi-tenant suites: set `Current.account` (and `Current.session` when behavior depends on the actor) in setup; integration/system tests set `default_url_options[:script_name]`; provide an `untenanted { }` helper for auth routes. Clear `Current` in teardown.
- Test middleware in isolation with `Rack::MockRequest`.
- System tests: `using_session("Kevin")` for multi-user scenarios; wait for cable connection before asserting realtime; auth via a fast session-transfer helper, keeping the full login flow to one smoke test.
- Suites with non-transactional side effects (FTS tables) opt out per-helper: `self.use_transactional_tests = false` + explicit cleanup.
- Reset shared global state per test in parallel suites (thread pools, `ActionCable.server.pubsub`, `Current`).

## Red Flags

- Adding production complexity only for testability.
- Over-mocking internal app code.
- Duplicate tests for the same behavior at multiple layers.
- Slow suites caused by unnecessary setup in each test (that's what fixtures are for).
- Unit tests for one-line job classes or trivial delegations.
- Hand-rolled HTML strings where production renderers/helpers would stay in sync automatically.
- Time-dependent assertions without `travel_to`.
