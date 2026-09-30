# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/document'

describe HexaPDF::Type::Function::PostScriptCalculator do
  before do
    @calculator = HexaPDF::Type::Function::PostScriptCalculator
  end

  def evaluate(source, *inputs)
    if inputs.empty?
      @calculator.evaluate(source)
    else
      @calculator.evaluate(source, *inputs)
    end
  end

  describe "arithmetic operators" do
    it "distinguishes integer and real arithmetic" do
      assert_equal([5], evaluate("{2 3 add}"))
      assert_in_delta(2.5, evaluate("{5 2 div}").first)
      assert_equal([2], evaluate("{5 2 idiv}"))
      assert_equal([1], evaluate("{5 2 mod}"))
      assert_equal([-1], evaluate("{-5 2 mod}"))
      assert_instance_of(Float, evaluate("{2.0 3 add}").first)
      assert_instance_of(Integer, evaluate("{2.0 cvi 3 add}").first)
    end

    it "calculates unary and transcendental operations" do
      assert_equal([-7, 7], evaluate("{7 neg 7 abs}"))
      source = "{1.2 ceiling 1.8 floor 1.5 round -1.5 round}"
      assert_equal([2, 1, 2, -1], evaluate(source))
      assert_equal([1, -1], evaluate("{1.9 truncate -1.9 truncate}"))
      assert_in_delta(2.0, evaluate("{4 sqrt}").first)
      assert_in_delta(1.0, evaluate("{0 cos}").first)
      assert_in_delta(1.0, evaluate("{90 sin}").first)
      assert_in_delta(45.0, evaluate("{1 1 atan}").first)
      assert_in_delta(Math.log(10), evaluate("{10 ln}").first)
      assert_in_delta(2.0, evaluate("{100 log}").first)
      assert_in_delta(8.0, evaluate("{2 3 exp}").first)
      assert_equal([3, 3.0], evaluate("{3.7 cvi 3 cvr}"))
    end
  end

  describe "comparison and logical operators" do
    it "returns booleans from comparisons and equality checks" do
      assert_equal([true], evaluate("{1 2 lt}"))
      assert_equal([false], evaluate("{1 2 gt}"))
      assert_equal([true], evaluate("{2 2 le}"))
      assert_equal([true], evaluate("{2 2 ge}"))
      assert_equal([false], evaluate("{1 2 eq}"))
      assert_equal([true], evaluate("{1 2 ne}"))
      assert_equal([true], evaluate("{1 1.0 eq}"))
      assert_raises(@calculator::TypeError) { evaluate("{true 1 eq}") }
    end

    it "handles boolean, integer logical and bit operations" do
      assert_equal([false, true, false],
                   evaluate("{true false and true false or true not}"))
      assert_equal([0, 7, 3, 16, 20], evaluate(<<~POSTSCRIPT))
        {6 1 and 6 1 or 1 2 xor 1 4 bitshift 160 -3 bitshift}
      POSTSCRIPT
      assert_raises(@calculator::TypeError) { evaluate("{1 true and}") }
      assert_raises(@calculator::TypeError) { evaluate("{false 1 or}") }
    end
  end

  describe "stack operators" do
    it "manipulates the operand stack" do
      assert_equal([2, 1], evaluate("{1 2 exch}"))
      assert_equal([3, 3], evaluate("{3 dup}"))
      assert_equal([1], evaluate("{1 2 pop}"))
      assert_equal([1, 2, 1, 2], evaluate("{1 2 2 copy}"))
      assert_equal(7, evaluate("{1 2 7 0 index}").last)
      assert_equal([3, 1, 2], evaluate("{1 2 3 3 1 roll}"))
      assert_equal([2, 3, 1], evaluate("{1 2 3 3 -1 roll}"))
    end
  end

  describe "conditional operators" do
    it "executes nested if and ifelse procedures" do
      source = <<~POSTSCRIPT
        {
          dup 0 ge
          {dup 10 gt {pop 10} if}
          {pop -10} ifelse
        }
      POSTSCRIPT
      assert_equal([5], evaluate(source, 5))
      assert_equal([10], evaluate(source, 20))
      assert_equal([-10], evaluate(source, -3))
    end
  end

  describe "errors" do
    it "raises for invalid tokens" do
      assert_raises(@calculator::SyntaxError) { @calculator.parse("{foo}") }
      assert_raises(@calculator::SyntaxError) { @calculator.parse("{{1}} {2}") }
      assert_raises(@calculator::SyntaxError) { @calculator.parse("{/add}") }
      assert_raises(@calculator::SyntaxError) { @calculator.parse("{[1]}") }
      assert_raises(@calculator::SyntaxError) { @calculator.parse("{(1)}") }
      assert_raises(@calculator::SyntaxError) { @calculator.parse("1") }
    end

    it "raises on stack underflow" do
      assert_raises(@calculator::StackUnderflowError) { evaluate("{add}") }
      assert_raises(@calculator::StackUnderflowError) { evaluate("{1 3 copy}") }
      assert_raises(@calculator::StackUnderflowError) do
        evaluate("{1 index}", 1)
      end
      assert_raises(@calculator::StackUnderflowError) do
        evaluate("{3 4 roll}", 1, 2)
      end
    end

    it "raises on type mismatches" do
      assert_raises(@calculator::TypeError) { evaluate("{true 1 add}") }
      assert_raises(@calculator::TypeError) { evaluate("{1.5 2 idiv}") }
      assert_raises(@calculator::TypeError) { evaluate("{1 true and}") }
      assert_raises(@calculator::TypeError) { evaluate("{1 {2} if}") }
      assert_raises(@calculator::TypeError) { evaluate("{1 {1} {2} ifelse}") }
    end

    it "raises on division or modulo by zero" do
      assert_raises(@calculator::DivisionByZeroError) { evaluate("{1 0 div}") }
      assert_raises(@calculator::DivisionByZeroError) { evaluate("{1 0 idiv}") }
      assert_raises(@calculator::DivisionByZeroError) { evaluate("{1 0 mod}") }
    end

    it "raises on non-finite results" do
      assert_raises(@calculator::NonFiniteResultError) do
        evaluate("{10.0 309 exp}")
      end
      assert_raises(@calculator::NonFiniteResultError) { evaluate("{-1 sqrt}") }
      assert_raises(@calculator::NonFiniteResultError) { evaluate("{0 ln}") }
      assert_raises(@calculator::NonFiniteResultError) do
        evaluate("{0 0 atan}")
      end
    end

    it "raises when resource limits are exceeded" do
      source = "{#{Array.new(1001, '1').join(' ')}}"
      assert_raises(@calculator::LimitError) { evaluate(source) }
      assert_raises(@calculator::LimitError) do
        evaluate("{1 #{Array.new(1000, 'dup').join(' ')}}")
      end
      assert_raises(@calculator::LimitError) { evaluate("{#{2 ** 31}}") }
    end
  end

  it "does not leave state on the operand stack between invocations" do
    calculator = @calculator.new
    assert_equal([3], calculator.evaluate("{1 2 add}"))
    assert_equal([4], calculator.evaluate("{3 add}", 1))
  end

  it "rejects an invalid compiled program" do
    calculator = @calculator.new
    assert_raises(@calculator::TypeError) { calculator.execute([:add]) }
    assert_raises(@calculator::TypeError) { calculator.execute([1, nil]) }
  end
end
