# frozen_string_literal: true

require "test_helper"

class TestIdempotencyLock < Minitest::Test
  include IdempotencyLockTestHelpers

  def test_that_it_has_a_version_number
    refute_nil ::IdempotencyLock::VERSION
  end

  def test_once_executes_block_first_time
    executed = false

    result = IdempotencyLock.once("test-operation") do
      executed = true
      "return value"
    end

    assert executed, "Block should have been executed"
    assert_predicate result, :executed?
    assert_predicate result, :success?
    refute_predicate result, :skipped?
    assert_equal "return value", result.value
  end

  def test_once_skips_on_second_call
    call_count = 0

    IdempotencyLock.once("test-operation") { call_count += 1 }
    result = IdempotencyLock.once("test-operation") { call_count += 1 }

    assert_equal 1, call_count, "Block should only execute once"
    refute_predicate result, :executed?
    assert_predicate result, :skipped?
  end

  def test_different_names_execute_independently
    results = []

    IdempotencyLock.once("operation-a") { results << "a" }
    IdempotencyLock.once("operation-b") { results << "b" }

    assert_equal %w[a b], results
  end

  def test_requires_block
    assert_raises(ArgumentError) do
      IdempotencyLock.once("no-block")
    end
  end

  def test_wrap_alias_works
    executed = false
    IdempotencyLock.wrap("test-wrap") { executed = true }

    assert executed
  end
end

class TestIdempotencyLockTTL < Minitest::Test
  include IdempotencyLockTestHelpers

  def test_ttl_allows_re_execution_after_expiry
    call_count = 0

    # First call with 1-second TTL
    IdempotencyLock.once("ttl-test", ttl: 1) { call_count += 1 }

    assert_equal 1, call_count

    # Immediate second call should be skipped
    result = IdempotencyLock.once("ttl-test", ttl: 1) { call_count += 1 }

    assert_equal 1, call_count
    assert_predicate result, :skipped?

    # Simulate time passing by updating the lock's expires_at
    lock = IdempotencyLock::Lock.find_by(name: "ttl-test")
    lock.update!(expires_at: 2.seconds.ago)

    # Now it should execute again
    result = IdempotencyLock.once("ttl-test", ttl: 1) { call_count += 1 }

    assert_equal 2, call_count
    assert_predicate result, :executed?
  end

  def test_nil_ttl_never_expires
    IdempotencyLock.once("permanent") { "first" }

    lock = IdempotencyLock::Lock.find_by(name: "permanent")

    assert_nil lock.expires_at
    refute_predicate lock, :expired?
    assert_predicate lock, :valid_lock?
  end

  def test_ttl_with_integer_seconds
    IdempotencyLock.once("int-ttl", ttl: 3600) { "hourly" }

    lock = IdempotencyLock::Lock.find_by(name: "int-ttl")

    assert_in_delta Time.current + 3600, lock.expires_at, 5
  end
end

class TestIdempotencyLockErrorHandling < Minitest::Test
  include IdempotencyLockTestHelpers

  def test_on_error_keep_locked_by_default
    result = IdempotencyLock.once("error-keep") do
      raise StandardError, "boom"
    end

    assert_predicate result, :executed?
    assert_predicate result, :error?
    assert_kind_of StandardError, result.error

    # Lock should still exist
    assert IdempotencyLock.locked?("error-keep")
  end

  def test_on_error_unlock
    result = IdempotencyLock.once("error-unlock", on_error: :unlock) do
      raise StandardError, "boom"
    end

    assert_predicate result, :executed?
    assert_predicate result, :error?

    # Lock should be released
    refute IdempotencyLock.locked?("error-unlock")

    # Should be able to retry
    call_count = 0
    IdempotencyLock.once("error-unlock") { call_count += 1 }

    assert_equal 1, call_count
  end

  def test_on_error_raise
    assert_raises(StandardError) do
      IdempotencyLock.once("error-raise", on_error: :raise) do
        raise StandardError, "boom"
      end
    end

    # Lock should be released
    refute IdempotencyLock.locked?("error-raise")
  end

  def test_on_error_with_proc
    captured_error = nil
    handler = ->(e) { captured_error = e }

    result = IdempotencyLock.once("error-proc", on_error: handler) do
      raise StandardError, "custom boom"
    end

    assert_equal "custom boom", captured_error.message
    assert_predicate result, :error?

    # Lock should be released when using proc
    refute IdempotencyLock.locked?("error-proc")
  end
end

