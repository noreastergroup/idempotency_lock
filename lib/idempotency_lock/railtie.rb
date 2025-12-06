# frozen_string_literal: true

module IdempotencyLock
  # Rails integration for IdempotencyLock.
  # Automatically configures the logger and loads generators.
  class Railtie < Rails::Railtie
    generators do
      require_relative "../generators/idempotency_lock/install_generator"
    end

    initializer "idempotency_lock.configure" do
      IdempotencyLock.logger = Rails.logger
    end
  end
end
