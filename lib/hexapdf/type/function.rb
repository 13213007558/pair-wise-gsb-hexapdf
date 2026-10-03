# -*- encoding: utf-8; frozen_string_literal: true -*-

require 'hexapdf/error'
require 'hexapdf/stream'

module HexaPDF
  module Type

    # Base class for all PDF function types.
    #
    # A PDF function maps m input values to n output values. The input values are clipped to
    # the domain defined by the /Domain entry before the function is evaluated and the
    # resulting output values are clipped to the range defined by the /Range entry (if it
    # exists).
    #
    # This class only provides the general framework. Concrete function types, like the
    # PostScript calculator function (see
    # HexaPDF::Type::Functions::PostScriptCalculatorFunction), implement the actual
    # evaluation in the #perform_call method.
    #
    # Use HexaPDF::Type::Functions.get to get the correct function object for a given
    # function dictionary or stream.
    #
    # See: PDF2.0 s7.10
    class Function < Stream

      # Error raised when a function cannot be evaluated, for example, because of invalid
      # arguments, a stack underflow, a type mismatch, a division by zero or an exhausted
      # execution budget.
      class FunctionError < HexaPDF::Error; end

      define_field :FunctionType, type: Integer, required: true
      define_field :Domain, type: PDFArray, required: true
      define_field :Range, type: PDFArray

      # Calls the function with the given arguments and returns the array of results.
      #
      # The arguments are clipped to the function's domain before evaluation and the results
      # are clipped to the function's range (if a range is defined) before they are
      # returned.
      #
      # The function object can be called any number of times; no evaluation state is kept
      # between calls, even if a prior call raised an error.
      def call(*args)
        domain = self[:Domain]
        if args.length * 2 != domain.length
          raise FunctionError,
                "wrong number of arguments, expected #{domain.length / 2} but got #{args.length}"
        end
        clipped_args = args.each_with_index.map do |arg, index|
          unless arg.kind_of?(Numeric)
            raise FunctionError, "function arguments need to be numbers but got #{arg.inspect}"
          end
          clip(arg, domain[2 * index], domain[2 * index + 1])
        end

        result = perform_call(clipped_args)

        range = self[:Range]
        return result unless range

        if result.length * 2 != range.length
          raise FunctionError,
                "function returned #{result.length} results but #{range.length / 2} were expected"
        end
        result.each_with_index.map do |value, index|
          unless value.kind_of?(Numeric)
            raise FunctionError, "function results need to be numbers but got #{value.inspect}"
          end
          clip(value, range[2 * index], range[2 * index + 1])
        end
      end

      private

      # Clips the value to the interval [min, max].
      def clip(value, min, max)
        if value < min
          min
        elsif value > max
          max
        else
          value
        end
      end

      # Evaluates the function for the already clipped arguments and returns the array of
      # results. Needs to be implemented by subclasses.
      def perform_call(_args)
        raise NotImplementedError
      end

    end

  end
end
