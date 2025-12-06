# IdempotencyLock

A simple, robust idempotency solution for Ruby on Rails applications. Ensures operations run exactly once using database-backed locks with support for TTL expiration, multiple error handling strategies, and clean return value handling.

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

# TTL also accepts integer seconds
IdempotencyLock.once("periodic-task", ttl: 3600) do
  some_periodic_work
end
```

### Error Handling

Control what happens when an error occurs inside the block:

```ruby
# :keep (default) - Keep the lock, don't allow retry
IdempotencyLock.once("risky-op", on_error: :keep) do
  might_fail
end

# :unlock - Release the lock so another process can retry
IdempotencyLock.once("retriable-op", on_error: :unlock) do
  external_api_call
end

# :raise - Re-raise the exception after releasing the lock
IdempotencyLock.once("critical-op", on_error: :raise) do
  must_succeed_or_alert
end

# Custom handler with a Proc
IdempotencyLock.once("custom-error", on_error: ->(e) { Bugsnag.notify(e) }) do
  something_important
end
```

### Manual Lock Management

```ruby
# Check if an operation is locked
IdempotencyLock.locked?("my-operation")  # => true/false

# Release a lock manually (useful for testing or manual intervention)
IdempotencyLock.release("my-operation")

# Clean up all expired locks (good for a periodic job)
IdempotencyLock.cleanup_expired
```

### Alias

The `wrap` method is available as an alias for `once`:

```ruby
IdempotencyLock.wrap("operation-name") { do_something }
```

## Use Cases

### Preventing Duplicate Webhook Processing

```ruby
class WebhooksController < ApplicationController
  def stripe
    event_id = params[:id]
    
    result = IdempotencyLock.once("stripe-webhook-#{event_id}") do
      StripeWebhookProcessor.process(params)
    end
    
    head :ok
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
    IdempotencyLock.once("important-job-#{record_id}", on_error: :unlock) do
      # If this fails, another job can retry
      ImportantService.process(record_id)
    end
  end
end
```

## Database Schema

The gem creates an `idempotency_locks` table with:

| Column | Type | Description |
|--------|------|-------------|
| `name` | string (max 255) | Unique identifier for the lock |
| `expires_at` | datetime | When the lock expires (null = never) |
| `executed_at` | datetime | When the operation was executed |
| `created_at` | datetime | Standard Rails timestamp |
| `updated_at` | datetime | Standard Rails timestamp |

Indexes:
- Unique index on `name` (provides atomicity)
- Index on `expires_at` (partial index on PostgreSQL/SQLite, regular index on MySQL)

**Note on name length:** Lock names are limited to 255 characters to ensure compatibility with database unique index limits. MySQL users with `utf8mb4` encoding may need to reduce this to 191 characters by modifying the migration before running it.

## How It Works

1. **Lock Acquisition**: Attempts to create a record with the given name. The unique index ensures only one process succeeds.

2. **TTL Support**: If a TTL is provided, the lock includes an `expires_at` timestamp. Expired locks can be claimed by new operations via an atomic UPDATE.

3. **Error Handling**: Different strategies control whether the lock is released on error, allowing for retry semantics.

4. **Return Values**: The block's return value is captured and returned in the `Result` object.

## Thread Safety

The gem relies on database-level uniqueness constraints for atomicity. This means:

- ✅ Safe across multiple processes (web servers, job workers)
- ✅ Safe across multiple machines
- ✅ Safe in multi-threaded environments
- ✅ Survives application restarts

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests.

## Contributing

Bug reports and pull requests are welcome on GitHub.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
