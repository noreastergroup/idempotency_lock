# frozen_string_literal: true

require_relative "migration_generator_helpers"

module IdempotencyLock
  module Generators
    # Generator to create the idempotency_locks table migration.
    # Run with: rails generate idempotency_lock:install
    class InstallGenerator < Rails::Generators::Base
      include MigrationGeneratorHelpers

      desc "Creates the idempotency_locks table migration"

      def create_migration_file
        migration_template(
          "create_idempotency_locks.rb.erb",
          "db/migrate/create_idempotency_locks.rb"
        )
      end
    end
  end
end
