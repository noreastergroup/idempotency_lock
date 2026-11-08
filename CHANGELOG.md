## [Unreleased]

### Upgrading

- **Run the upgrade migration before deploying:** `rails generate idempotency_lock:upgrade && rails db:migrate`
  (adds the `owner_token` column).
- Minimum supported ActiveRecord / ActiveSupport is now **7.1** (7.0 is end-of-life).
- Invalid arguments now raise `ArgumentError` instead of being silently accepted
  (see "Fixed" below).

### Fixed

- **A process could release a lock it no longer held.** If a lock's TTL lapsed
  mid-block and another process claimed it, the original holder's release
  (`temporarily`'s auto-release, or `once` with `:unlock` / `:raise` / a callable)
  deleted the new holder's lock, allowing concurrent execution. Locks now carry
  a random owner token and releases only delete the caller's own lock.
- Invalid lock names (`nil`, blank, non-String/Symbol, or over 255 characters)
  were reported as `skipped?` without running the block. They now raise
  `ArgumentError`.
- An unknown `on_error` value (e.g. a typo like `:unlok`) silently kept the lock.
  It now raises `ArgumentError`. Invalid `ttl:` and `wait:` values also raise.
- Non-`StandardError` exceptions (`Interrupt`, `SignalException`,
  `Sidekiq::Shutdown`, ...) bypassed `on_error`, leaving the lock held even with
  `:unlock`. The lock is now released for every strategy except `:keep`.
- A lock conflict that reached the database (two callers racing on a new name)
  inside a caller's transaction aborted that transaction on PostgreSQL
  (`PG::InFailedSqlTransaction`). Acquisition now runs in a savepoint.
- `IdempotencyLock.logger = nil` was ignored in Rails apps (it fell back to
  `Rails.logger`), and the lookup crashed when `Rails` was defined without a
  `logger` method.
- Fractional `ttl:` values were truncated to whole seconds.

### Changed

- Requiring the gem no longer loads `ActiveRecord::Base` eagerly; the model is
  autoloaded on first use, so host-app ActiveRecord configuration is respected.
  The gem now requires `active_record` / `active_support` itself.
- Expired-lock claims use the owner token (instead of `updated_at`) as the
  optimistic-lock version, avoiding timestamp-precision edge cases.
- `Lock.acquire` returns the owner token (or `nil`) instead of `true`/`false`;
  `Lock.release` accepts an optional `owner_token:`. Truthiness is unchanged.
- Dropped the `uniqueness` validation on `Lock#name`; the unique index already
  enforces it, saving a `SELECT` per acquisition.
- `Result#inspect` shows the class of the value rather than its contents, to
  avoid leaking sensitive data into logs and error trackers.
- `temporarily` wait loop uses a monotonic clock.
- The Railtie no longer overwrites a configured logger.

### Added

- `on_error:` for `temporarily` (`:raise` or a callable).
- `rails generate idempotency_lock:upgrade` generator.
- `on_error:` accepts any object responding to `call`, not only Procs.
- RBS signatures for the public API.
- CI: Ruby 3.2–3.4 × ActiveRecord 7.1–8.1, plus PostgreSQL and MySQL jobs;
  read-only token permissions and SHA-pinned actions.

### Documentation

- Clarified that `once` is *at most once*, not exactly once, and documented
  error-swallowing, interrupt, transaction, and clock-skew behavior.
- Fixed the Sidekiq example (it used `:unlock`, which swallows the error so
  Sidekiq never retries) and the webhook example (now verifies the signature
  before taking a lock). Added a Security Considerations section.

## [0.2.0] - 2026-01-24

### Added

- `IdempotencyLock.temporarily` - Execute a block with an ephemeral lock that is
  automatically released when the block completes (success or error)
- `wait:` parameter for `temporarily` - Poll for lock availability with configurable
  timeout (e.g., `wait: 5.seconds`)

## [0.1.3] - 2025-12-06

### Changed

- Use `updated_at` instead of `expires_at` for optimistic locking (more reliable
  since it's system-managed and always moves forward)

## [0.1.2] - 2025-12-06

### Fixed

- Migration now works with MySQL (uses regular index instead of partial index,
  which MySQL doesn't support)

### Added

- `Result#inspect` for easier debugging

## [0.1.1] - 2025-12-06

### Fixed

- Use optimistic locking when claiming expired locks to prevent race conditions
  where two processes with clock skew could both claim the same lock

### Changed

- `now` parameter is now injectable in `Lock.acquire`, `expired?`, and `valid_lock?` for testing

## [0.1.0] - 2025-12-06

### Added

- `IdempotencyLock.once` - Execute a block exactly once per lock name
- `Result` object with `executed?`, `skipped?`, `success?`, `error?`, and `value` methods
- TTL/expiration support via `ttl:` option (accepts ActiveSupport durations or seconds)
- Multiple error handling strategies via `on_error:` option:
  - `:keep` (default) - keep lock on error
  - `:unlock` - release lock to allow retry
  - `:raise` - re-raise exception after releasing lock
  - `Proc` - custom error handler
- `IdempotencyLock.locked?` - Check if an operation is locked
- `IdempotencyLock.release` - Manually release a lock
- `IdempotencyLock.cleanup_expired` - Remove all expired locks
- Rails generator: `rails generate idempotency_lock:install`
- `wrap` alias for `once` method
