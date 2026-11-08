# IdempotencyLock

A simple, robust idempotency solution for Ruby on Rails applications. Guarantees an operation runs **at most once** per lock name (or once per TTL window) across processes and machines, using database-backed locks with support for TTL expiration, multiple error handling strategies, and clean return value handling.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "idempotency_lock"
```

Then execute:

```bash
bundle install
```

Generate the migration:

```bash
rails generate idempotency_lock:install
rails db:migrate
```

Requires Ruby 3.2+ and Rails / ActiveRecord 7.1+. Tested on SQLite, PostgreSQL, and MySQL.

### Upgrading from 0.2.x or earlier

Version 0.3.0 adds an `owner_token` column. Generate and run the upgrade migration **before** deploying 0.3.0:

```bash
rails generate idempotency_lock:upgrade
rails db:migrate
```

## Usage

### Basic Usage

Wrap any operation that should only run once:

```ruby
result = IdempotencyLock.once("send-welcome-email-user-#{user.id}") do
  UserMailer.welcome(user).deliver_now
end

if result.executed?
  puts "Email sent!"
else
  puts "Email already sent (skipped)"
end
```

The `once` method returns a `Result` object that tells you what happened:

```ruby
result.executed?  # true if the block ran
result.skipped?   # true if skipped due to existing lock
result.success?   # true if executed without error
result.error?     # true if an error occurred
result.value      # the return value of the block
result.error      # the exception if one was raised
```

### At-most-once semantics

The lock is taken **before** the block runs. That makes `once` *at most once*, not *exactly once*:

- If the block raises, `on_error` decides whether the lock is kept (no retry) or released (retry allowed). See [Error Handling](#error-handling).
- If the process dies mid-block (crash, `kill -9`, OOM), the lock stays in place and the operation will not run again until the lock expires (`ttl:`) or is released manually. Use a `ttl:` if you would rather risk a second run than never finishing.

Lock names must be non-blank Strings or Symbols of at most 255 characters; anything else raises `ArgumentError`.

### TTL / Expiration

Sometimes you want "run once per hour" instead of "run once forever":

```ruby
# Run daily report once per day
IdempotencyLock.once("daily-report", ttl: 24.hours) do
  ReportGenerator.daily_summary
end

# Run cleanup once per hour
IdempotencyLock.once("hourly-cleanup", ttl: 1.hour) do
  TempFile.cleanup_old
end

# TTL also accepts seconds
IdempotencyLock.once("periodic-task", ttl: 3600) do
  some_periodic_work
end
```

Expiry is checked against the clock of the server doing the check, so keep server clocks synchronized (NTP). Clock skew can shorten or lengthen a TTL window: a server whose clock runs ahead can see a lock as expired, and take it over, while the previous holder is still running. Pick TTLs with a margin well above your expected clock drift. (When several callers race to claim the *same* expired lock, the owner-token check still guarantees only one succeeds.)

### Temporary Locks (Auto-Release)

Use `temporarily` when you want exclusive execution but don't need permanent idempotency. The lock is released when the block finishes, whether it succeeds, raises, or exits early:

```ruby
IdempotencyLock.temporarily("process-payment-#{payment.id}", ttl: 5.minutes) do
  PaymentProcessor.charge(payment)
end
# Lock is now released - another call can acquire it
```

This is useful for:
- Preventing concurrent processing of the same resource
- Mutex-style synchronization across processes/servers
- Operations that should be exclusive but retriable

#### Always set a TTL

> **Without `ttl:`, a lock held by a process that is killed (SIGKILL, OOM, host failure) is never released**, and every later call is skipped until you run `IdempotencyLock.release(name)`.

Set `ttl:` comfortably longer than the block's worst-case runtime. If the block outlives its TTL, another process may acquire the lock and run concurrently. The original holder will not release the new holder's lock when it finishes.

#### Waiting for Lock Availability

By default, `temporarily` returns immediately if the lock is held. Use `wait:` to poll until the lock becomes available:

```ruby
# Wait up to 5 seconds for lock, then skip if still unavailable
result = IdempotencyLock.temporarily("exclusive-job", ttl: 10.minutes, wait: 5.seconds) do
  process_job
end

if result.skipped?
  puts "Could not acquire lock within timeout"
