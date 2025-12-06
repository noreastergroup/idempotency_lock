## [Unreleased]

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
