# frozen_string_literal: true

require "test_helper"
require "open3"

class TestIdempotencyLockArgumentValidation < Minitest::Test
  include IdempotencyLockTestHelpers

  def test_invalid_names_raise_instead_of_silently_skipping
    [nil, "", "   ", "\u00a0", "\u3000\t", "a" * 256, 123].each do |name|
      ran = false
      assert_raises(ArgumentError, "name: #{name.inspect}") do
        IdempotencyLock.once(name) { ran = true }
      end
      refute ran
    end

    assert_equal 0, IdempotencyLock::Lock.count
  end

  def test_max_length_name_is_accepted
    result = IdempotencyLock.once("a" * IdempotencyLock::MAX_NAME_LENGTH) { :ok }

    assert_predicate result, :success?
  end

  def test_symbol_names_are_equivalent_to_strings
    IdempotencyLock.once(:symbol_name) { :ok }

    assert IdempotencyLock.locked?("symbol_name")
    assert_predicate IdempotencyLock.once("symbol_name") { :ok }, :skipped?
  end

  def test_unknown_on_error_raises_before_running
    ran = false
    error = assert_raises(ArgumentError) do
      IdempotencyLock.once("typo", on_error: :unlok) { ran = true }
    end

    assert_match(/on_error/, error.message)
    refute ran
    refute IdempotencyLock.locked?("typo")
  end

  def test_temporarily_rejects_once_only_strategies
    assert_raises(ArgumentError) do
      IdempotencyLock.temporarily("temp", on_error: :keep) { :ok }
    end
  end

  def test_any_callable_is_accepted_as_error_handler
    handler = Struct.new(:received) { def call(error) = self.received = error }.new

    IdempotencyLock.once("callable", on_error: handler) { raise "boom" }

    assert_equal "boom", handler.received.message
  end

  def test_invalid_ttl_raises
    [0, -5, "60", Float::NAN, Float::INFINITY].each do |ttl|
      assert_raises(ArgumentError, "ttl: #{ttl.inspect}") do
        IdempotencyLock.once("bad-ttl", ttl: ttl) { :ok }
      end
    end
  end

  def test_fractional_ttl_is_respected
    IdempotencyLock.once("fractional", ttl: 1.5) { :ok }

    lock = IdempotencyLock::Lock.find_by(name: "fractional")

    assert_in_delta Time.current + 1.5, lock.expires_at, 0.5
  end
end

class TestIdempotencyLockOwnership < Minitest::Test
  include IdempotencyLockTestHelpers

  def test_lock_release_requires_matching_owner_token
    token = IdempotencyLock::Lock.acquire("owned")

    refute IdempotencyLock::Lock.release("owned", owner_token: "someone-else")
    assert IdempotencyLock.locked?("owned")
    assert IdempotencyLock::Lock.release("owned", owner_token: token)
    refute IdempotencyLock.locked?("owned")
  end

  def test_public_release_is_a_force_release
    IdempotencyLock::Lock.acquire("forced")

    assert IdempotencyLock.release("forced")
    refute IdempotencyLock.locked?("forced")
  end

  def test_temporarily_does_not_release_a_lock_taken_over_after_expiry
    other_token = nil

    IdempotencyLock.temporarily("job", ttl: 60) do
      other_token = take_over("job")
    end

    assert other_token, "another process should have claimed the expired lock"
    assert IdempotencyLock.locked?("job"), "the new holder's lock must survive"
    assert_equal other_token, IdempotencyLock::Lock.find_by(name: "job").owner_token
  end

  def test_once_unlock_does_not_release_a_lock_taken_over_after_expiry
    IdempotencyLock.once("once-job", ttl: 60, on_error: :unlock) do
      take_over("once-job")
      raise "boom"
    end

    assert IdempotencyLock.locked?("once-job")
  end

  def test_once_raise_does_not_release_a_lock_taken_over_after_expiry
    assert_raises(RuntimeError) do
      IdempotencyLock.once("once-raise", ttl: 60, on_error: :raise) do
        take_over("once-raise")
        raise "boom"
      end
    end

    assert IdempotencyLock.locked?("once-raise")
  end

  private

  # Simulate the current holder's TTL lapsing and another process claiming it.
  def take_over(name)
    IdempotencyLock::Lock.where(name: name).update_all(expires_at: 1.second.ago)
    IdempotencyLock::Lock.acquire(name, expires_at: 1.hour.from_now)
  end
end

class TestIdempotencyLockAbortedBlocks < Minitest::Test
  include IdempotencyLockTestHelpers

  def test_interrupt_with_unlock_releases_and_propagates
    assert_raises(Interrupt) do
      IdempotencyLock.once("int-unlock", on_error: :unlock) { raise Interrupt }
    end

    refute IdempotencyLock.locked?("int-unlock")
  end

  def test_interrupt_with_raise_releases_and_propagates
    assert_raises(Interrupt) do
      IdempotencyLock.once("int-raise", on_error: :raise) { raise Interrupt }
    end

    refute IdempotencyLock.locked?("int-raise")
  end

  def test_interrupt_with_keep_keeps_lock
    assert_raises(Interrupt) do
      IdempotencyLock.once("int-keep") { raise Interrupt }
    end

    assert IdempotencyLock.locked?("int-keep")
  end

  def test_interrupt_with_callable_releases_without_calling_handler
    called = false

    assert_raises(Interrupt) do
      IdempotencyLock.once("int-proc", on_error: ->(_e) { called = true }) { raise Interrupt }
    end

    refute called, "handler is only for StandardError"
    refute IdempotencyLock.locked?("int-proc")
  end

  def test_early_return_from_once_counts_as_completed
    assert_equal :early, once_with_early_return

    assert IdempotencyLock.locked?("early-return"), "a non-local return is not an error"
  end

  def test_temporarily_releases_on_interrupt
    assert_raises(Interrupt) do
      IdempotencyLock.temporarily("temp-int") { raise Interrupt }
    end

    refute IdempotencyLock.locked?("temp-int")
  end

  def test_temporarily_releases_on_early_return
    assert_equal :early, temporarily_with_early_return

    refute IdempotencyLock.locked?("temp-early")
  end

  private

  def once_with_early_return
    IdempotencyLock.once("early-return", on_error: :unlock) { return :early }
    :not_reached
  end

  def temporarily_with_early_return
    IdempotencyLock.temporarily("temp-early") { return :early }
    :not_reached
  end
