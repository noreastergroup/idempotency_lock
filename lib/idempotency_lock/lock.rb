# frozen_string_literal: true

require "securerandom"

module IdempotencyLock
  # ActiveRecord model for storing idempotency locks.
  #
  # This model expects a database table with the following schema:
  #   - name: string (unique, indexed, max 255 chars)
  #   - owner_token: string (random token identifying the current holder)
  #   - expires_at: datetime (nullable, indexed)
  #   - executed_at: datetime (when the lock was acquired / the block started)
  #   - created_at: datetime
  #   - updated_at: datetime
  #
  # Use the provided generators to create the migration:
  #   rails generate idempotency_lock:install   # new installs
  #   rails generate idempotency_lock:upgrade   # upgrading from < 0.3.0
  #
  class Lock < ActiveRecord::Base
    self.table_name = "idempotency_locks"

    MAX_NAME_LENGTH = IdempotencyLock::MAX_NAME_LENGTH

    # Uniqueness is enforced by the unique index on `name`, not by a
    # validation, so acquiring a lock is a single INSERT rather than a
    # SELECT followed by an INSERT.
    validates :name, presence: true, length: { maximum: MAX_NAME_LENGTH }

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
      #
      # @param name [String] unique identifier for the operation
      # @param expires_at [Time, nil] when the lock should expire (nil = never)
      # @param now [Time] current time reference (injectable for testing)
      # @return [String, nil] an owner token if the lock was acquired, nil otherwise.
      #   Pass the token to {release} so only the holder can release the lock.
      def acquire(name, expires_at: nil, now: Time.current)
        token = SecureRandom.uuid
        return token if insert_lock(name, token, expires_at, now)

        claim_expired(name, token, expires_at, now) ? token : nil
      end

      # Release a lock by name.
      #
      # When `owner_token` is given, the lock is only removed if it is still
      # held by that owner. This prevents a holder whose lock expired (and was
      # claimed by someone else) from deleting the new holder's lock.
      #
      # @param name [String] unique identifier for the operation
      # @param owner_token [String, nil] token returned by {acquire}; nil forces release
      # @return [Boolean] true if a lock was removed
      def release(name, owner_token: nil)
        scope = where(name: name)
        scope = scope.where(owner_token: owner_token) if owner_token
        scope.delete_all.positive?
      end

      # Check if a valid (non-expired) lock exists for the given name
      #
      # @param name [String] unique identifier for the operation
      # @return [Boolean]
      def locked?(name, now: Time.current)
        lock = find_by(name: name)
        return false if lock.nil?

        lock.valid_lock?(now: now)
      end

      # Clean up expired locks
      #
      # @return [Integer] number of locks removed
      def cleanup_expired(now: Time.current)
        where("expires_at IS NOT NULL AND expires_at < ?", now).delete_all
      end

      private

      # Insert a new lock row. Runs inside a savepoint so that a unique
      # violation does not abort an enclosing transaction (PostgreSQL marks the
      # whole transaction as failed after any error otherwise).
      def insert_lock(name, token, expires_at, now)
        transaction(requires_new: true) do
          create!(name: name, owner_token: token, expires_at: expires_at, executed_at: now)
        end
        true
      rescue ActiveRecord::RecordNotUnique
        false
      end

      # Claim an existing lock if it has expired.
      #
      # Uses the observed owner_token as an optimistic-lock version: if two
      # processes both see the same expired lock, only one UPDATE matches and
      # the other affects 0 rows. Every acquisition writes a fresh random
      # token, so the version always changes (no timestamp precision issues).
      def claim_expired(name, token, expires_at, now)
        existing = find_by(name: name)
        return false if existing.nil? || !existing.expired?(now: now)

        where(name: name, owner_token: existing.owner_token)
          .update_all(owner_token: token, expires_at: expires_at, executed_at: now, updated_at: now)
          .positive?
      end
    end
  end
end
