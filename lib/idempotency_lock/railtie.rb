# frozen_string_literal: true

module IdempotencyLock
  # Rails integration for IdempotencyLock: registers the generators.
  #
  # Logging defaults to Rails.logger (see IdempotencyLock.logger), so no
  # initializer is needed and an explicitly configured logger, including nil,
  # is never overwritten.
  class Railtie < Rails::Railtie
    generators do
      require_relative "../generators/idempotency_lock/install_generator"
      require_relative "../generators/idempotency_lock/upgrade_generator"
    end
  end
end
