# -*- encoding: utf-8; frozen_string_literal: true -*-

require 'strscan'
require 'hexapdf/type/function'

module HexaPDF
  module Type
    module Functions

      # Implements the PostScript calculator function (function type 4).
      #
      # The stream of such a function contains a fragment of PostScript code that is
      # evaluated with a stack based machine. The code is parsed into numbers, procedures
      # and operator names and then interpreted directly - the code is never handed to
      # Ruby's eval or any other dynamic code evaluation mechanism.
      #
      # All operators defined by the PDF specification are supported:
      #
      # * Arithmetic: abs add atan ceiling cos cvi cvr div exp floor idiv ln log mod mul
      #   neg round sin sqrt sub truncate
      # * Stack: copy dup exch index pop roll
      # * Relational, boolean and bitwise: and bitshift eq false ge gt le lt ne not or true
      #   xor
      # * Conditional: if ifelse (procedures may be nested arbitrarily)
      #
      # Integers, reals and booleans are distinct types and are not silently converted into
      # one another. For example, +if+ requires a boolean and +bitshift+ requires integers.
      #
      # Errors like a division by zero, a stack underflow, a type mismatch or an exhausted
      # execution budget (see #max_execution_steps) are reported by raising
      # HexaPDF::Type::Function::FunctionError.
      #
      # Example - a composed function usable for color conversion, mapping linear RGB
      # values to the sRGB gamma corrected space:
      #
      #   { dup 0.0031308 le { 12.92 mul } { 1 2.4 div exp 1.055 mul 0.055 sub } ifelse }
      #
      # See: PDF2.0 s7.10.5
      class PostScriptCalculatorFunction < Function

        # The default maximum number of tokens evaluated during a single function call.
        DEFAULT_MAX_EXECUTION_STEPS = 1_000_000

        # The maximum number of tokens (literals and operators) that may be evaluated
        # during a single function call.
        #
        # This execution budget is a safe-guard against runaway functions; when it is
        # exhausted, a HexaPDF::Type::Function::FunctionError is raised.
        attr_accessor :max_execution_steps

        def initialize(...)
          super
          @max_execution_steps = DEFAULT_MAX_EXECUTION_STEPS
        end

        private

        def perform_call(args) # :nodoc:
          stack = args.dup
          execute(parsed_code, stack, [@max_execution_steps])
          stack
        end

        # Resets the cached parsed code when the stream data changes.
        def after_data_change
          @parsed_code = nil
          super
        end

        # Returns the parsed representation of the PostScript code in the stream: an array
        # of Integer/Float literals, String operator names and nested arrays for
        # procedures.
        def parsed_code
          @parsed_code ||= begin
            code = parse_code(stream)
            # The stream normally contains a single procedure holding the actual code
            code.length == 1 && code.first.kind_of?(Array) ? code.first : code
          end
        end

        NUMBER_RE = /[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?/ # :nodoc:

        # Parses the given string into the token representation described at #parsed_code.
        def parse_code(string)
          scanner = StringScanner.new(string)
          stack = [[]]
          until scanner.eos?
            scanner.skip(/(?:\s|%[^\r\n]*)+/)
            break if scanner.eos?

            if scanner.scan(/\{/)
              procedure = []
              stack.last << procedure
              stack << procedure
            elsif scanner.scan(/\}/)
              if stack.length == 1
                raise FunctionError, "unbalanced '}' in calculator function code"
              end
              stack.pop
            elsif (token = scanner.scan(NUMBER_RE))
              stack.last << (token.match?(/[.eE]/) ? token.to_f : token.to_i)
            elsif (token = scanner.scan(/[^\s{}\[\]()<>%]+/))
              stack.last << token
            else
              raise FunctionError,
                    "invalid character in calculator function code at byte #{scanner.pos}"
            end
          end
          if stack.length > 1
            raise FunctionError, "unbalanced '{' in calculator function code"
          end
          stack.first
        end

        # Executes the given parsed code, modifying the stack in-place. The budget is a
        # one-element array holding the number of tokens that may still be evaluated.
        def execute(code, stack, budget)
          code.each do |token|
            budget[0] -= 1
            if budget[0] < 0
              raise FunctionError, "execution budget of the calculator function exhausted"
            end

            case token
            when Integer, Float, Array
              stack << token
            when String
              execute_operator(token, stack, budget)
            end
          end
        end

        # Executes a single operator.
        def execute_operator(operator, stack, budget)
          case operator
          when 'abs' then stack << pop_number(stack).abs
          when 'add'
            num2 = pop_number(stack)
            num1 = pop_number(stack)
            stack << num1 + num2
          when 'atan'
            den = pop_number(stack)
            num = pop_number(stack)
            angle = Math.atan2(num, den) * 180.0 / Math::PI
            stack << (angle < 0 ? angle + 360.0 : angle)
          when 'ceiling'
            num = pop_number(stack)
            stack << (num.kind_of?(Integer) ? num : num.ceil.to_f)
          when 'cos' then stack << Math.cos(pop_number(stack) * Math::PI / 180.0)
          when 'cvi' then stack << pop_number(stack).truncate
          when 'cvr' then stack << pop_number(stack).to_f
          when 'div'
            num2 = pop_number(stack)
            num1 = pop_number(stack)
            raise FunctionError, "division by zero" if num2.zero?
            stack << num1.to_f / num2
          when 'exp'
            exponent = pop_number(stack)
            base = pop_number(stack)
            result = base.to_f**exponent
            raise FunctionError, "invalid operands for exp" if !result.real? || result.nan?
            stack << result
          when 'floor'
            num = pop_number(stack)
            stack << (num.kind_of?(Integer) ? num : num.floor.to_f)
          when 'idiv'
            int2 = pop_integer(stack)
            int1 = pop_integer(stack)
            raise FunctionError, "division by zero" if int2.zero?
            stack << (int1 - int1.remainder(int2)) / int2
          when 'ln'
            num = pop_number(stack)
            raise FunctionError, "logarithm of a non-positive number" if num <= 0
            stack << Math.log(num)
          when 'log'
            num = pop_number(stack)
            raise FunctionError, "logarithm of a non-positive number" if num <= 0
            stack << Math.log10(num)
          when 'mod'
            int2 = pop_integer(stack)
            int1 = pop_integer(stack)
            raise FunctionError, "division by zero" if int2.zero?
            stack << int1.remainder(int2)
          when 'mul'
            num2 = pop_number(stack)
            num1 = pop_number(stack)
            stack << num1 * num2
          when 'neg' then stack << -pop_number(stack)
          when 'round'
            num = pop_number(stack)
            stack << (num.kind_of?(Integer) ? num : (num + 0.5).floor.to_f)
          when 'sin' then stack << Math.sin(pop_number(stack) * Math::PI / 180.0)
          when 'sqrt'
            num = pop_number(stack)
            raise FunctionError, "square root of a negative number" if num < 0
            stack << Math.sqrt(num)
          when 'sub'
            num2 = pop_number(stack)
            num1 = pop_number(stack)
            stack << num1 - num2
          when 'truncate'
            num = pop_number(stack)
            stack << (num.kind_of?(Integer) ? num : num.truncate.to_f)
          when 'copy'
            count = pop_integer(stack)
            if count < 0
              raise FunctionError, "negative count for copy"
            elsif count > stack.length
              raise FunctionError, "stack underflow"
            end
            stack.concat(stack.last(count))
          when 'dup'
            value = pop(stack)
            stack << value << value
          when 'exch'
            raise FunctionError, "stack underflow" if stack.length < 2
            stack[-1], stack[-2] = stack[-2], stack[-1]
          when 'index'
            index = pop_integer(stack)
            if index < 0 || index >= stack.length
              raise FunctionError, "stack underflow"
            end
            stack << stack[-1 - index]
          when 'pop' then pop(stack)
          when 'roll'
            shift = pop_integer(stack)
            count = pop_integer(stack)
            if count < 0
              raise FunctionError, "negative count for roll"
            elsif count > stack.length
              raise FunctionError, "stack underflow"
            elsif count > 0
              stack.concat(stack.pop(count).rotate(-(shift % count)))
            end
          when 'and' then boolean_or_bitwise(stack) {|a, b| a & b }
          when 'or' then boolean_or_bitwise(stack) {|a, b| a | b }
          when 'xor' then boolean_or_bitwise(stack) {|a, b| a ^ b }
          when 'not'
            value = pop(stack)
            if value == true || value == false
              stack << !value
            elsif value.kind_of?(Integer)
              stack << ~value
            else
              raise FunctionError, "expected a boolean or integer but got #{value.inspect}"
            end
          when 'bitshift'
            shift = pop_integer(stack)
            value = pop_integer(stack)
            stack << (shift >= 0 ? value << shift : value >> -shift)
          when 'true' then stack << true
          when 'false' then stack << false
          when 'eq'
            value2 = pop(stack)
            value1 = pop(stack)
            stack << (value1 == value2)
          when 'ne'
            value2 = pop(stack)
            value1 = pop(stack)
            stack << (value1 != value2)
          when 'ge' then compare(stack) {|a, b| a >= b }
          when 'gt' then compare(stack) {|a, b| a > b }
          when 'le' then compare(stack) {|a, b| a <= b }
          when 'lt' then compare(stack) {|a, b| a < b }
          when 'if'
            procedure = pop_procedure(stack)
            condition = pop_boolean(stack)
            execute(procedure, stack, budget) if condition
          when 'ifelse'
            else_procedure = pop_procedure(stack)
            if_procedure = pop_procedure(stack)
            condition = pop_boolean(stack)
            execute(condition ? if_procedure : else_procedure, stack, budget)
          else
            raise FunctionError, "unknown operator #{operator.inspect}"
          end
        end

        # Pops one object off the stack, raising an error if the stack is empty.
        def pop(stack)
          raise FunctionError, "stack underflow" if stack.empty?
          stack.pop
        end

        # Pops a number (integer or real) off the stack.
        def pop_number(stack)
          value = pop(stack)
          unless value.kind_of?(Numeric)
            raise FunctionError, "expected a number but got #{value.inspect}"
          end
          value
        end

        # Pops an integer off the stack.
        def pop_integer(stack)
          value = pop(stack)
          unless value.kind_of?(Integer)
            raise FunctionError, "expected an integer but got #{value.inspect}"
          end
          value
        end

        # Pops a boolean off the stack.
        def pop_boolean(stack)
          value = pop(stack)
          unless value == true || value == false
            raise FunctionError, "expected a boolean but got #{value.inspect}"
          end
          value
        end

        # Pops a procedure off the stack.
        def pop_procedure(stack)
          value = pop(stack)
          unless value.kind_of?(Array)
            raise FunctionError, "expected a procedure but got #{value.inspect}"
          end
          value
        end

        # Applies a binary operator that works either on two booleans (logical operation)
        # or on two integers (bitwise operation).
        def boolean_or_bitwise(stack)
          value2 = pop(stack)
          value1 = pop(stack)
          booleans = [true, false]
          if booleans.include?(value1) && booleans.include?(value2)
            stack << yield(value1, value2)
          elsif value1.kind_of?(Integer) && value2.kind_of?(Integer)
            stack << yield(value1, value2)
          else
            raise FunctionError,
                  "expected two booleans or two integers but got #{value1.inspect} and #{value2.inspect}"
          end
        end

        # Compares two numbers popped off the stack and pushes the boolean result.
        def compare(stack)
          num2 = pop_number(stack)
          num1 = pop_number(stack)
          stack << yield(num1, num2)
        end

      end

    end
  end
end
