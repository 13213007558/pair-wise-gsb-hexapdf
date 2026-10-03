# -*- encoding: utf-8; frozen_string_literal: true -*-

require 'hexapdf/error'
require 'hexapdf/type/function'
require 'hexapdf/type/functions/post_script_calculator_function'

module HexaPDF
  module Type

    # Dispatcher for PDF function objects.
    #
    # PDF functions (see HexaPDF::Type::Function) come in several varieties which are
    # distinguished by their /FunctionType entry. This module maps a function dictionary or
    # stream to the specific function class.
    #
    # See: PDF2.0 s7.10
    module Functions

      # Returns the specific HexaPDF::Type::Function object for the given function
      # dictionary or stream.
      #
      # Currently only the PostScript calculator function (/FunctionType 4) is supported;
      # for all other function types an error is raised.
      def self.get(function)
        case function[:FunctionType]
        when 4
          if function.kind_of?(PostScriptCalculatorFunction)
            function
          elsif function.kind_of?(HexaPDF::Object) && function.document
            function.document.wrap(function, type: PostScriptCalculatorFunction)
          else
            PostScriptCalculatorFunction.new(function.kind_of?(HexaPDF::Object) ? function.data : function)
          end
        else
          raise HexaPDF::Error, "unsupported function type: #{function[:FunctionType].inspect}"
        end
      end

    end

  end
end
