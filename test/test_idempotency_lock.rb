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

  # Simulates two processes that both read the same expired lock before either
  # claims it. Process B's find_by is stubbed to return the stale snapshot it
  # read earlier; its UPDATE must then match 0 rows because A's claim changed
  # the owner_token.
  def test_concurrent_claims_of_expired_lock_only_one_wins
    create_expired_lock("concurrent-claim")
    stale_snapshot = IdempotencyLock::Lock.find_by(name: "concurrent-claim")

    token_a = IdempotencyLock::Lock.acquire("concurrent-claim", expires_at: 1.hour.from_now)
    token_b = IdempotencyLock::Lock.stub(:find_by, stale_snapshot) do
      IdempotencyLock::Lock.acquire("concurrent-claim", expires_at: 2.hours.from_now)
    end

    assert token_a, "A should claim the expired lock"
    assert_nil token_b, "B should fail: optimistic locking prevents a double claim"
    assert_equal token_a, IdempotencyLock::Lock.find_by(name: "concurrent-claim").owner_token
  end

  # A and B race to claim the SAME expired lock (both read the old token).
  # A claims with a SHORT TTL and B's clock is far ahead, so A's new lock
  # already looks expired to B. B's claim must still fail, because it is
  # conditioned on the stale owner_token B observed. (A fresh read by B is a
  # different case; see test_clock_skew_allows_takeover_after_a_fresh_read.)
  def test_short_ttl_with_clock_skew_only_one_wins
    create_expired_lock("short-ttl-skew")
    stale_snapshot = IdempotencyLock::Lock.find_by(name: "short-ttl-skew")

    process_a_clock = Time.current
    process_b_clock = process_a_clock + 1.minute

    token_a = IdempotencyLock::Lock.acquire("short-ttl-skew", expires_at: process_a_clock + 10.seconds,
                                                              now: process_a_clock)
    token_b = IdempotencyLock::Lock.stub(:find_by, stale_snapshot) do
      IdempotencyLock::Lock.acquire("short-ttl-skew", expires_at: process_b_clock + 1.hour, now: process_b_clock)
    end

    assert token_a, "A should succeed"
    assert_nil token_b, "B should fail even though A's lock looks expired on B's clock"
  end

  # Documents a known limitation (see README "TTL / Expiration"): expiry is
  # judged by the claiming server's clock, so a server whose clock is ahead can
  # take over a lock that is still live from the holder's point of view.
  def test_clock_skew_allows_takeover_after_a_fresh_read
    holder_clock = Time.current
    holder_token = IdempotencyLock::Lock.acquire("skewed", expires_at: holder_clock + 10.seconds,
                                                           now: holder_clock)

    skewed_token = IdempotencyLock::Lock.acquire("skewed", expires_at: holder_clock + 2.minutes,
                                                           now: holder_clock + 1.minute)

    assert skewed_token, "a fast clock sees the holder's lock as expired"
    refute IdempotencyLock::Lock.release("skewed", owner_token: holder_token),
           "but the original holder still cannot release the new holder's lock"
  end

  def test_reclaim_issues_a_new_owner_token
    first = IdempotencyLock::Lock.acquire("reclaim", expires_at: 1.hour.from_now)
    IdempotencyLock::Lock.where(name: "reclaim").update_all(expires_at: 1.minute.ago)

    second = IdempotencyLock::Lock.acquire("reclaim", expires_at: 1.hour.from_now)

    assert second
    refute_equal first, second
  end

  private

  def create_expired_lock(name)
    IdempotencyLock::Lock.create!(name: name, expires_at: 1.minute.ago, executed_at: 2.minutes.ago)
  end
end

