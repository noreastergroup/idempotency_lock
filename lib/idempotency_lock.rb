# frozen_string_literal: true

require "active_record"
require "active_support/time"

require_relative "idempotency_lock/version"
require_relative "idempotency_lock/result"
require_relative "idempotency_lock/arguments"

# Database-backed idempotency locks for Ruby on Rails.
#
# Guarantees an operation runs *at most once* per lock name (or once per TTL
# window) across processes and machines, using a unique database index for
# atomicity. Supports TTL expiration, multiple error handling strategies, and
# clean return value handling.
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

  # Error handling strategies for `once`
  ON_ERROR_UNLOCK = :unlock       # Remove lock so operation can be retried
  ON_ERROR_KEEP_LOCKED = :keep    # Keep lock in place (default)
  ON_ERROR_RAISE = :raise         # Release lock, then re-raise
  ON_ERROR_STRATEGIES = [ON_ERROR_KEEP_LOCKED, ON_ERROR_UNLOCK, ON_ERROR_RAISE].freeze

  # Error handling strategies for `temporarily` (the lock is always released)
  TEMPORARY_ON_ERROR_STRATEGIES = [nil, ON_ERROR_RAISE].freeze

  # Maximum length for lock names. Matches the column limit in the generated
  # migration and stays within unique index limits on common databases.
  MAX_NAME_LENGTH = 255

  # Interval between attempts when `temporarily` is called with `wait:`
  WAIT_RETRY_INTERVAL = 0.1 # 100ms

  # Loaded on first use so that requiring the gem does not force
  # ActiveRecord::Base to load before the host application is configured.
  autoload :Lock, File.expand_path("idempotency_lock/lock", __dir__)

  class << self
    # Execute a block at most once for the given operation name.
    #
    # The lock is taken *before* the block runs. If the block raises, `on_error`
    # decides whether the lock is kept (no retry) or released (retry allowed).
    #
    # @param name [String, Symbol] unique identifier for this operation
    # @param ttl [ActiveSupport::Duration, Numeric, nil] time-to-live for the lock
    # @param on_error [Symbol, #call] :keep (default), :unlock, :raise, or a callable
    # @yield The block to execute (at most once per lock name / TTL window)
    # @return [Result] containing execution status and return value
    # @raise [ArgumentError] for a missing block, invalid name, ttl, or on_error
    def once(name, ttl: nil, on_error: ON_ERROR_KEEP_LOCKED, &block)
      raise ArgumentError, "Block required" unless block

      name = Arguments.normalize_name!(name)
      Arguments.validate_ttl!(ttl)
      Arguments.validate_on_error!(on_error, ON_ERROR_STRATEGIES)

      token = acquire_lock(name, ttl)
      unless token
        log_debug("Lock already exists for '#{name}', skipping execution")
        return Result.new(executed: false, skipped: true)
      end

      log_debug("Lock acquired for '#{name}', executing block")
      run_once(name, token, on_error, &block)
    end

    # Convenience alias for `once`
    alias wrap once

    # Execute a block while holding a lock that is always released when the
    # block finishes (success, error, or non-local exit).
    #
    # Unlike `once`, this is mutex-style exclusion, not idempotency.
    #
    # Without a `ttl:`, a lock held by a process that is killed (e.g. SIGKILL,
    # OOM, host failure) is never released. Pass a `ttl:` longer than the
    # block's worst-case runtime for crash protection.
    #
    # @param name [String, Symbol] unique identifier for this lock
    # @param ttl [ActiveSupport::Duration, Numeric, nil] time-to-live for crash protection
    # @param wait [ActiveSupport::Duration, Numeric, nil] how long to wait for the lock
    # @param on_error [nil, Symbol, #call] nil (default) captures the error in the
    #   Result; :raise re-raises it; a callable is invoked with it
    # @yield The block to execute while holding the lock
    # @return [Result] containing execution status and return value
    # @raise [ArgumentError] for a missing block, invalid name, ttl, wait, or on_error
    def temporarily(name, ttl: nil, wait: nil, on_error: nil, &block)
      raise ArgumentError, "Block required" unless block

      name = Arguments.normalize_name!(name)
      Arguments.validate_ttl!(ttl)
      Arguments.validate_on_error!(on_error, TEMPORARY_ON_ERROR_STRATEGIES)
      wait_seconds = Arguments.normalize_wait!(wait)

      token = acquire_with_wait(name, ttl, wait_seconds)
      unless token
        log_debug("Lock already held for '#{name}', skipping execution")
        return Result.new(executed: false, skipped: true)
      end

      log_debug("Temporary lock acquired for '#{name}', executing block")
      run_temporarily(name, token, on_error, &block)
    end

    # Force-release a lock regardless of who holds it (useful for testing or
    # manual intervention).
    #
    # @param name [String, Symbol] the lock name to release
    # @return [Boolean] true if a lock was released
    def release(name)
      Lock.release(Arguments.normalize_name!(name))
    end

    # Check if an operation is currently locked
    #
    # @param name [String, Symbol] the lock name to check
    # @return [Boolean] true if locked and not expired
    def locked?(name)
      Lock.locked?(Arguments.normalize_name!(name))
    end

    # Clean up all expired locks
    #
    # @return [Integer] number of locks cleaned up
    def cleanup_expired
      Lock.cleanup_expired
    end

    # Set the logger. Set to nil to disable logging.
    attr_writer :logger

    # The configured logger, or Rails.logger if none has been set.
    def logger
      return @logger if defined?(@logger)

      Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)
    end

    private

    def run_once(name, token, on_error)
      value = yield
      Result.new(executed: true, value: value)
    rescue StandardError => e
      handle_error(name, token, e, on_error)
    rescue Exception # rubocop:disable Lint/RescueException
      # Interrupt, SignalException, Sidekiq::Shutdown, etc. The block did not
      # finish, so apply the release policy before propagating.
      release_after_abort(name, token, on_error)
      raise
    end

    def run_temporarily(name, token, on_error)
      begin
        value = yield
      rescue StandardError => e
        error = e
      ensure
        Lock.release(name, owner_token: token)
        log_debug("Temporary lock released for '#{name}'")
      end
      return Result.new(executed: true, value: value) unless error

      log_error("Exception in temporary lock block '#{name}': #{error.class} - #{error.message}")
      raise error if on_error == ON_ERROR_RAISE

      on_error&.call(error)
      Result.new(executed: true, error: error)
    end

    def acquire_lock(name, ttl)
      now = Time.current
      Lock.acquire(name, expires_at: ttl && (now + ttl), now: now)
    end

    def acquire_with_wait(name, ttl, wait_seconds)
      token = acquire_lock(name, ttl)
      return token if token || wait_seconds.nil?

      deadline = monotonic_now + wait_seconds
      loop do
        remaining = deadline - monotonic_now
        return nil unless remaining.positive?

        sleep([WAIT_RETRY_INTERVAL, remaining].min)
        token = acquire_lock(name, ttl)
        return token if token
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def handle_error(name, token, exception, on_error)
      log_error("Exception in idempotent block '#{name}': #{exception.class} - #{exception.message}")

      case on_error
      when ON_ERROR_KEEP_LOCKED
        log_debug("Lock kept for '#{name}' despite error (on_error: :keep)")
      when ON_ERROR_UNLOCK
        release_owned(name, token, "due to error (on_error: :unlock)")
      when ON_ERROR_RAISE
        release_owned(name, token, "re-raising error (on_error: :raise)")
        raise exception
      else
        release_owned(name, token, "calling error handler")
        on_error.call(exception)
      end

      Result.new(executed: true, error: exception)
    end

    def release_after_abort(name, token, on_error)
      return if on_error == ON_ERROR_KEEP_LOCKED

      release_owned(name, token, "after the block was aborted")
    end

    def release_owned(name, token, reason)
      Lock.release(name, owner_token: token)
      log_debug("Lock released for '#{name}' #{reason}")
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
