# frozen_string_literal: true

module IdempotencyLock
  # Represents the result of an idempotency operation.
  #
  # @example Checking if the block was executed
  #   result = IdempotencyLock.once("my-operation") { expensive_work }
  #   if result.executed?
  #     puts "Operation ran, got: #{result.value}"
  #   else
  #     puts "Operation was skipped (already ran)"
  #   end
  #
  class Result
    attr_reader :value, :error

    def initialize(executed:, value: nil, skipped: false, error: nil)
      @executed = executed
      @value = value
      @skipped = skipped
      @error = error
    end

    # @return [Boolean] true if the block was executed
    def executed?
      @executed
    end

    # @return [Boolean] true if the operation was skipped due to existing lock
    def skipped?
      @skipped
    end

    # @return [Boolean] true if an error occurred during execution
    def error?
      !@error.nil?
    end

    # @return [Boolean] true if executed successfully without error
    def success?
      @executed && !error?
    end

    # @return [String] human-readable representation for debugging
    def inspect
      parts = ["executed=#{@executed}"]
      parts << "skipped=#{@skipped}" if @skipped
      parts << "value=#{@value.inspect}" if @value
      parts << "error=#{@error.class}" if @error
      "#<IdempotencyLock::Result #{parts.join(" ")}>"
    end
  end
end