class TestIdempotencyLockTemporarily < Minitest::Test
  include IdempotencyLockTestHelpers

  def test_temporarily_executes_block_and_returns_value
    executed = false

    result = IdempotencyLock.temporarily("temp-test") do
      executed = true
      "return value"
    end

    assert executed, "Block should have been executed"
    assert_predicate result, :executed?
    assert_predicate result, :success?
    refute_predicate result, :skipped?
    assert_equal "return value", result.value
  end

  def test_temporarily_releases_lock_after_success
    IdempotencyLock.temporarily("temp-release") { "done" }

    refute IdempotencyLock.locked?("temp-release")
  end

  def test_temporarily_releases_lock_after_error
    result = IdempotencyLock.temporarily("temp-error") do
      raise StandardError, "boom"
    end

    assert_predicate result, :executed?
    assert_predicate result, :error?
    assert_kind_of StandardError, result.error
    refute IdempotencyLock.locked?("temp-error")
  end

  def test_temporarily_skips_when_lock_held
    IdempotencyLock::Lock.acquire("temp-held")

    call_count = 0
    result = IdempotencyLock.temporarily("temp-held") { call_count += 1 }

    assert_equal 0, call_count, "Block should not execute when lock is held"
    refute_predicate result, :executed?
    assert_predicate result, :skipped?
  end

  def test_temporarily_allows_re_execution_after_release
    call_count = 0

    3.times { IdempotencyLock.temporarily("temp-reuse") { call_count += 1 } }

    assert_equal 3, call_count, "Block should execute each time since lock is released"
  end

  def test_temporarily_requires_block
    assert_raises(ArgumentError) do
      IdempotencyLock.temporarily("no-block")
    end
  end

  def test_temporarily_with_ttl
    IdempotencyLock.temporarily("temp-ttl", ttl: 3600) { "done" }

    # Lock should be released immediately, not after TTL
    refute IdempotencyLock.locked?("temp-ttl")
  end

  def test_temporarily_different_names_work_independently
    results = []

    IdempotencyLock.temporarily("temp-a") { results << "a" }
    IdempotencyLock.temporarily("temp-b") { results << "b" }

    assert_equal %w[a b], results
  end

  def test_temporarily_on_error_raise_reraises_and_releases
    error = assert_raises(RuntimeError) do
      IdempotencyLock.temporarily("temp-raise", on_error: :raise) { raise "boom" }
    end

    assert_equal "boom", error.message
    refute IdempotencyLock.locked?("temp-raise")
  end

  def test_temporarily_on_error_callable_is_called_after_release
    locked_during_handler = nil
    handler = ->(_e) { locked_during_handler = IdempotencyLock.locked?("temp-proc") }

    result = IdempotencyLock.temporarily("temp-proc", on_error: handler) { raise "boom" }

    assert_predicate result, :error?
    refute locked_during_handler, "lock should already be released when the handler runs"
  end
end

class TestIdempotencyLockTemporarilyWait < Minitest::Test
  include IdempotencyLockTestHelpers

  def test_wait_acquires_lock_when_released
    # Create a lock with a very short TTL that will expire during wait
    IdempotencyLock::Lock.create!(
      name: "wait-test",
      expires_at: 0.15.seconds.from_now,
      executed_at: Time.current
    )

    call_count = 0
    result = IdempotencyLock.temporarily("wait-test", wait: 2) { call_count += 1 }

    assert_equal 1, call_count, "Block should execute after lock expires"
    assert_predicate result, :executed?
  end

  def test_wait_times_out_and_skips
    IdempotencyLock::Lock.acquire("wait-timeout")

    call_count = 0
    elapsed = measure { @result = IdempotencyLock.temporarily("wait-timeout", wait: 0.25) { call_count += 1 } }

    assert_equal 0, call_count, "Block should not execute when timeout reached"
    assert_predicate @result, :skipped?
    refute_predicate @result, :executed?
    assert_operator elapsed, :>=, 0.25
    assert_operator elapsed, :<, 2.0, "should not wait far beyond the timeout"
  end

  def test_wait_with_duration
    IdempotencyLock::Lock.acquire("wait-duration")

    elapsed = measure { IdempotencyLock.temporarily("wait-duration", wait: 0.2.seconds) { "done" } }

    assert_operator elapsed, :>=, 0.2
    assert_operator elapsed, :<, 2.0
  end

  def test_wait_with_numeric_seconds
    IdempotencyLock::Lock.acquire("wait-numeric")

    elapsed = measure { IdempotencyLock.temporarily("wait-numeric", wait: 0.2) { "done" } }

    assert_operator elapsed, :>=, 0.2
    assert_operator elapsed, :<, 2.0
  end

  def test_wait_nil_skips_immediately
    IdempotencyLock::Lock.acquire("wait-nil")

    result = IdempotencyLock.stub(:sleep, ->(*) { flunk "should not sleep when wait is nil" }) do
      IdempotencyLock.temporarily("wait-nil", wait: nil) { "done" }
    end

    assert_predicate result, :skipped?
  end

  def test_wait_rejects_invalid_values
    [-1, "5", :forever, Float::NAN, Float::INFINITY].each do |wait|
      assert_raises(ArgumentError, "wait: #{wait.inspect}") do
        IdempotencyLock.temporarily("wait-invalid", wait: wait) { "done" }
      end
    end
  end

  private

  def measure
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end
end
