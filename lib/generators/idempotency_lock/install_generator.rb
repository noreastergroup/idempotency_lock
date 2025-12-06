# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module IdempotencyLock
  module Generators
    # Generator to create the idempotency_locks table migration.
    # Run with: rails generate idempotency_lock:install
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates the idempotency_locks table migration"

      def create_migration_file
        migration_template(
          "create_idempotency_locks.rb.erb",
          "db/migrate/create_idempotency_locks.rb"
        )
      end

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
