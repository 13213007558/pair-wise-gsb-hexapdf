# -*- encoding: utf-8; frozen_string_literal: true -*-
#
#--
# This file is part of HexaPDF.
#
# HexaPDF is free software: you can redistribute it and/or modify it
# under the terms of the GNU Affero General Public License version 3 as
# published by the Free Software Foundation with the addition of the
# following permission added to Section 15 as permitted in Section 7(a):
# FOR ANY PART OF THE COVERED WORK IN WHICH THE COPYRIGHT IS OWNED BY
# THOMAS LEITNER, THOMAS LEITNER DISCLAIMS THE WARRANTY OF NON
# INFRINGEMENT OF THIRD PARTY RIGHTS.
#
# HexaPDF is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public
# License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with HexaPDF. If not, see <http://www.gnu.org/licenses/>.
#
# The interactive user interfaces in modified source and object code
# versions of HexaPDF must display Appropriate Legal Notices, as required
# under Section 5 of the GNU Affero General Public License version 3.
#
# In accordance with Section 7(b) of the GNU Affero General Public
# License, a covered work must retain the producer line in every PDF that
# is created or manipulated using HexaPDF.
#
# If the GNU Affero General Public License doesn't fit your need,
# commercial licenses are available at <https://gettalong.at/hexapdf/>.
#++

require 'hexapdf/error'

module HexaPDF
  module Type

    # Evaluates PDF type 2 and type 3 functions.
    #
    # This evaluator intentionally works on already wrapped or unwrapped dictionaries. It is used by
    # shading code where input values are interpolated before a function is evaluated.
    #
    # See: PDF2.0 s7.10
    class Function

      # Creates a function evaluator for a single function dictionary or an array of functions.
      def self.for(functions)
        array = Array(functions)
        raise HexaPDF::Error, 'No PDF function specified' if array.empty?
        new(array)
      end

      # Creates a new evaluator for the given function dictionaries.
      def initialize(functions)
        @functions = functions
      end

      # Evaluates the function or function array with the given input values.
      def evaluate(inputs)
        @functions.flat_map do |function|
          Array(evaluate_one(function, inputs))
        end
      end

      private

      def evaluate_one(function, inputs)
        type = function[:FunctionType]
        normalized = clip(inputs, function[:Domain] || [0, 1])
        result = case type
                 when 2 then evaluate_exponential(function, normalized)
                 when 3 then evaluate_stitching(function, normalized)
                 else
                   raise HexaPDF::Error, "Unsupported PDF function type #{type.inspect}"
                 end
        clip(result, function[:Range]) if function.key?(:Range)
        result
      end

      def evaluate_exponential(function, inputs)
        c0 = Array(function[:C0] || [0.0])
        c1 = Array(function[:C1] || [1.0])
        exponent = function[:N].to_f
        inputs.product([0]).flat_map do |input, _|
          c0.zip(c1).map do |start_value, end_value|
            start_value + input ** exponent * (end_value - start_value)
          end
        end
      end

      def evaluate_stitching(function, inputs)
        functions = function[:Functions]
        bounds = Array(function[:Bounds])
        domain = function[:Domain] || [0.0, 1.0]
        input = inputs.fetch(0).clamp(domain[0], domain[1])
        index = bounds.find_index {|bound| input < bound } || functions.length - 1
        target_min, target_max = Array(function[:Encode]).each_slice(2).to_a.fetch(index)
        lower = index.zero? ? domain.fetch(0) : bounds.fetch(index - 1)
        upper = index < bounds.length ? bounds.fetch(index) : (function[:Domain] || [0, 1]).fetch(1, 1.0)
        value = target_min + (input - lower) / (upper - lower) * (target_max - target_min)
        evaluate_one(functions[index], [value])
      end

      def clip(values, pairs)
        ranges = Array(pairs).each_slice(2).to_a
        Array(values).each_with_index.map do |value, index|
          lower, upper = ranges.fetch(index)
          value.to_f.clamp(lower.to_f, upper.to_f)
        end
      end

    end

  end
end
