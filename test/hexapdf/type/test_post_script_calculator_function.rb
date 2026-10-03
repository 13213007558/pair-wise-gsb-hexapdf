# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/document'
require 'hexapdf/type/functions'

describe HexaPDF::Type::Functions::PostScriptCalculatorFunction do
  before do
    @doc = HexaPDF::Document.new
  end

  def create_function(code, domain: [0, 1], range: [0, 1])
    HexaPDF::Type::Functions.get(
      @doc.wrap({FunctionType: 4, Domain: domain, Range: range}, stream: code)
    )
  end

  describe "evaluation" do
    it "evaluates simple arithmetic" do
      assert_equal([0.8], create_function('{ 2 mul }').call(0.4))
    end

    it "handles code without enclosing braces and comments" do
      function = create_function("% a comment\n2 mul % trailing comment")
      assert_equal([0.8], function.call(0.4))
    end

    it "clips the input arguments to the domain" do
      function = create_function('{ 2 mul }', domain: [0, 1], range: [0, 4])
      assert_equal([2], function.call(1.5))
      assert_equal([0], function.call(-1.5))
    end

    it "clips the results to the range" do
      function = create_function('{ 2 mul }', domain: [0, 2], range: [0, 1])
      assert_equal([1], function.call(1.5))
    end

    it "works without a range" do
      function = HexaPDF::Type::Functions.get(
        @doc.wrap({FunctionType: 4, Domain: [0, 2]}, stream: '{ 2 mul }')
      )
      assert_equal([3], function.call(1.5))
    end

    it "keeps integers and reals apart" do
      result = create_function('{ 2 3 add }', domain: [], range: [0, 10]).call
      assert_equal([5], result)
      assert_instance_of(Integer, result.first)
      result = create_function('{ 2 0.5 add }', domain: [], range: [0, 10]).call
      assert_equal([2.5], result)
      assert_instance_of(Float, result.first)
    end

    it "can be called repeatedly with independent stacks" do
      function = create_function('{ 1 2 3 }', domain: [], range: [0, 10, 0, 10, 0, 10])
      assert_equal([1, 2, 3], function.call)
      assert_equal([1, 2, 3], function.call)
    end
  end

  describe "color conversion samples" do
    it "computes the luminance of an RGB color" do
      function = create_function('{ 0.0722 mul exch 0.7152 mul add exch 0.2126 mul add }',
                                 domain: [0, 1, 0, 1, 0, 1], range: [0, 1])
      assert_in_delta(1.0, function.call(1, 1, 1).first, 0.0001)
      assert_in_delta(0.2126, function.call(1, 0, 0).first, 0.0001)
      assert_in_delta(0.7152, function.call(0, 1, 0).first, 0.0001)
      assert_in_delta(0.0722, function.call(0, 0, 1).first, 0.0001)
    end

    it "applies the sRGB gamma curve with a nested conditional" do
      function = create_function(
        '{ dup 0.0031308 le { 12.92 mul } { 1 2.4 div exp 1.055 mul 0.055 sub } ifelse }'
      )
      assert_in_delta(0.0, function.call(0).first, 0.0001)
      assert_in_delta(1.0, function.call(1).first, 0.0001)
      assert_in_delta(0.735357, function.call(0.5).first, 0.0001)
      assert_in_delta(0.0031308 * 12.92, function.call(0.0031308).first, 0.0001)
    end
  end

  describe "stack operators" do
    it "supports roll with positive and negative shifts" do
      domain = [0, 10, 0, 10, 0, 10]
      range = [0, 10, 0, 10, 0, 10]
      assert_equal([3, 1, 2], create_function('{ 3 1 roll }', domain: domain, range: range).call(1, 2, 3))
      assert_equal([2, 3, 1], create_function('{ 3 -1 roll }', domain: domain, range: range).call(1, 2, 3))
      assert_equal([1, 2, 3], create_function('{ 3 3 roll }', domain: domain, range: range).call(1, 2, 3))
    end

    it "supports index" do
      range = [0, 10, 0, 10, 0, 10]
      function = create_function('{ 1 index }', domain: [0, 10, 0, 10], range: range)
      assert_equal([5, 7, 5], function.call(5, 7))
      function = create_function('{ 0 index }', domain: [0, 10, 0, 10], range: range)
      assert_equal([5, 7, 7], function.call(5, 7))
    end

    it "supports copy, dup, exch and pop" do
      range = [0, 10, 0, 10, 0, 10, 0, 10]
      function = create_function('{ 2 copy }', domain: [0, 10, 0, 10], range: range)
      assert_equal([1, 2, 1, 2], function.call(1, 2))
      function = create_function('{ dup pop exch }', domain: [0, 10, 0, 10], range: [0, 10, 0, 10])
      assert_equal([2, 1], function.call(1, 2))
    end
  end

  describe "conditionals" do
    it "supports if" do
      function = create_function('{ 0.5 gt { 1 } if }', range: [0, 1])
      assert_equal([1], function.call(0.7))
    end

    it "supports nested ifelse" do
      code = '{ dup 0 lt { pop -1 } { dup 0 gt { pop 1 } { pop 0 } ifelse } ifelse }'
      function = create_function(code, domain: [-10, 10], range: [-1, 1])
      assert_equal([-1], function.call(-5))
      assert_equal([0], function.call(0))
      assert_equal([1], function.call(3.5))
    end

    it "supports booleans and bitwise operators" do
      assert_equal([1], create_function('{ pop true { 1 } { 2 } ifelse }').call(0))
      assert_equal([2], create_function('{ pop false not not { 1 } { 2 } ifelse }', range: [0, 10]).call(0))
      assert_equal([2], create_function('{ pop 6 3 and }', range: [0, 10]).call(0))
      assert_equal([7], create_function('{ pop 6 3 or }', range: [0, 10]).call(0))
      assert_equal([5], create_function('{ pop 6 3 xor }', range: [0, 10]).call(0))
      assert_equal([-7], create_function('{ pop 6 not }', range: [-10, 10]).call(0))
      assert_equal([16], create_function('{ pop 1 4 bitshift }', range: [0, 20]).call(0))
      assert_equal([4], create_function('{ pop 16 -2 bitshift }', range: [0, 20]).call(0))
    end

    it "compares numbers and booleans without mixing them up" do
      range = [0, 20]
      assert_equal([10], create_function('{ 1 1 eq { 10 } { 20 } ifelse }', domain: [], range: range).call)
      assert_equal([10], create_function('{ 1 1.0 eq { 10 } { 20 } ifelse }', domain: [], range: range).call)
      assert_equal([20], create_function('{ 1 true eq { 10 } { 20 } ifelse }', domain: [], range: range).call)
      assert_equal([10], create_function('{ 1 2 ne { 10 } { 20 } ifelse }', domain: [], range: range).call)
      assert_equal([10], create_function('{ 1 2 le { 10 } { 20 } ifelse }', domain: [], range: range).call)
      assert_equal([10], create_function('{ 2 1 ge { 10 } { 20 } ifelse }', domain: [], range: range).call)
      assert_equal([10], create_function('{ 1 2 lt { 10 } { 20 } ifelse }', domain: [], range: range).call)
      assert_equal([10], create_function('{ 2 1 gt { 10 } { 20 } ifelse }', domain: [], range: range).call)
    end
  end

  describe "rounding of negative numbers" do
    def create_rounding_function(operator)
      create_function("{ #{operator} }", domain: [-10, 10], range: [-10, 10])
    end

    it "supports floor" do
      function = create_rounding_function('floor')
      assert_equal([-3.0], function.call(-2.5))
      assert_instance_of(Float, function.call(-2.5).first)
      assert_equal([2.0], function.call(2.5))
    end

    it "supports ceiling" do
      function = create_rounding_function('ceiling')
      assert_equal([-2.0], function.call(-2.5))
      assert_equal([3.0], function.call(2.5))
    end

    it "supports truncate" do
      function = create_rounding_function('truncate')
      assert_equal([-2.0], function.call(-2.5))
      assert_equal([2.0], function.call(2.5))
    end

    it "supports round" do
      function = create_rounding_function('round')
      assert_equal([-2.0], function.call(-2.5))
      assert_equal([-3.0], function.call(-2.6))
      assert_equal([3.0], function.call(2.5))
    end

    it "supports cvi and cvr" do
      result = create_rounding_function('cvi').call(-2.7)
      assert_equal([-2], result)
      assert_instance_of(Integer, result.first)
      result = create_rounding_function('cvr').call(2)
      assert_equal([2.0], result)
      assert_instance_of(Float, result.first)
    end

    it "supports idiv with truncation towards zero" do
      function = create_function('{ idiv }', domain: [-10, 10, -10, 10], range: [-10, 10])
      assert_equal([-3], function.call(-7, 2))
      assert_equal([-3], function.call(7, -2))
      assert_equal([3], function.call(7, 2))
    end

    it "supports mod with the sign of the dividend" do
      function = create_function('{ mod }', domain: [-10, 10, -10, 10], range: [-10, 10])
      assert_equal([-1], function.call(-7, 3))
      assert_equal([1], function.call(7, -3))
    end
  end

  describe "arithmetic operators" do
    it "supports abs, neg, sub, mul and div" do
      assert_equal([5], create_function('{ abs }', domain: [-10, 10], range: [0, 10]).call(-5))
      assert_equal([-5], create_function('{ neg }', domain: [-10, 10], range: [-10, 10]).call(5))
      assert_equal([1], create_function('{ 3 2 sub }', domain: [], range: [0, 10]).call)
      assert_equal([6], create_function('{ 3 2 mul }', domain: [], range: [0, 10]).call)
      assert_equal([1.5], create_function('{ 3 2 div }', domain: [], range: [0, 10]).call)
    end

    it "supports sqrt, exp, ln and log" do
      assert_in_delta(1.4142, create_function('{ 2 sqrt }', domain: [], range: [0, 10]).call.first, 0.001)
      assert_equal([100.0], create_function('{ 10 2 exp }', domain: [], range: [0, 200]).call)
      assert_in_delta(1.0, create_function('{ 2.718281828459045 ln }', domain: [], range: [0, 10]).call.first, 0.0001)
      assert_in_delta(1.0, create_function('{ 10 log }', domain: [], range: [0, 10]).call.first, 0.0001)
    end

    it "supports sin, cos and atan with degrees" do
      assert_in_delta(1.0, create_function('{ 90 sin }', domain: [], range: [0, 10]).call.first, 0.0001)
      assert_in_delta(-1.0, create_function('{ 180 cos }', domain: [], range: [-10, 10]).call.first, 0.0001)
      assert_in_delta(45.0, create_function('{ 1 1 atan }', domain: [], range: [0, 360]).call.first, 0.0001)
      assert_in_delta(315.0, create_function('{ -1 1 atan }', domain: [], range: [0, 360]).call.first, 0.0001)
    end
  end

  describe "error handling" do
    it "raises an error on division by zero" do
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ 0 div }', domain: [-10, 10], range: [-10, 10]).call(1)
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ 0 idiv }', domain: [-10, 10], range: [-10, 10]).call(1)
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ 0 mod }', domain: [-10, 10], range: [-10, 10]).call(1)
      end
    end

    it "raises an error on a stack underflow" do
      error = assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ add }').call(0.5)
      end
      assert_match(/stack underflow/, error.message)
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ pop pop }').call(0.5)
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ 5 index }').call(0.5)
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ 5 copy }').call(0.5)
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ 5 1 roll }').call(0.5)
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ exch }').call(0.5)
      end
    end

    it "raises an error on type mismatches" do
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ 1 { 2 } if }', domain: []).call
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ true 1 and }', domain: []).call
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ 2.5 1 bitshift }', domain: []).call
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ true add }', domain: []).call
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ 1.5 not }', domain: []).call
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ 1 2 if }', domain: []).call
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ 1 { 1 } { 2 } ifelse }', domain: []).call
      end
    end

    it "raises an error for invalid domains of math functions" do
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ -1 sqrt }', domain: []).call
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ 0 ln }', domain: []).call
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ -1 log }', domain: []).call
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ -2 0.5 exp }', domain: []).call
      end
    end

    it "raises an error when the execution budget is exhausted" do
      function = create_function('{ 1 1 add 1 add 1 add }', domain: [], range: [0, 10])
      function.max_execution_steps = 3
      error = assert_raises(HexaPDF::Type::Function::FunctionError) { function.call }
      assert_match(/budget/, error.message)
    end

    it "raises an error for malformed code" do
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ { }').call(0.5)
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ } }').call(0.5)
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ [ }').call(0.5)
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ unknownop }').call(0.5)
      end
    end

    it "raises an error for a wrong number of arguments or results" do
      function = create_function('{ 2 mul }')
      assert_raises(HexaPDF::Type::Function::FunctionError) { function.call(1, 2) }
      assert_raises(HexaPDF::Type::Function::FunctionError) { function.call }
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ 5 6 }', domain: []).call
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ true }', domain: []).call
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ }').call(true)
      end
    end

    it "raises an error for negative copy and roll counts" do
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ -1 copy }').call(0.5)
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ -1 1 roll }').call(0.5)
      end
      assert_raises(HexaPDF::Type::Function::FunctionError) do
        create_function('{ -1 index }').call(0.5)
      end
    end
  end

  describe "reusability" do
    it "returns correct results after a failed call" do
      function = create_function('{ 2 exch div }', domain: [-10, 10], range: [-10, 10])
      assert_equal([0.5], function.call(4))
      assert_raises(HexaPDF::Type::Function::FunctionError) { function.call(0) }
      assert_equal([0.5], function.call(4))
      assert_equal([-0.5], function.call(-4))
    end

    it "leaves no stack residue after a failed call" do
      function = create_function('{ 5 6 7 add add }', domain: [], range: [0, 20])
      function.max_execution_steps = 2
      assert_raises(HexaPDF::Type::Function::FunctionError) { function.call }
      function.max_execution_steps = 100
      assert_equal([18], function.call)
    end

    it "reflects changes to the stream" do
      function = create_function('{ 2 mul }')
      assert_equal([0.4], function.call(0.2))
      function.stream = '{ 3 mul }'
      assert_in_delta(0.6, function.call(0.2).first, 0.0001)
    end
  end
end