class TestIdempotencyLockModel < Minitest::Test
  include IdempotencyLockTestHelpers

  def test_max_name_length_constant
    assert_equal 255, IdempotencyLock::Lock::MAX_NAME_LENGTH
  end

  def test_name_length_validation
    long_name = "a" * 256
    lock = IdempotencyLock::Lock.new(name: long_name, executed_at: Time.current)

    refute_predicate lock, :valid?
    assert_includes lock.errors[:name], "is too long (maximum is 255 characters)"
  end

  def test_lock_acquire_creates_record
    acquired = IdempotencyLock::Lock.acquire("new-lock")

    assert acquired
    assert IdempotencyLock::Lock.exists?(name: "new-lock")
  end

  def test_lock_acquire_fails_for_existing
    IdempotencyLock::Lock.acquire("existing")
    acquired = IdempotencyLock::Lock.acquire("existing")

    refute acquired
    assert_equal 1, IdempotencyLock::Lock.where(name: "existing").count
  end

  def test_lock_acquire_succeeds_for_expired
    IdempotencyLock::Lock.create!(
      name: "expired",
      expires_at: 1.hour.ago,
      executed_at: 2.hours.ago
    )

    acquired = IdempotencyLock::Lock.acquire("expired", expires_at: 1.hour.from_now)

    assert acquired
    lock = IdempotencyLock::Lock.find_by(name: "expired")

    assert_operator lock.expires_at, :>, Time.current
  end

  def test_lock_release
    IdempotencyLock::Lock.acquire("to-release")

    assert IdempotencyLock::Lock.locked?("to-release")

    released = IdempotencyLock::Lock.release("to-release")

    assert released
    refute IdempotencyLock::Lock.locked?("to-release")
  end

  def test_cleanup_expired
    # Create some locks
    IdempotencyLock::Lock.create!(name: "expired-1", expires_at: 1.hour.ago, executed_at: 2.hours.ago)
    IdempotencyLock::Lock.create!(name: "expired-2", expires_at: 30.minutes.ago, executed_at: 1.hour.ago)
    IdempotencyLock::Lock.create!(name: "valid", expires_at: 1.hour.from_now, executed_at: Time.current)
    IdempotencyLock::Lock.create!(name: "permanent", expires_at: nil, executed_at: Time.current)

    cleaned = IdempotencyLock::Lock.cleanup_expired

    assert_equal 2, cleaned
    refute IdempotencyLock::Lock.exists?(name: "expired-1")
    refute IdempotencyLock::Lock.exists?(name: "expired-2")
    assert IdempotencyLock::Lock.exists?(name: "valid")
    assert IdempotencyLock::Lock.exists?(name: "permanent")
  end
end

class TestIdempotencyLockResult < Minitest::Test
  def test_result_executed
    result = IdempotencyLock::Result.new(executed: true, value: 42)

    assert_predicate result, :executed?
    refute_predicate result, :skipped?
    refute_predicate result, :error?
    assert_predicate result, :success?
    assert_equal 42, result.value
  end

  def test_result_skipped
    result = IdempotencyLock::Result.new(executed: false, skipped: true)

    refute_predicate result, :executed?
    assert_predicate result, :skipped?
    refute_predicate result, :error?
    refute_predicate result, :success?
  end

  def test_result_with_error
    error = StandardError.new("test error")
    result = IdempotencyLock::Result.new(executed: true, error: error)

    assert_predicate result, :executed?
    assert_predicate result, :error?
    refute_predicate result, :success?
    assert_equal error, result.error
  end
end

class TestIdempotencyLockOptimisticLocking < Minitest::Test
  include IdempotencyLockTestHelpers

  # This test verifies why optimistic locking (WHERE updated_at = observed_value)
  # is better than a simple expiration check (WHERE expires_at < now).
  #
  # Scenario: Process A acquires with a SHORT TTL, and Process B has a clock
  # that's ahead. Without optimistic locking, B could steal A's lock because
  # A's new expires_at is already "expired" from B's perspective.
  def test_short_ttl_with_clock_skew_only_one_wins
    # Create an expired lock
    IdempotencyLock::Lock.create!(
      name: "short-ttl-skew",
      expires_at: 1.minute.ago,
      executed_at: 2.minutes.ago
    )

    # Both processes read the SAME state (simulating concurrent read)
    observed_updated_at = IdempotencyLock::Lock.find_by(name: "short-ttl-skew").updated_at

    process_a_clock = Time.current
    short_ttl = 10.seconds
    process_b_clock = process_a_clock + 1.minute # B's clock is way ahead

    # A acquires with short TTL - new expires_at is only 10 seconds out
    new_expires_at_from_a = process_a_clock + short_ttl

    # With optimistic locking: WHERE updated_at = observed_value
    result_a = IdempotencyLock::Lock
               .where(name: "short-ttl-skew", updated_at: observed_updated_at)
               .update_all(expires_at: new_expires_at_from_a, executed_at: process_a_clock, updated_at: process_a_clock)

    # B tries with same observed value - should FAIL because updated_at changed
    new_expires_at_from_b = process_b_clock + 1.hour
    result_b = IdempotencyLock::Lock
               .where(name: "short-ttl-skew", updated_at: observed_updated_at)
               .update_all(expires_at: new_expires_at_from_b, executed_at: process_b_clock, updated_at: process_b_clock)

    assert_equal 1, result_a, "A should succeed"
    assert_equal 0, result_b, "B should fail - optimistic locking prevents double claim"

    # WITHOUT optimistic locking (using WHERE expires_at < now), B would check:
    #   new_expires_at_from_a < process_b_clock
    #   = (now + 10 seconds) < (now + 1 minute)
    #   = TRUE  <-- B would also succeed! That's the bug optimistic locking prevents.
  end

  # Demonstrates the race condition at the UPDATE level
  def test_concurrent_updates_only_one_wins
    IdempotencyLock::Lock.create!(
      name: "concurrent-update",
      expires_at: 1.minute.ago,
      executed_at: 2.minutes.ago
    )

    # Both "processes" observe the same updated_at before either updates
    observed_updated_at = IdempotencyLock::Lock.find_by(name: "concurrent-update").updated_at
    now = Time.current

    # First update wins
    first = IdempotencyLock::Lock
            .where(name: "concurrent-update", updated_at: observed_updated_at)
            .update_all(expires_at: now + 1.hour, executed_at: now, updated_at: now)

    # Second update fails - updated_at no longer matches
    second = IdempotencyLock::Lock
             .where(name: "concurrent-update", updated_at: observed_updated_at)
             .update_all(expires_at: now + 2.hours, executed_at: now, updated_at: now)

    assert_equal 1, first, "First update should affect 1 row"
    assert_equal 0, second, "Second update should affect 0 rows"
  end
end
