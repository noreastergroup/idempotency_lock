## [Unreleased]

## [0.2.0] - 2025-01-24

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
