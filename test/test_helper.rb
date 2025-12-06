# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "active_record"
require "active_support/all"
require "idempotency_lock"
require "minitest/autorun"

# Set up in-memory SQLite database for testing
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:"
)

# Create the idempotency_locks table
ActiveRecord::Schema.define do
  create_table :idempotency_locks, force: true do |t|
    t.string :name, null: false, limit: 255
    t.datetime :expires_at
    t.datetime :executed_at
    t.timestamps
  end

  add_index :idempotency_locks, :name, unique: true
end

# Silence ActiveRecord logging during tests
ActiveRecord::Base.logger = Logger.new(nil)

# Configure IdempotencyLock to use a nil logger during tests
IdempotencyLock.logger = nil

module IdempotencyLockTestHelpers
  def setup
    # Clean up locks between tests
    IdempotencyLock::Lock.delete_all
  end
end
