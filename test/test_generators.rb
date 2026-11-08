# frozen_string_literal: true

require "test_helper"
require "open3"

class TestIdempotencyLockGenerators < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  def test_install_generator_creates_migration_with_owner_token
    migration = generate("Install", "create_idempotency_locks")

    assert_match(/class CreateIdempotencyLocks < ActiveRecord::Migration\[\d+\.\d+\]/, migration)
    assert_includes migration, "t.string :owner_token"
  end

  def test_upgrade_generator_creates_add_column_migration
    migration = generate("Upgrade", "add_owner_token_to_idempotency_locks")

    assert_match(/class AddOwnerTokenToIdempotencyLocks < ActiveRecord::Migration\[\d+\.\d+\]/, migration)
    assert_includes migration, "add_column :idempotency_locks, :owner_token"
  end

  # Runs the real upgrade migration against a pre-0.3.0 table.
  def test_upgrade_migration_adds_owner_token_column
    connection = ActiveRecord::Base.connection
    connection.remove_column(:idempotency_locks, :owner_token)
    IdempotencyLockTestSchema.load_migration("add_owner_token_to_idempotency_locks.rb.erb")
    AddOwnerTokenToIdempotencyLocks.new.migrate(:up)

    assert connection.column_exists?(:idempotency_locks, :owner_token)
  ensure
    IdempotencyLockTestSchema.create!
    IdempotencyLock::Lock.reset_column_information
  end

  private

  # Generators run in a subprocess so loading Rails doesn't leak into the
  # other tests (e.g. `defined?(Rails)` checks).
  def generate(kind, file_suffix)
    Dir.mktmpdir do |dir|
      script = <<~RUBY
        require "rails/generators"
        require "idempotency_lock"
        require "generators/idempotency_lock/#{kind.downcase}_generator"
        IdempotencyLock::Generators::#{kind}Generator.start(["--quiet"], destination_root: ARGV.fetch(0))
      RUBY
      output, status = Open3.capture2e(RbConfig.ruby, "-I", LIB, "-e", script, dir)

      assert_predicate status, :success?, output
      files = Dir[File.join(dir, "db/migrate/*_#{file_suffix}.rb")]

      assert_equal 1, files.size, "expected one migration, got #{files.inspect}\n#{output}"
      source = File.read(files.first)
      syntax, = Open3.capture2e(RbConfig.ruby, "-c", stdin_data: source)

      assert_includes syntax, "Syntax OK"
      source
    end
  end
end
