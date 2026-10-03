# -*- coding: utf-8 -*-

require 'test_helper'
require 'hexapdf/type/function'

describe HexaPDF::Type::Function::PostScriptCalculator do
  CalcError = HexaPDF::Type::Function::PostScriptCalculator::Error

  def calc(program, max_instructions: nil)
    if max_instructions
      HexaPDF::Type::Function::PostScriptCalculator.new(program,
                                                        max_instructions: max_instructions)
    else
      HexaPDF::Type::Function::PostScriptCalculator.new(program)
    end
  end

  def result(program, *input)
    calc(program).evaluate(input)
  end

  describe "parsing" do
    it "parses integers, reals, scientific notation and booleans" do
      assert_equal([1, -2, 1.5, -0.5, 5.0, 100.0, 15.0, true, false],
                 result('{ 1 -2 1.5 -.5 5. 1e2 1.5d1 true false }'))
    end

    it "ignores whitespace and comments" do
      program = "{ % comment line\n 1 % another\n 2 add }"
      assert_equal([3], result(program))
    end

    it "supports brace-less programs for leniency" do
      assert_equal([7], result('5 2 add'))
    end

    it "raises an error for unmatched braces" do
      assert_raises(CalcError) { calc('{{ }') }
      assert_raises(CalcError) { calc('{ }}') }
    end

    it "raises an error for unsupported syntax" do
      ['{ (string) }', '{ <41> }', '{ [ 1 ] }', '{ << >> }'].each do |program|
        assert_raises(CalcError) { calc(program) }
      end
    end

    it "raises an error for unknown operator names during evaluation" do
      error = assert_raises(CalcError) { result('{ unknownop }') }
      assert_match(/Unsupported operator/, error.message)
    end

    it "raises an error for invalid numbers" do
      assert_raises(CalcError) { result('{ 1.2.3 }') }
    end
  end

  describe "arithmetic operators" do
    it "handles add, sub and mul with integer/real type rules" do
      assert_equal([7], result('{ add }', 3, 4))
      assert_equal([7.0], result('{ add }', 3, 4.0))
      assert_equal([-1], result('{ sub }', 3, 4))
      assert_equal([12], result('{ mul }', 3, 4))
      assert_instance_of(Float, result('{ mul }', 3, 4.0).first)
    end

    it "always returns reals for div" do
      assert_equal([3.5], result('{ div }', 7, 2))
      assert_equal([2.5], result('{ div }', 5.0, 2))
    end

    it "truncates toward zero for idiv and uses C-style remainder for mod" do
      assert_equal([-1], result('{ idiv }', -5, 3))
      assert_equal([-1], result('{ idiv }', 5, -3))
      assert_equal([-2], result('{ mod }', -5, 3))
      assert_equal([2], result('{ mod }', 5, -3))
      assert_equal([1], result('{ mod }', 7, 3))
    end

    it "handles neg and abs while preserving types" do
      assert_equal([-5], result('{ neg }', 5))
      assert_equal([-5.0], result('{ neg }', 5.0))
      assert_equal([5], result('{ abs }', -5))
      assert_equal([5.0], result('{ abs }', -5.0))
    end

    it "handles ceiling, floor, round and truncate including negative values" do
      assert_equal([-1, -2, -1, -1], result('{ -1.2 ceiling -1.2 floor -1.2 round -1.2 truncate }'))
      assert_equal([2, 1, 2, 1], result('{ 1.5 ceiling 1.5 floor 1.5 round 1.5 truncate }'))
      assert_equal([-1, -2, -2, -1], result('{ -1.5 ceiling -1.5 floor -1.5 round -1.5 truncate }'))
      assert_equal([3, 3, 3, 3], result('{ 3 ceiling 3 floor 3 round 3 truncate }'))
      [-1.2, -1.5, 1.5, 3].flatten.each do |value|
        program = '{ ceiling floor round truncate }'
        assert(result(program, value).all?(Integer))
      end
    end

    it "handles the mathematical functions" do
      assert_in_delta(2.0, result('{ sqrt }', 4).first, 1e-9)
      assert_in_delta(1.0, result('{ sin }', 90).first, 1e-9)
      assert_in_delta(1.0, result('{ cos }', 0).first, 1e-9)
      assert_in_delta(45.0, result('{ atan }', 1, 1).first, 1e-9)
      assert_equal([90.0], result('{ atan }', 1, 0))
      assert_equal([270.0], result('{ atan }', -1, 0))
      assert_in_delta(100.0, result('{ exp }', 10, 2).first, 1e-9)
      assert_in_delta(0.0, result('{ ln }', 1).first, 1e-9)
      assert_in_delta(2.0, result('{ log }', 100).first, 1e-9)
    end

    it "rejects invalid math arguments" do
      assert_raises(CalcError) { result('{ sqrt }', -1) }
      assert_raises(CalcError) { result('{ ln }', 0) }
      assert_raises(CalcError) { result('{ log }', -1) }
    end

    it "converts values with cvi and cvr" do
      assert_equal([2], result('{ cvi }', 2.9))
      assert_equal([-2], result('{ cvi }', -2.9))
      assert_equal([2.0], result('{ cvr }', 2))
    end

    it "raises an error on division by zero" do
      assert_raises(CalcError) { result('{ div }', 1, 0) }
      assert_raises(CalcError) { result('{ idiv }', 1, 0) }
      assert_raises(CalcError) { result('{ mod }', 1, 0) }
    end
  end

  describe "comparison and boolean operators" do
    it "compares numeric values for equality regardless of integer/real type" do
      assert_equal([true], result('{ eq }', 1, 1.0))
      assert_equal([false], result('{ eq }', true, 1))
      assert_equal([false], result('{ eq }', 1, 2))
      assert_equal([true], result('{ ne }', 1, 2))
    end

    it "handles ordering comparisons" do
      assert_equal([true], result('{ gt }', 2, 1))
      assert_equal([true], result('{ ge }', 1, 1))
      assert_equal([true], result('{ lt }', 1, 2))
      assert_equal([true], result('{ le }', 1, 1))
      assert_equal([false], result('{ gt }', 1.0, 2.0))
    end

    it "handles boolean operators" do
      assert_equal([true], result('{ and }', true, true))
      assert_equal([false], result('{ and }', true, false))
      assert_equal([true], result('{ or }', false, true))
      assert_equal([true], result('{ xor }', true, false))
      assert_equal([false], result('{ xor }', true, true))
      assert_equal([true], result('{ not }', false))
    end

    it "handles bitshift on integers" do
      assert_equal([8], result('{ bitshift }', 1, 3))
      assert_equal([64], result('{ bitshift }', 256, -2))
    end

    it "rejects booleans where numbers are expected and vice versa" do
      assert_raises(CalcError) { result('{ add }', 1, true) }
      assert_raises(CalcError) { result('{ gt }', true, false) }
      assert_raises(CalcError) { result('{ and }', 1, 1) }
      assert_raises(CalcError) { result('{ cvi }', true) }
    end
  end

  describe "conditional operators" do
    it "executes the procedure for if only when the condition is true" do
      assert_equal([5], result('{ true { 5 } if }'))
      assert_equal([], result('{ false { 5 } if }'))
    end

    it "executes the matching procedure for ifelse" do
      assert_equal([7], result('{ 1 1 eq { 7 } { 8 } ifelse }'))
      assert_equal([8], result('{ 1 2 eq { 7 } { 8 } ifelse }'))
    end

    it "supports nested conditions" do
      program = '{ 2 1 gt { 1 2 lt { 30 } { 40 } ifelse } { 50 } ifelse }'
      assert_equal([30], result(program))
      program = '{ 2 3 gt { 1 2 lt { 30 } { 40 } ifelse } { 1 0 gt { 60 } { 70 } ifelse } ifelse }'
      assert_equal([60], result(program))
    end

    it "executes procedures nested inside procedures" do
      assert_equal([42], result('{ true { true { 42 } if } if }'))
    end
  end

  describe "stack operators" do
    it "handles pop, exch, dup and clear" do
      assert_equal([1], result('{ pop }', 1, 2))
      assert_equal([2, 1], result('{ exch }', 1, 2))
      assert_equal([9, 9], result('{ dup }', 9))
      assert_equal([9], result('{ 1 2 3 clear 9 }'))
    end

    it "handles copy" do
      assert_equal([1, 2, 3, 2, 3], result('{ 2 copy }', 1, 2, 3))
      assert_raises(CalcError) { result('{ 2 copy }', 1) }
      assert_raises(CalcError) { result('{ -1 copy }', 1) }
    end

    it "handles index" do
      assert_equal([10, 20, 30, 30], result('{ 0 index }', 10, 20, 30))
      assert_equal([10, 20, 30, 10], result('{ 2 index }', 10, 20, 30))
      assert_raises(CalcError) { result('{ 3 index }', 10, 20, 30) }
      assert_raises(CalcError) { result('{ -1 index }', 10) }
    end

    it "handles roll with positive and negative amounts" do
      assert_equal([2, 3, 1], result('{ 3 1 roll }', 1, 2, 3))
      assert_equal([3, 1, 2], result('{ 3 -1 roll }', 1, 2, 3))
      assert_equal([1, 2, 3], result('{ 3 3 roll }', 1, 2, 3))
      assert_equal([1, 3, 4, 2], result('{ 3 1 roll }', 1, 2, 3, 4))
      assert_raises(CalcError) { result('{ 4 1 roll }', 1, 2, 3) }
      assert_raises(CalcError) { result('{ -1 1 roll }', 1, 2, 3) }
    end

    it "handles count" do
      assert_equal([1, 2, 3, 3], result('{ count }', 1, 2, 3))
    end
  end

  describe "error handling" do
    it "raises an error on stack underflow" do
      error = assert_raises(CalcError) { result('{ add }', 1) }
      assert_match(/Not enough operands/, error.message)
      assert_raises(CalcError) { result('{ pop }') }
    end

    it "raises an error on invalid operand types" do
      error = assert_raises(CalcError) { result('{ add }', true, 1) }
      assert_match(/Invalid operand type/, error.message)
    end

    it "raises an error when the execution budget is exhausted" do
      error = assert_raises(CalcError) do
        calc('{ 1 1 add }', max_instructions: 2).evaluate([0])
      end
      assert_match(/execution budget/, error.message)
      assert_raises(CalcError) do
        calc('{ { 1 } }', max_instructions: 0).evaluate([])
      end
    end

    it "counts nested procedure instructions against the budget" do
      assert_raises(CalcError) do
        calc('{ true { 1 } if }', max_instructions: 3).evaluate([])
      end
    end
  end

  describe "repeated invocation" do
    before do
      @calculator = calc('{ 2 mul 1 add }')
    end

    it "always starts with an empty stack besides the input values" do
      assert_equal([5], @calculator.evaluate([2]))
      assert_equal([11], @calculator.evaluate([5]))
      assert_equal([-3], @calculator.evaluate([-2]))
    end

    it "recovers after a failed evaluation" do
      failing = calc('{ 1 0 div }')
      assert_raises(CalcError) { failing.evaluate([1]) }
      assert_raises(CalcError) { failing.evaluate([1]) }
      assert_equal([2], calc('{ 1 add }').evaluate([1]))
    end
  end
end
