# frozen_string_literal: true

require "active_support/core_ext/object/blank"

module IdempotencyLock
  # Validation for the public API's arguments. Invalid input raises
  # ArgumentError up front instead of being mistaken for "lock already held".
  # @api private
  module Arguments
    module_function

    # @return [String] the name as a String
    def normalize_name!(name)
      unless name.is_a?(String) || name.is_a?(Symbol)
        raise ArgumentError, "Lock name must be a String or Symbol, got #{name.class}"
      end

      name = name.to_s
      # blank? (not strip.empty?) so Unicode whitespace such as U+00A0 is
      # rejected here, matching the model's presence validation.
      raise ArgumentError, "Lock name must not be blank" if name.blank?
      if name.length > MAX_NAME_LENGTH
        raise ArgumentError, "Lock name is too long (#{name.length} > #{MAX_NAME_LENGTH} characters)"
      end

      name
    end

    # ActiveSupport::Duration reports is_a?(Numeric) as true, so this accepts
    # both plain seconds and durations like 5.minutes. NaN and Infinity are
    # rejected: they can't be added to a Time.
    def validate_ttl!(ttl)
      return if ttl.nil? || (finite_number?(ttl) && ttl.positive?)

      raise ArgumentError, "ttl must be a positive number of seconds or a Duration, got #{ttl.inspect}"
    end

    # @return [Float, nil] the wait in seconds
    # NaN and Infinity are rejected: NaN would silently skip without waiting,
    # and Infinity would poll forever.
    def normalize_wait!(wait)
      return nil if wait.nil?
      return wait.to_f if finite_number?(wait) && !wait.negative?

      raise ArgumentError, "wait must be a non-negative number of seconds or a Duration, got #{wait.inspect}"
    end

    def finite_number?(value)
      value.is_a?(Numeric) && value.to_f.finite?
    end

    def validate_on_error!(on_error, strategies)
      return if strategies.include?(on_error) || on_error.respond_to?(:call)

      allowed = strategies.map(&:inspect).join(", ")
      raise ArgumentError, "on_error must be one of #{allowed} or a callable, got #{on_error.inspect}"
    end
  end
end
