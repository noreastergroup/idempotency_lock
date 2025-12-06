# frozen_string_literal: true

require_relative "idempotency_lock/version"
require_relative "idempotency_lock/result"
require_relative "idempotency_lock/lock"

# Database-backed idempotency locks for Ruby on Rails.
#
# Ensures operations run exactly once using database-backed locks with support
# for TTL expiration, multiple error handling strategies, and clean return
# value handling.
#
# @example Basic usage
#   result = IdempotencyLock.once("send-welcome-email-user-123") do
#     UserMailer.welcome(user).deliver_now
#   end
#   puts "Email sent!" if result.executed?
#
# @example With TTL
#   IdempotencyLock.once("daily-report", ttl: 24.hours) { generate_report }
#
module IdempotencyLock
  class Error < StandardError; end

  # Error handling strategies
  ON_ERROR_UNLOCK = :unlock       # Remove lock so operation can be retried
  ON_ERROR_KEEP_LOCKED = :keep    # Keep lock in place (default)
  ON_ERROR_RAISE = :raise         # Re-raise after cleanup/logging

  class << self
    # Execute a block exactly once for the given operation name.
    #
    # @param name [String] unique identifier for this operation
    # @param ttl [ActiveSupport::Duration, Integer, nil] time-to-live for the lock
    # @param on_error [Symbol, Proc] error handling strategy (:keep, :unlock, :raise, or Proc)
    # @yield The block to execute (exactly once per lock name)
    # @return [Result] containing execution status and return value
    def once(name, ttl: nil, on_error: ON_ERROR_KEEP_LOCKED, &)
      raise ArgumentError, "Block required" unless block_given?

      now = Time.current
      expires_at = calculate_expires_at(ttl, now)
      acquired = Lock.acquire(name, expires_at: expires_at, now: now)

      unless acquired
        log_debug("Lock already exists for '#{name}', skipping execution")
        return Result.new(executed: false, skipped: true)
      end

      log_debug("Lock acquired for '#{name}', executing block")
      execute_with_lock(name, on_error, &)
    end

    # Convenience alias for `once`
    alias wrap once

    # Release a lock manually (useful for testing or manual intervention)
    #
    # @param name [String] the lock name to release
    # @return [Boolean] true if a lock was released
    def release(name)
      Lock.release(name)
    end

    # Check if an operation is currently locked
    #
    # @param name [String] the lock name to check
    # @return [Boolean] true if locked and not expired
    def locked?(name)
      Lock.locked?(name)
    end

    # Clean up all expired locks
    #
    # @return [Integer] number of locks cleaned up
    def cleanup_expired
      Lock.cleanup_expired
    end

    # Configure the logger (uses Rails.logger by default if available)
    attr_writer :logger

    def logger
      @logger ||= defined?(Rails) ? Rails.logger : nil
    end

    private

    def calculate_expires_at(ttl, now)
      return nil if ttl.nil?

      if ttl.respond_to?(:from_now)
        # ActiveSupport::Duration
        now + ttl
      else
        # Assume seconds
        now + ttl.to_i
      end
    end

    def execute_with_lock(name, on_error)
      value = yield
      Result.new(executed: true, value: value)
    rescue StandardError => e
      handle_error(name, e, on_error)
    end

    def handle_error(name, exception, on_error)
      log_error("Exception in idempotent block '#{name}': #{exception.class} - #{exception.message}")

      case on_error
      when :unlock then handle_unlock_error(name, exception)
      when :raise then handle_raise_error(name, exception)
      when :keep, ON_ERROR_KEEP_LOCKED then handle_keep_error(name, exception)
      when Proc then handle_proc_error(name, exception, on_error)
      else Result.new(executed: true, error: exception)
      end
    end

    def handle_unlock_error(name, exception)
      Lock.release(name)
      log_debug("Lock released for '#{name}' due to error (on_error: :unlock)")
      Result.new(executed: true, error: exception)
    end

    def handle_raise_error(name, exception)
      Lock.release(name)
      log_debug("Lock released for '#{name}', re-raising error (on_error: :raise)")
      raise exception
    end

    def handle_keep_error(name, exception)
      log_debug("Lock kept for '#{name}' despite error (on_error: :keep)")
      Result.new(executed: true, error: exception)
    end

    def handle_proc_error(name, exception, handler)
      Lock.release(name)
      handler.call(exception)
      Result.new(executed: true, error: exception)
    end

    def log_debug(message)
      logger&.debug("[IdempotencyLock] #{message}")
    end

    def log_error(message)
      logger&.error("[IdempotencyLock] #{message}")
    end
  end
end

# Load Rails integration if Rails is present
require_relative "idempotency_lock/railtie" if defined?(Rails::Railtie)
