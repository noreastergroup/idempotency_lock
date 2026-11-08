# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module IdempotencyLock
  module Generators
    # Shared setup for the gem's migration generators.
    module MigrationGeneratorHelpers
      def self.included(base)
        base.include ActiveRecord::Generators::Migration
        base.source_root File.expand_path("templates", __dir__)
      end

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
