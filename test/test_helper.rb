# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "erb"
require "fileutils"
require "logger"
require "tmpdir"
require "active_record"
require "active_support/all"
require "idempotency_lock"
require "minitest/autorun"
require "minitest/mock"

# Database selection:
#   - DATABASE_URL set (CI for PostgreSQL / MySQL): use it.
#   - Otherwise: a file-backed SQLite database in a temp dir. File-backed rather
#     than :memory: so that multiple connections (threads) share the same data.
if ENV["DATABASE_URL"]
  ActiveRecord::Base.establish_connection(ENV.fetch("DATABASE_URL"))
else
  tmp_dir = Dir.mktmpdir("idempotency_lock_test")
  Minitest.after_run { FileUtils.remove_entry(tmp_dir) }
  ActiveRecord::Base.establish_connection(
    adapter: "sqlite3",
    database: File.join(tmp_dir, "test.sqlite3"),
    pool: 20,
    timeout: 10_000
  )
end

ActiveRecord::Base.logger = Logger.new(nil)
ActiveRecord::Migration.verbose = false

# Build the schema from the install generator's migration template, so the
# tests always run against exactly what users get.
module IdempotencyLockTestSchema
  TEMPLATES = File.expand_path("../lib/generators/idempotency_lock/templates", __dir__)

  def self.load_migration(template_name)
    migration_version = "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
    source = ERB.new(File.read(File.join(TEMPLATES, template_name))).result_with_hash(migration_version:)
    class_name = template_name.delete_suffix(".rb.erb").camelize
    Object.send(:remove_const, class_name) if Object.const_defined?(class_name, false)
    Dir.mktmpdir do |dir|
      path = File.join(dir, template_name.delete_suffix(".erb"))
      File.write(path, source)
      load path
    end
  end

  def self.create!
    ActiveRecord::Base.connection.drop_table(:idempotency_locks, if_exists: true)
    load_migration("create_idempotency_locks.rb.erb")
    CreateIdempotencyLocks.new.migrate(:up)
  end
end

IdempotencyLockTestSchema.create!

# Configure IdempotencyLock to use a nil logger during tests
IdempotencyLock.logger = nil

module IdempotencyLockTestHelpers
  def setup
    IdempotencyLock::Lock.delete_all
  end

  def teardown
    IdempotencyLock::Lock.delete_all
  end
end
