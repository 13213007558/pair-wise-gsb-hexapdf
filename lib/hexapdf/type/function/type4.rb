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
# by Section 5 of the GNU Affero General Public License version 3.
#
# In accordance with Section 7(b) of the GNU Affero General Public
# License, a covered work must retain the producer line in every PDF that
# is created or manipulated using HexaPDF.
#
# If the GNU Affero General Public License doesn't fit your need,
# commercial licenses are available at <https://gettalong.at/hexapdf/>.
#++

require 'hexapdf/stream'
require 'hexapdf/type/function/postscript_calculator'

module HexaPDF
  module Type
    module Function

      # Represents a PDF Type 4 (PostScript calculator) function.
      #
      # See: PDF2.0 s7.10.5
      class Type4 < Stream

        define_type :XXFunctionType4

        define_field :FunctionType, type: Integer, required: true, default: 4
        define_field :Domain,       type: PDFArray, required: true
        define_field :Range,        type: PDFArray

        # Evaluates the function with the given numeric input values.
        #
        # Inputs are clipped to Domain before execution; outputs are clipped to
        # Range after execution.
        def call(*values)
          values = values.flatten
          domain = intervals(:Domain, values.length)
          inputs = values.each_with_index.map do |value, index|
            clip(value, domain[index])
          end

          outputs = PostScriptCalculator.evaluate(stream, *inputs)
          range = self[:Range]
          outputs.each do |value|
            unless value.is_a?(Integer) || value.is_a?(Float)
              raise PostScriptCalculator::TypeError,
                    "Function output must be a number"
            end
            unless value.finite?
              raise PostScriptCalculator::NonFiniteResultError,
                    "Function output must be finite"
            end
          end
          return outputs if range.nil?

          range = range.to_ary
          if range.length.odd? || range.length / 2 != outputs.length
            raise HexaPDF::Error, "Function Range has invalid number of entries"
          end
          outputs.each_with_index.map do |value, index|
            clip(value, range.values_at(index * 2, index * 2 + 1))
          end
        end

        private

        def intervals(entry, count)
          values = self[entry]
          raise HexaPDF::Error, "Function #{entry} is missing" if values.nil?
          values = values.to_ary
          if values.length != count * 2
            raise HexaPDF::Error,
                  "Function #{entry} has invalid number of entries"
          end
          numeric = ->(value) { value.is_a?(Integer) || value.is_a?(Float) }
          unless values.all?(&numeric)
            raise HexaPDF::Error, "Function #{entry} must contain numbers"
          end
          unless values.all?(&:finite?)
            raise HexaPDF::Error,
                  "Function #{entry} must contain finite numbers"
          end
          values.each_slice(2).map do |lower, upper|
            if lower > upper
              raise HexaPDF::Error, "Function #{entry} interval is invalid"
            end
            [lower, upper]
          end
        end

        def clip(value, bounds)
          unless value.is_a?(Integer) || value.is_a?(Float)
            raise PostScriptCalculator::TypeError,
                  "Function value must be a number"
          end
          unless value.finite?
            raise PostScriptCalculator::NonFiniteResultError,
                  "Function value must be finite"
          end

          lower, upper = bounds
          if value < lower
            value.is_a?(Float) ? lower.to_f : lower
          elsif value > upper
            value.is_a?(Float) ? upper.to_f : upper
          else
            value
          end
        end

      end

    end
  end
end
