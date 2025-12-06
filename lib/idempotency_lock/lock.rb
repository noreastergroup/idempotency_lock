# frozen_string_literal: true

module IdempotencyLock
  # ActiveRecord model for storing idempotency locks.
  #
  # This model expects a database table with the following schema:
  #   - name: string (unique, indexed, max 255 chars)
  #   - expires_at: datetime (nullable, indexed)
  #   - executed_at: datetime
  #   - created_at: datetime
  #   - updated_at: datetime
  #
  # Use the provided generator to create the migration:
  #   rails generate idempotency_lock:install
  #
  class Lock < ActiveRecord::Base
    self.table_name = "idempotency_locks"

    # Maximum length for lock names. Ensures compatibility with database
    # unique index limits (MySQL utf8mb4 = 191, most others = 255+).
    MAX_NAME_LENGTH = 255

    validates :name, presence: true, uniqueness: true, length: { maximum: MAX_NAME_LENGTH }

    # Check if this lock has expired
    # @return [Boolean]
    def expired?(now: Time.current)
      expires_at.present? && expires_at < now
    end

    # Check if this lock is still valid (not expired)
    # @return [Boolean]
    def valid_lock?(now: Time.current)
      expires_at.nil? || expires_at >= now
    end

    class << self
      # Attempt to acquire a lock for the given name.
      # Returns true if the lock was acquired, false otherwise.
      #
      # @param name [String] unique identifier for the operation
      # @param expires_at [Time, nil] when the lock should expire (nil = never)
      # @param now [Time] current time reference (injectable for testing)
      # @return [Boolean] true if lock was acquired
      def acquire(name, expires_at: nil, now: Time.current)
        # Try to insert first (most common case for new keys)
        begin
          create!(name: name, expires_at: expires_at, executed_at: now)
          return true
        rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
          # Lock exists, check if it's expired
        end

        # Check if an existing lock is expired and can be claimed
        existing = find_by(name: name)
        return false if existing.nil?
        return false unless existing.expired?(now: now)

        # Optimistic locking: use the observed updated_at in the WHERE clause.
        # This prevents a race where two processes both see an expired lock and
        # both try to claim it. Only one UPDATE will match; the other returns 0.
        # We use updated_at rather than expires_at because it's system-managed
        # and always moves forward, making it more reliable for concurrency control.
        updated = where(name: name, updated_at: existing.updated_at)
                  .update_all(expires_at: expires_at, executed_at: now, updated_at: now)

        updated.positive?
      end

      # Release a lock by name (removes the record entirely)
      #
      # @param name [String] unique identifier for the operation
      # @return [Boolean] true if a lock was removed
      def release(name)
        deleted = where(name: name).delete_all
        deleted.positive?
      end

      # Check if a valid (non-expired) lock exists for the given name
      #
      # @param name [String] unique identifier for the operation
      # @return [Boolean]
      def locked?(name)
        lock = find_by(name: name)
        return false if lock.nil?

        lock.valid_lock?
      end

      # Clean up expired locks
      #
      # @return [Integer] number of locks removed
      def cleanup_expired
        where("expires_at IS NOT NULL AND expires_at < ?", Time.current).delete_all
      end
    end
  end
end
