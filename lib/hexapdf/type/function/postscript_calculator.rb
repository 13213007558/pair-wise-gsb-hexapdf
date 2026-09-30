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

require 'stringio'
require 'hexapdf/error'
require 'hexapdf/tokenizer'

module HexaPDF
  module Type
    module Function

      # Implements the restricted PostScript subset for PDF Type 4 functions.
      #
      # It is not a general PostScript interpreter: it handles only numeric and
      # boolean values, executable procedures, and PDF-permitted operators.
      class PostScriptCalculator

        class Error < HexaPDF::Error; end
        class SyntaxError < Error; end
        class StackUnderflowError < Error; end
        class TypeError < Error; end
        class DivisionByZeroError < Error; end
        class NonFiniteResultError < Error; end
        class LimitError < Error; end

        MAX_TOKEN_COUNT = 10_000
        MAX_STACK_SIZE = 1_000
        MAX_OPERATION_COUNT = 100_000
        MAX_NESTING_DEPTH = 100
        MAX_INTEGER = (2 ** 31) - 1
        MIN_INTEGER = -(2 ** 31)

        OPERATORS = %w[
          add sub mul div idiv mod neg abs ceiling floor round truncate
          sqrt sin cos atan exp ln log cvi cvr
          lt gt le ge eq ne and or not xor bitshift
          pop exch dup copy index roll
          if ifelse
        ].freeze

        def self.parse(source)
          new.send(:parse, source)
        end

        def self.evaluate(source, *inputs)
          new.evaluate(source, *inputs)
        end

        def evaluate(source, *inputs)
          execute(parse(source), *inputs)
        end

        def execute(source_or_program, *inputs)
          program = if source_or_program.is_a?(String)
                      parse(source_or_program)
                    else
                      source_or_program
                    end
          unless program.is_a?(Array) &&
              program.all? do |item|
                item.is_a?(Array) || item.is_a?(String) || literal?(item)
              end
            raise TypeError, "Invalid compiled PostScript calculator program"
          end

          unless inputs.all? {|item| item.is_a?(Integer) || item.is_a?(Float) }
            raise TypeError, "PostScript calculator inputs must be numbers"
          end
          unless inputs.map(&:finite?).all?
            raise NonFiniteResultError,
                  "PostScript calculator inputs must be finite"
          end
          check_stack_size(inputs.length)

          @stack = inputs.dup
          @steps = 0
          run(program)
          @stack
        ensure
          @stack = nil
          @steps = nil
        end

        private

        def parse(source)
          unless source.is_a?(String)
            raise SyntaxError, "PostScript calculator source must be a string"
          end

          tokenizer = HexaPDF::Tokenizer.new(StringIO.new(source.b))
          first = tokenizer.next_token
          unless opening_brace?(first)
            raise SyntaxError,
                  "PostScript calculator must begin with a procedure"
          end

          parsed, = parse_items(tokenizer, 1, 1)

          loop do
            token = tokenizer.next_token
            break if token.equal?(HexaPDF::Tokenizer::NO_MORE_TOKENS)
            raise SyntaxError,
                  "PostScript calculator must contain one procedure"
          end

          parsed
        end

        def parse_items(tokenizer, token_count, depth)
          if depth > MAX_NESTING_DEPTH
            raise LimitError, "PostScript calculator nesting limit exceeded"
          end
          procedure = []
          loop do
            token = tokenizer.next_token
            if token.equal?(HexaPDF::Tokenizer::NO_MORE_TOKENS)
              raise SyntaxError, "Unclosed PostScript procedure"
            end
            token_count += 1
            if token_count > MAX_TOKEN_COUNT
              raise LimitError, "PostScript calculator is too large"
            end

            if opening_brace?(token)
              nested, token_count = parse_items(tokenizer, token_count,
                                               depth + 1)
              procedure << nested
            elsif closing_brace?(token)
              return [procedure, token_count]
            else
              procedure << validate_literal(token)
            end
          end
        end

        def validate_literal(token)
          case token
          when Integer
            check_integer(token)
            token
          when Float
            check_finite(token)
            token
          when true, false
            token
          when HexaPDF::Tokenizer::TOKEN_ARRAY_START,
               HexaPDF::Tokenizer::TOKEN_ARRAY_END
            raise SyntaxError,
                  "Arrays are not allowed in PostScript calculator functions"
          when HexaPDF::Tokenizer::Token
            if OPERATORS.include?(token)
              +token
            else
              raise SyntaxError,
                    "Invalid PostScript calculator token #{token.inspect}"
            end
          else
            raise SyntaxError,
                  "Unsupported PostScript calculator token #{token.inspect}"
          end
        end

        def literal?(item)
          item.is_a?(Integer) || item.is_a?(Float) ||
            item == true || item == false
        end

        def opening_brace?(token)
          token.is_a?(HexaPDF::Tokenizer::Token) && token == '{'
        end

        def closing_brace?(token)
          token.is_a?(HexaPDF::Tokenizer::Token) && token == '}'
        end

        def run(program)
          program.each do |item|
            if item.is_a?(Array)
              push(item)
            elsif item.is_a?(String)
              step!
              execute_operator(item)
            elsif literal?(item)
              step!
              push(item)
            else
              raise SyntaxError,
                    "Invalid PostScript calculator token #{item.inspect}"
            end
          end
        end

        def step!
          @steps += 1
          if @steps > MAX_OPERATION_COUNT
            raise LimitError, "PostScript calculator operation limit exceeded"
          end
        end

        def push(value)
          check_stack_size(@stack.length + 1) unless value.is_a?(Array)
          @stack << value
          value
        end

        def execute_operator(operator)
          case operator
          when 'add' then numeric_binary {|a, b| arithmetic_value(a + b, a, b) }
          when 'sub' then numeric_binary {|a, b| arithmetic_value(a - b, a, b) }
          when 'mul' then numeric_binary {|a, b| arithmetic_value(a * b, a, b) }
          when 'div'
            right = pop_number
            left = pop_number
            if right.zero?
              raise DivisionByZeroError, "PostScript division by zero"
            end
            finish_float(left.to_f / right)
          when 'idiv'
            right = pop_integer
            left = pop_integer
            if right.zero?
              raise DivisionByZeroError,
                    "PostScript integer division by zero"
            end
            finish_integer(left.div(right))
          when 'mod'
            right = pop_integer
            left = pop_integer
            if right.zero?
              raise DivisionByZeroError, "PostScript modulo by zero"
            end
            quotient = left.to_f / right
            finish_integer(left - (right * quotient.truncate))
          when 'neg' then numeric_unary {|v| arithmetic_value(-v, v) }
          when 'abs' then numeric_unary {|v| arithmetic_value(v.abs, v) }
          when 'ceiling' then numeric_unary {|v| integer_result(v.ceil) }
          when 'floor' then numeric_unary {|v| integer_result(v.floor) }
          when 'round'
            numeric_unary do |value|
              result = value.is_a?(Integer) ? value : round_half_away(value)
              integer_result(result)
            end
          when 'truncate' then numeric_unary {|v| integer_result(v.truncate) }
          when 'sqrt'
            numeric_unary do |value|
              if value < 0
                raise NonFiniteResultError,
                      "PostScript square root of negative number"
              end
              Math.sqrt(value)
            end
          when 'sin' then numeric_unary {|v| Math.sin(v * Math::PI / 180) }
          when 'cos' then numeric_unary {|v| Math.cos(v * Math::PI / 180) }
          when 'atan'
            x = pop_number
            y = pop_number
            if x.zero? && y.zero?
              raise NonFiniteResultError,
                    "PostScript atan is undefined for zero arguments"
            end
            finish_float(Math.atan2(y, x) * 180 / Math::PI)
          when 'exp'
            exponent = pop_number
            base = pop_number
            if exponent.is_a?(Integer)
              if base < 0
                raise NonFiniteResultError,
                      "PostScript exponentiation is undefined"
              end
              result = base ** exponent
              result = result.to_f if base.is_a?(Float)
              check_result(result)
              push(result)
            else
              if base < 0
                raise NonFiniteResultError,
                      "PostScript exponentiation is undefined"
              end
              finish_float(base ** exponent)
            end
          when 'ln'
            numeric_unary do |value|
              if value <= 0
                raise NonFiniteResultError,
                      "PostScript ln requires a positive number"
              end
              Math.log(value)
            end
          when 'log'
            numeric_unary do |value|
              if value <= 0
                raise NonFiniteResultError,
                      "PostScript log requires a positive number"
              end
              Math.log10(value)
            end
          when 'cvi' then numeric_unary {|value| integer_result(value) }
          when 'cvr' then numeric_unary {|value| value.to_f }
          when 'lt' then compare_numbers {|left, right| left < right }
          when 'gt' then compare_numbers {|left, right| left > right }
          when 'le' then compare_numbers {|left, right| left <= right }
          when 'ge' then compare_numbers {|left, right| left >= right }
          when 'eq' then compare_equality(true)
          when 'ne' then compare_equality(false)
          when 'and'
            right = pop
            left = pop
            logical_operation(left, right, boolean: ->(a, b) { a && b },
                              integer: ->(a, b) { a & b })
          when 'or'
            right = pop
            left = pop
            logical_operation(left, right, boolean: ->(a, b) { a || b },
                              integer: ->(a, b) { a | b })
          when 'not' then push(!pop_boolean)
          when 'xor'
            right = pop
            left = pop
            logical_operation(left, right, boolean: ->(a, b) { a ^ b },
                              integer: ->(a, b) { a ^ b })
          when 'bitshift'
            shift = pop_integer
            value = pop_integer
            push(bitshift(value, shift))
          when 'pop' then pop
          when 'exch'
            right = pop
            left = pop
            push(right)
            push(left)
          when 'dup'
            if @stack.empty?
              raise StackUnderflowError,
                    "PostScript calculator stack underflow"
            end
            push(@stack.last)
          when 'copy'
            count = pop_integer
            if count < 0
              raise TypeError, "PostScript copy requires a non-negative count"
            end
            if @stack.length < count
              raise StackUnderflowError,
                    "PostScript calculator stack underflow"
            end
            check_stack_size(@stack.length + count)
            @stack.concat(@stack.last(count))
          when 'index'
            index = pop_integer
            if index < 0 || index >= @stack.length
              raise StackUnderflowError, "PostScript calculator stack underflow"
            end
            push(@stack[-index - 1])
          when 'roll'
            places = pop_integer
            count = pop_integer
            if count < 0 || count > @stack.length
              raise StackUnderflowError, "PostScript calculator stack underflow"
            end
            unless places.is_a?(Integer)
              raise TypeError, "Expected integer but got #{places.class}"
            end
            @stack[@stack.length - count, count] =
              @stack.last(count).then {|items| items.rotate(-places) }
          when 'if'
            procedure = pop_procedure
            condition = pop_boolean
            run(procedure) if condition
          when 'ifelse'
            false_procedure = pop_procedure
            true_procedure = pop_procedure
            condition = pop_boolean
            run(condition ? true_procedure : false_procedure)
          else
            raise SyntaxError,
                  "Unsupported PostScript operator #{operator.inspect}"
          end
        end

        def pop(expected_class = nil)
          if @stack.empty?
            raise StackUnderflowError,
                  "PostScript calculator stack underflow"
          end
          value = @stack.pop
          if expected_class && !value.is_a?(expected_class)
            raise TypeError, "Expected #{expected_class} but got #{value.class}"
          end
          value
        end

        def pop_number
          value = pop
          unless value.is_a?(Integer) || value.is_a?(Float)
            raise TypeError, "Expected number but got #{value.class}"
          end
          value
        end

        def pop_integer
          value = pop
          unless value.is_a?(Integer)
            raise TypeError, "Expected integer but got #{value.class}"
          end
          value
        end

        def pop_boolean
          value = pop
          unless value == true || value == false
            raise TypeError, "Expected boolean but got #{value.class}"
          end
          value
        end

        def compare_numbers
          right = pop_number
          left = pop_number
          push(yield(left, right))
        end

        def logical_operation(left, right, boolean:, integer:)
          if boolean?(left) && boolean?(right)
            push(boolean.call(left, right))
          elsif left.is_a?(Integer) && right.is_a?(Integer)
            finish_integer(integer.call(left, right))
          else
            raise TypeError, "Expected two booleans or two integers"
          end
        end

        def compare_equality(expected)
          right = pop
          left = pop
          if numeric?(left) && numeric?(right)
            equality = left == right || left.to_f == right.to_f
          elsif boolean?(left) && boolean?(right)
            equality = left == right
          else
            raise TypeError, "Expected comparable values"
          end
          push((equality == expected))
        end

        def numeric?(value)
          value.is_a?(Integer) || value.is_a?(Float)
        end

        def boolean?(value)
          value == true || value == false
        end

        def arithmetic_value(result, *operands)
          operands.any?(Float) ? result.to_f : result
        end

        def integer_result(value)
          result = value.is_a?(Integer) ? value : convert_integer(value)
          check_integer(result)
          result
        end

        def convert_integer(value)
          value.truncate
        rescue FloatDomainError
          raise NonFiniteResultError,
                "PostScript calculator result is not finite"
        end

        def round_half_away(value)
          value.round(half: (value >= 0 ? :up : :down))
        end

        def finish_integer(result)
          check_integer(result)
          push(result)
        end

        def finish_float(result)
          check_finite(result)
          push(result)
        end

        def bitshift(value, shift)
          result = if shift >= 0
                     shift >= 32 ? 0 : (value << shift) & 0xffffffff
                   else
                     shift <= -32 ? (value < 0 ? -1 : 0) : value >> -shift
                   end
          result = result - 2 ** 32 if result >= 2 ** 31
          check_integer(result)
          result
        end

        def pop_procedure
          value = pop
          unless value.is_a?(Array)
            raise TypeError, "Expected procedure but got #{value.class}"
          end
          value
        end

        def numeric_binary(&block)
          right = pop_number
          left = pop_number
          result = block.call(left, right)
          check_result(result)
          push(result)
        end

        def numeric_unary(&block)
          value = pop_number
          result = block.call(value)
          check_result(result)
          push(result)
        end

        def check_result(result)
          unless result.is_a?(Integer) || result.is_a?(Float)
            raise NonFiniteResultError,
                  "PostScript operator returned #{result.class}"
          end
          check_integer(result) if result.is_a?(Integer)
          check_finite(result) if result.is_a?(Float)
        end

        def check_finite(value)
          unless value.finite?
            raise NonFiniteResultError,
                  "PostScript calculator result is not finite"
          end
        end

        def check_integer(value)
          unless value.between?(MIN_INTEGER, MAX_INTEGER)
            raise LimitError, "PostScript calculator integer is out of range"
          end
        end

        def check_stack_size(size)
          if size > MAX_STACK_SIZE
            raise LimitError, "PostScript calculator stack limit exceeded"
          end
        end

      end

    end
  end
end