end

class TestIdempotencyLockTransactions < Minitest::Test
  include IdempotencyLockTestHelpers

  # On PostgreSQL, a failed INSERT aborts the enclosing transaction unless it
  # runs in a savepoint. This is only a meaningful regression test on PG, but
  # it must pass on every adapter.
  def test_skipping_inside_a_transaction_leaves_the_transaction_usable
    IdempotencyLock.once("in-tx") { :first }

    IdempotencyLock::Lock.transaction do
      result = IdempotencyLock.once("in-tx") { :second }

      assert_predicate result, :skipped?
      assert_equal 1, IdempotencyLock::Lock.where(name: "in-tx").count
    end
  end

  def test_expired_lock_can_be_reclaimed_inside_a_transaction
    IdempotencyLock::Lock.create!(name: "in-tx-expired", expires_at: 1.minute.ago, executed_at: 2.minutes.ago)

    IdempotencyLock::Lock.transaction do
      assert_predicate IdempotencyLock.once("in-tx-expired", ttl: 60) { :ok }, :executed?
    end
  end

  def test_lock_is_rolled_back_with_the_enclosing_transaction
    IdempotencyLock::Lock.transaction do
      IdempotencyLock.once("rolled-back") { :ok }
      raise ActiveRecord::Rollback
    end

    refute IdempotencyLock.locked?("rolled-back")
  end
end

class TestIdempotencyLockThreads < Minitest::Test
  include IdempotencyLockTestHelpers

  THREADS = 8

  def test_once_runs_exactly_one_block_across_racing_threads
    results = race { IdempotencyLock.once("race") { :ran } }

    assert_equal 1, results.count(&:executed?)
    assert_equal THREADS - 1, results.count(&:skipped?)
  end

  def test_expired_lock_is_reclaimed_by_exactly_one_racing_thread
    IdempotencyLock::Lock.create!(name: "race-expired", expires_at: 1.minute.ago, executed_at: 2.minutes.ago)

    results = race { IdempotencyLock.once("race-expired", ttl: 60) { :ran } }

    assert_equal 1, results.count(&:executed?)
  end

  def test_temporarily_provides_mutual_exclusion
    active = Concurrent::AtomicFixnum.new(0)
    max_active = Concurrent::AtomicFixnum.new(0)

    results = race do
      IdempotencyLock.temporarily("mutex", wait: 10) do
        now_active = active.increment
        max_active.update { |m| [m, now_active].max }
        sleep 0.02
        active.decrement
      end
    end

    assert results.all?(&:executed?), "every thread should eventually get the lock"
    assert_equal 1, max_active.value
  end

  private

  def race(&block)
    gate = Concurrent::CountDownLatch.new(1)
    threads = Array.new(THREADS) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.wait
          block.call
        end
      end
    end
    gate.count_down
    threads.map(&:value)
  end
end

class TestIdempotencyLockLogger < Minitest::Test
  def teardown
    IdempotencyLock.logger = nil
  end

  def test_explicit_nil_logger_disables_logging
    IdempotencyLock.logger = Logger.new(nil)
    IdempotencyLock.logger = nil

    with_fake_rails_logger do
      assert_nil IdempotencyLock.logger
    end
  end

  def test_defaults_to_rails_logger_when_unset
    IdempotencyLock.remove_instance_variable(:@logger) if IdempotencyLock.instance_variable_defined?(:@logger)

    with_fake_rails_logger do |fake|
      assert_same fake, IdempotencyLock.logger
    end
  end

  private

  # Rails may or may not be defined here (railties' minitest plugin defines a
  # bare `Rails` module without `logger`), so handle every case.
  def with_fake_rails_logger
    fake = Logger.new(nil)
    created = !defined?(Rails)
    Object.const_set(:Rails, Module.new) if created

    if Rails.respond_to?(:logger)
      Rails.stub(:logger, fake) { yield fake }
    else
      Rails.define_singleton_method(:logger) { fake }
      begin
        yield fake
      ensure
        Rails.singleton_class.send(:remove_method, :logger)
      end
    end
  ensure
    Object.send(:remove_const, :Rails) if created
  end
end

class TestIdempotencyLockResultInspect < Minitest::Test
  def test_inspect_does_not_leak_values
    result = IdempotencyLock::Result.new(executed: true, value: "secret-api-key")

    refute_includes result.inspect, "secret-api-key"
    assert_includes result.inspect, "value=String"
  end

  def test_inspect_shows_false_values
    assert_includes IdempotencyLock::Result.new(executed: true, value: false).inspect, "value=FalseClass"
  end
end

class TestIdempotencyLockLoading < Minitest::Test
  def test_requiring_the_gem_does_not_load_active_record_base
    lib = File.expand_path("../lib", __dir__)
    script = <<~RUBY
      require "idempotency_lock"
      abort "ActiveRecord::Base was loaded eagerly" unless ActiveRecord.autoload?(:Base)
      abort "IdempotencyLock::Lock was loaded eagerly" unless IdempotencyLock.autoload?(:Lock)
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, "-I", lib, "-e", script)

    assert_predicate status, :success?, output
  end
end
