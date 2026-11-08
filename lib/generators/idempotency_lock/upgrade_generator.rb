# frozen_string_literal: true

require_relative "migration_generator_helpers"

module IdempotencyLock
  module Generators
    # Generator for existing installs upgrading to 0.3.0+: adds the
    # owner_token column used to make lock release owner-safe.
    # Run with: rails generate idempotency_lock:upgrade
    class UpgradeGenerator < Rails::Generators::Base
      include MigrationGeneratorHelpers

      desc "Adds the owner_token column required by idempotency_lock >= 0.3.0"

      def create_migration_file
        migration_template(
          "add_owner_token_to_idempotency_locks.rb.erb",
          "db/migrate/add_owner_token_to_idempotency_locks.rb"
        )
      end
    end
  end
end