end
```

#### Errors in temporary locks

By default an exception raised in the block is captured in the `Result` (`result.error?`) and **not re-raised**. Pass `on_error: :raise` to re-raise it after the lock is released, or a callable to be notified:

```ruby
IdempotencyLock.temporarily("sync-account-#{id}", ttl: 1.minute, on_error: :raise) do
  AccountSync.run(id)
end
```

### Error Handling

Control what happens when the block raises a `StandardError`:

```ruby
# :keep (default) - Keep the lock: the operation will NOT be retried
IdempotencyLock.once("risky-op", on_error: :keep) do
  might_fail
end

# :unlock - Release the lock so a later call can retry
IdempotencyLock.once("retriable-op", on_error: :unlock) do
  external_api_call
end

# :raise - Release the lock, then re-raise the exception
IdempotencyLock.once("critical-op", on_error: :raise) do
  must_succeed_or_alert
end

# Any callable - Release the lock, then call it with the exception
IdempotencyLock.once("custom-error", on_error: ->(e) { Bugsnag.notify(e) }) do
  something_important
end
```

Things to know:

- **Errors are swallowed unless you use `:raise`.** With `:keep`, `:unlock`, or a callable, `once` returns a `Result` with `error?` set and does not raise. In a background job, that means the job framework sees success and **will not retry**. Use `on_error: :raise` when you rely on job retries.
- **The default (`:keep`) means a transient failure permanently suppresses the operation** (or until the TTL expires). Choose `:unlock` / `:raise` if retrying is safe.
- **Interrupts and other non-`StandardError` exceptions** (e.g. `Interrupt`, `SignalException`, `Sidekiq::Shutdown` during a deploy) are always re-raised. The lock is kept for `:keep` and released for every other strategy; callables are not invoked for them.
- **An early `return`/`break`/`next` out of the block counts as success.** The lock is kept.
- An unknown `on_error` value raises `ArgumentError` before anything runs.

### Database Transactions

The lock row is written through the current database connection, so if you call `once` inside a transaction:

- The lock is not visible to other processes until your transaction commits. A concurrent caller blocks on the unique index until then, then skips.
- **If your transaction rolls back, the lock is rolled back too**, even though any side effects (emails sent, APIs called) already happened. Prefer to call `once` outside transactions, or wrap only database work that should roll back together with the lock.

Acquisition uses a savepoint, so a lock conflict never aborts your surrounding transaction (relevant on PostgreSQL).

### Manual Lock Management

```ruby
# Check if an operation is locked
IdempotencyLock.locked?("my-operation")  # => true/false

# Force-release a lock regardless of who holds it
# (useful for testing or manual intervention)
IdempotencyLock.release("my-operation")

# Clean up all expired locks (good for a periodic job)
IdempotencyLock.cleanup_expired
```

Locks without a TTL are never removed by `cleanup_expired`.

### Logging

Logs go to `Rails.logger` by default. To use a different logger, or disable logging:

```ruby
IdempotencyLock.logger = Logger.new($stdout)
IdempotencyLock.logger = nil # disable
```

Lock names and exception messages are logged, so avoid putting secrets or personal data in lock names.

### Alias

The `wrap` method is available as an alias for `once`:

```ruby
IdempotencyLock.wrap("operation-name") { do_something }
```

## Use Cases

### Preventing Duplicate Webhook Processing

Verify the webhook signature **before** taking a lock. Otherwise anyone can send forged requests that claim lock names (and grow the table) for events that never happened.

```ruby
class WebhooksController < ApplicationController
  def stripe
    event = Stripe::Webhook.construct_event(
      request.body.read,
      request.headers["Stripe-Signature"],
      Rails.application.credentials.stripe_webhook_secret
    )

    # Namespace the key; expire it after Stripe's retry window.
    # on_error: :raise releases the lock and returns a 500, so Stripe retries.
    IdempotencyLock.once("stripe-webhook:#{event.id}", ttl: 7.days, on_error: :raise) do
      StripeWebhookProcessor.process(event)
    end

    head :ok
  rescue JSON::ParserError, Stripe::SignatureVerificationError
    head :bad_request
  end
end
```

### Ensuring One-Time Migrations

```ruby
IdempotencyLock.once("backfill-user-preferences-2024-01") do
  User.find_each do |user|
    user.create_preferences! unless user.preferences.present?
  end
end
```

### Rate-Limited Operations

```ruby
# Only send one reminder per user per day
IdempotencyLock.once("reminder-user-#{user.id}", ttl: 24.hours) do
  ReminderMailer.daily_reminder(user).deliver_later
