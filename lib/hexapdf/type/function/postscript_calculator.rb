# -*- encoding: utf-8; frozen_string_literal: true -*-
#
#--
# This file is part of HexaPDF.
#
# HexaPDF - A Versatile PDF Creation and Manipulation Library For Ruby
# Copyright (C) 2014-2026 Thomas Leitner
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

require 'strscan'
require 'hexapdf/error'

module HexaPDF
  module Type
    class Function < Stream

      # Implements the PostScript language subset used by Type 4 (PostScript calculator)
      # functions.
      #
      # The program is parsed once and, for every #evaluate call, walked with a fresh operand
      # stack. The program code is never handed to Ruby's +eval+ or similar mechanisms.
      #
      # The integer, real and boolean types are kept strictly separate: an operator that expects
      # an integer rejects a real value or a boolean and vice versa. Arithmetic between an integer
      # and a real always yields a real. See PDF2.0 s7.10.4 for the list of supported operators.
      class PostScriptCalculator

        # The default maximum number of instructions (pushed literals and executed operators)
        # processed during a single evaluation. This prevents runaway calculations (e.g. endless
        # recursion through nested procedures) from consuming unbounded resources.
        DEFAULT_MAX_INSTRUCTIONS = 100_000

        # Raised when a calculator function is invalid or cannot be evaluated.
        class Error < HexaPDF::Error; end

        WHITE_SPACE_RE = /[\x00\t\n\f\r ]+/
        COMMENT_RE = /%[^\n\f]*/
        NUMBER_RE = /[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eEdD][+-]?\d+)?(?![\w.])/
        OPERATOR_RE = /[^\x00\t\n\f\r ()<>{}\[\]\/%]+/

        # Creates a new calculator for the given PostScript +program+ string.
        #
        # The optional +max_instructions+ limits the number of instructions processed per
        # evaluation.
        def initialize(program, max_instructions: DEFAULT_MAX_INSTRUCTIONS)
          @max_instructions = max_instructions
          @program = parse(program.to_s)
        end

        # Evaluates the program using the given initial operand stack +values+ and returns the
        # resulting operand stack (the bottom-most value first).
        #
        # A new operand stack is created for every invocation so neither successful nor failed
        # evaluations leave state behind.
        def evaluate(values = [])
          stack = values.dup
          counter = [0]
          # The execution frames hold the instruction sequences and the next index to process.
          # An explicit stack is used so deeply nested procedures cannot overflow the stack.
          frames = [[@program, 0]]
          until frames.empty?
            instructions, index = frames.last
            if index >= instructions.length
              frames.pop
              next
            end
            instruction = instructions[index]
            frames.last[1] += 1
            bump_counter(counter)

            case instruction
            when Array, Integer, Float, true, false
              stack << instruction
            when String
              execute_operator(instruction, stack, frames, counter)
            else
              raise Error, "Invalid token #{instruction.inspect} in PostScript calculator function"
            end
          end
          stack
        end

        private

        # Parses the program string into integers, floats, booleans, nested procedure arrays and
        # operator name strings.
        def parse(string)
          scanner = StringScanner.new(string)
          skip_separators(scanner)
          tokens = []
          return tokens if scanner.eos?
          # The whole program is conventionally enclosed in one pair of braces. The braces are
          # handled with an explicit stack (instead of recursion) so deeply nested procedures
          # cannot cause a stack overflow.
          stack = [tokens]
          expect_outer_close = scanner.peek(1) == '{'
          scanner.get_byte if expect_outer_close

          until scanner.eos?
            skip_separators(scanner)
            break if scanner.eos?

            character = scanner.get_byte
            case character
            when '{'
              procedure = []
              stack.last << procedure
              stack << procedure
            when '}'
              if expect_outer_close && stack.length == 1
                expect_outer_close = false
                skip_separators(scanner)
                unless scanner.eos?
                  raise Error, "Unexpected token #{scanner.rest.inspect} in PostScript " \
                               'calculator function'
                end
              elsif stack.length == 1
                raise Error, 'Unmatched closing brace in PostScript calculator function'
              else
                stack.pop
              end
            when '(', '<', '['
              raise Error, 'Unsupported syntax in PostScript calculator function: only numbers, '
                           'booleans, operator names and brace-delimited procedures are allowed'
            else
              scanner.pos -= 1
              if scanner.match?(NUMBER_RE)
                stack.last << parse_number(scanner.scan(NUMBER_RE))
              elsif (operator = scanner.scan(OPERATOR_RE))
                case operator
                when 'true' then stack.last << true
                when 'false' then stack.last << false
                else stack.last << operator
                end
              else
                raise Error, "Unexpected character #{scanner.get_byte.inspect} in PostScript "
                           'calculator function'
              end
            end
          end

          if expect_outer_close || stack.length != 1
            raise Error, 'Unmatched opening brace in PostScript calculator function'
          end
          tokens
        end

        # Skips whitespace and comments.
        def skip_separators(scanner)
          nil while scanner.skip(WHITE_SPACE_RE) || scanner.skip(COMMENT_RE)
        end

        # Converts a scanned number token into an Integer or Float, preserving the integer/real
        # distinction from the source.
        def parse_number(token)
          if token.match?(/[.eEdD]/)
            Float(token.gsub(/[dD]/, 'e'))
          else
            Integer(token, 10)
          end
        rescue ArgumentError
          raise Error, "Invalid number #{token.inspect} in PostScript calculator function"
        end

        # Raises an error if the execution budget is exhausted.
        def bump_counter(counter)
          counter[0] += 1
          return unless counter[0] > @max_instructions
          raise Error, 'PostScript calculator function exceeded the execution budget of '
                       "#{@max_instructions} instructions"
        end

        # Executes a single operator on the operand stack.
        def execute_operator(operator, stack, frames, counter)
          case operator
          when 'add' then binary_numeric(stack, operator) {|a, b| a + b }
          when 'sub' then binary_numeric(stack, operator) {|a, b| a - b }
          when 'mul' then binary_numeric(stack, operator) {|a, b| a * b }
          when 'div' then binary_real(stack, operator) {|a, b| a.to_f / b }
          when 'idiv'
            a, b = two_integers(stack, operator)
            raise_zero_division(operator) if b == 0
            stack << (a.quo(b).truncate)
          when 'mod'
            a, b = two_integers(stack, operator)
            raise_zero_division(operator) if b == 0
            stack << (a - b * (a.quo(b).truncate))
          when 'neg' then unary_numeric(stack, operator, &:-@)
          when 'abs'
            value = one_numeric(stack, operator)
            stack << (value < 0 ? -value : value)
          when 'ceiling'
            value = one_numeric(stack, operator)
            stack << (value.kind_of?(Integer) ? value : value.ceil)
          when 'floor'
            value = one_numeric(stack, operator)
            stack << (value.kind_of?(Integer) ? value : value.floor)
          when 'round'
            value = one_numeric(stack, operator)
            stack << (value.kind_of?(Integer) ? value : value.round)
          when 'truncate'
            value = one_numeric(stack, operator)
            stack << (value.kind_of?(Integer) ? value : value.truncate)
          when 'sqrt'
            value = one_numeric_non_negative(stack, operator)
            stack << Math.sqrt(value)
          when 'sin' then stack << Math.sin(to_radians(one_numeric(stack, operator)))
          when 'cos' then stack << Math.cos(to_radians(one_numeric(stack, operator)))
          when 'atan'
            numerator, denominator = two_numerics(stack, operator)
            if denominator == 0
              stack << (numerator >= 0 ? 90.0 : 270.0)
            else
              stack << Math.atan2(numerator.to_f, denominator.to_f) * 180.0 / Math::PI
            end
          when 'exp'
            base, exponent = two_numerics(stack, operator)
            result = base.to_f ** exponent.to_f
            unless result.kind_of?(Float) && result.finite?
              raise Error, "Result of operator 'exp' is not finite"
            end
            stack << result
          when 'ln'
            value = one_numeric_positive(stack, operator)
            stack << Math.log(value.to_f)
          when 'log'
            value = one_numeric_positive(stack, operator)
            stack << Math.log10(value.to_f)
          when 'cvi' then stack << one_numeric(stack, operator).truncate
          when 'cvr' then stack << one_numeric(stack, operator).to_f
          when 'eq' then stack << (two_values(stack, operator).reduce(:==))
          when 'ne' then stack << (!two_values(stack, operator).reduce(:==))
          when 'gt' then stack << comparison(stack, operator, :>)
          when 'ge' then stack << comparison(stack, operator, :>=)
          when 'lt' then stack << comparison(stack, operator, :<)
          when 'le' then stack << comparison(stack, operator, :<=)
          when 'and'
            a, b = two_booleans(stack, operator)
            stack << (a && b)
          when 'or'
            a, b = two_booleans(stack, operator)
            stack << (a || b)
          when 'xor'
            a, b = two_booleans(stack, operator)
            stack << (a != b)
          when 'not' then stack << (!one_boolean(stack, operator))
          when 'bitshift'
            value, shift = two_integers(stack, operator)
            if shift < -65_536 || shift > 65_536
              raise Error, "Invalid shift amount #{shift} for operator 'bitshift'"
            end
            stack << (shift >= 0 ? (value << shift) : (value >> -shift))
          when 'if'
            procedure = one_procedure(stack)
            condition = one_boolean(stack, operator)
            frames << [procedure, 0] if condition
          when 'ifelse'
            false_procedure = one_procedure(stack)
            true_procedure = one_procedure(stack)
            condition = one_boolean(stack, operator)
            frames << [condition ? true_procedure : false_procedure, 0]
          when 'pop' then pop_stack(stack, operator)
          when 'exch'
            a, b = two_values(stack, operator)
            stack.push(a, b)
          when 'dup'
            value = pop_stack(stack, operator)
            stack.push(value, value)
          when 'copy'
            count = one_integer(stack, operator)
            if count < 0
              raise Error, "Invalid count #{count} for operator 'copy'"
            end
            ensure_stack_size(stack, count, operator)
            stack.concat(stack.last(count))
          when 'index'
            index = one_integer(stack, operator)
            if index < 0
              raise Error, "Invalid index #{index} for operator 'index'"
            end
            ensure_stack_size(stack, index + 1, operator)
            stack << stack[-index - 1]
          when 'roll'
            ensure_stack_size(stack, 2, operator)
            amount = one_integer(stack, operator)
            count = one_integer(stack, operator)
            if count < 0
              raise Error, "Invalid count #{count} for operator 'roll'"
            end
            ensure_stack_size(stack, count, operator)
            unless count == 0
              portion = stack.pop(count)
              stack.concat(portion.rotate(amount))
            end
          when 'clear' then stack.clear
          when 'count' then stack << stack.length
          else
            raise Error, "Unsupported operator #{operator.inspect} in PostScript calculator function"
          end
        end

        # Pops the top value of the stack or raises an error if the stack is empty.
        def pop_stack(stack, operator)
          raise_underflow(operator) if stack.empty?
          stack.pop
        end

        # Pops two values (top-most value second in the returned array).
        def two_values(stack, operator)
          ensure_stack_size(stack, 2, operator)
          [stack.pop, stack.pop]
        end

        # Pops one value and checks that it is numeric (integer or real, but not boolean).
        def one_numeric(stack, operator)
          value = pop_stack(stack, operator)
          ensure_kind(value, Numeric, operator)
          value
        end

        # Pops two numeric values.
        def two_numerics(stack, operator)
          b = one_numeric(stack, operator)
          a = one_numeric(stack, operator)
          [a, b]
        end

        # Pops one integer value.
        def one_integer(stack, operator)
          value = pop_stack(stack, operator)
          ensure_kind(value, Integer, operator)
          value
        end

        # Pops two integer values.
        def two_integers(stack, operator)
          b = one_integer(stack, operator)
          a = one_integer(stack, operator)
          [a, b]
        end

        # Pops one boolean value.
        def one_boolean(stack, operator)
          value = pop_stack(stack, operator)
          unless value == true || value == false
            raise Error, "Invalid operand type #{value.class} for operator '#{operator}': expected boolean"
          end
          value
        end

        # Pops two boolean values.
        def two_booleans(stack, operator)
          b = one_boolean(stack, operator)
          a = one_boolean(stack, operator)
          [a, b]
        end

        # Pops a procedure (parsed brace-delimited block).
        def one_procedure(stack)
          value = pop_stack(stack, 'procedure')
          unless value.kind_of?(Array)
            raise Error, "Invalid operand type #{value.class} for procedure: expected procedure"
          end
          value
        end

        # Pops one non-negative numeric value.
        def one_numeric_non_negative(stack, operator)
          value = one_numeric(stack, operator)
          if value < 0
            raise Error, "Invalid operand #{value} for operator '#{operator}': value must not be negative"
          end
          value
        end

        # Pops one strictly positive numeric value.
        def one_numeric_positive(stack, operator)
          value = one_numeric(stack, operator)
          if value <= 0
            raise Error, "Invalid operand #{value} for operator '#{operator}': value must be positive"
          end
          value
        end

        # Applies the binary operation, converting the result to a real if either operand is one.
        def binary_numeric(stack, operator, &operation)
          a, b = two_numerics(stack, operator)
          result = operation.call(a, b)
          stack << (a.kind_of?(Float) || b.kind_of?(Float) ? result.to_f : result)
        end

        # Applies a binary operation that always yields a real result (division).
        def binary_real(stack, operator, &operation)
          a, b = two_numerics(stack, operator)
          raise_zero_division(operator) if b == 0
          stack << operation.call(a, b)
        end

        # Applies an unary numeric operation, preserving the integer/real type.
        def unary_numeric(stack, operator, &operation)
          value = one_numeric(stack, operator)
          result = operation.call(value)
          stack << (value.kind_of?(Float) ? result.to_f : result)
        end

        # Performs an ordering comparison on two numeric values.
        def comparison(stack, operator, method)
          a, b = two_numerics(stack, operator)
          a.public_send(method, b)
        end

        # Raises an error unless the stack contains at least +needed+ values.
        def ensure_stack_size(stack, needed, operator)
          if stack.length < needed
            raise_underflow(operator)
          end
        end

        # Raises a type error for the given value.
        def ensure_kind(value, klass, operator)
          unless value.kind_of?(klass)
            raise Error, "Invalid operand type #{value.class} for operator '#{operator}': expected #{klass}"
          end
        end

        # Raises a stack underflow error.
        def raise_underflow(operator)
          raise Error, "Not enough operands on the stack for operator '#{operator}'"
        end

        # Raises a division by zero error.
        def raise_zero_division(operator)
          raise Error, "Division by zero in operator '#{operator}'"
        end

        # Converts an angle in degrees to radians.
        def to_radians(value)
          value.to_f * Math::PI / 180.0
        end

      end

    end
  end
end