end
```

### Preventing Duplicate Sidekiq Jobs

```ruby
class ImportantJob
  include Sidekiq::Job

  def perform(record_id)
    # :raise releases the lock and re-raises, so Sidekiq's retry runs it again.
    # (With :unlock the error would be swallowed and Sidekiq would never retry.)
    IdempotencyLock.once("important-job-#{record_id}", on_error: :raise) do
      ImportantService.process(record_id)
    end
  end
end
```

### Exclusive Resource Processing

```ruby
# Ensure only one process handles a payment at a time
def process_payment(payment_id)
  IdempotencyLock.temporarily("payment-#{payment_id}", ttl: 5.minutes, wait: 10.seconds) do
    Payment.find(payment_id).process!
  end
end
```

## Security Considerations

- **Lock names derived from user input:** if an attacker can choose lock names, they can claim names in advance to block legitimate operations, or create rows without limit. Authenticate/verify input first (e.g. webhook signatures), namespace names (`"stripe-webhook:#{id}"`), and use a `ttl:` plus a periodic `cleanup_expired` so the table stays bounded.
- **`Result#inspect`** shows only the class of the block's return value, not its contents, so inspecting a result in logs or error trackers does not leak data. `result.value` still holds the real value.
- All queries use bound parameters.

## Database Schema

The gem creates an `idempotency_locks` table with:

| Column | Type | Description |
|--------|------|-------------|
| `name` | string (max 255) | Unique identifier for the lock |
| `owner_token` | string (36) | Random token identifying the current holder |
| `expires_at` | datetime | When the lock expires (null = never) |
| `executed_at` | datetime | When the lock was acquired (i.e. when the block started) |
| `created_at` | datetime | Standard Rails timestamp |
| `updated_at` | datetime | Standard Rails timestamp |

Indexes:
- Unique index on `name` (provides atomicity)
- Index on `expires_at` (partial index on PostgreSQL/SQLite, regular index on MySQL)

**Note on name length:** modern MySQL (InnoDB with the default DYNAMIC row format) can index 255 `utf8mb4` characters. Very old MySQL setups limited to 767-byte index keys need the column reduced to 191 characters in the migration. If you do that, keep your lock names within that length too.

## How It Works

1. **Lock Acquisition**: Inserts a row with the given name and a fresh random owner token. The unique index ensures only one process succeeds. The insert runs in a savepoint so a conflict never breaks a surrounding transaction.

2. **TTL Support**: If a TTL is provided, the lock includes an `expires_at` timestamp. An expired lock is claimed with a conditional `UPDATE ... WHERE owner_token = <observed token>`, so if several processes race to claim the same expired lock, exactly one wins. Whether a lock counts as expired depends on the claiming server's clock (see [TTL / Expiration](#ttl--expiration)).

3. **Owner-Safe Release**: Releases delete the row only if it still carries the releasing process's owner token. A process whose lock expired and was taken over cannot delete the new holder's lock.

4. **Error Handling**: Strategies control whether the lock is released on error, allowing for retry semantics.

5. **Return Values**: The block's return value is captured and returned in the `Result` object.

## Concurrency

The gem relies on database-level uniqueness constraints for atomicity. This means:

- ✅ Safe across multiple processes (web servers, job workers) and machines
- ✅ Safe across threads (each thread uses its own database connection)
- ✅ Survives application restarts
- ⚠️ Mutual exclusion from `temporarily` holds only while the TTL has not expired (as judged by each server's clock), so pick a TTL longer than the block's runtime plus expected clock drift

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then run `rake` to run the tests and RuboCop.

The suite uses SQLite by default. To run it against PostgreSQL or MySQL:

```bash
BUNDLE_WITH=postgres bundle install
BUNDLE_WITH=postgres DATABASE_URL=postgres://user:pass@localhost/idempotency_lock_test bundle exec rake test

BUNDLE_WITH=mysql bundle install
BUNDLE_WITH=mysql DATABASE_URL=mysql2://user:pass@127.0.0.1/idempotency_lock_test bundle exec rake test
```

To test a specific ActiveRecord version, use the gemfiles in `gemfiles/`:

```bash
BUNDLE_GEMFILE=gemfiles/activerecord_7.1.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/activerecord_7.1.gemfile bundle exec rake test
```

## Contributing

Bug reports and pull requests are welcome on GitHub.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
