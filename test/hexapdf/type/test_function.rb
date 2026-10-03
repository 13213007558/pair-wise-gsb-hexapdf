# -*- encoding: utf-8 -*-

require 'test_helper'
require 'stringio'
require 'hexapdf/document'
require 'hexapdf/type/function'

describe HexaPDF::Type::Function do
  before do
    @doc = HexaPDF::Document.new
  end

  def make_function(domain: [0, 1], range: nil, program: '{ }', type: 4, **fields)
    @doc.wrap({FunctionType: type, Domain: domain, **fields}.tap do |hash|
      hash[:Range] = range if range
    end, type: :Function, stream: program)
  end

  describe "fields" do
    it "wraps the function dictionary via the type map" do
      function = @doc.add({Type: :Function, FunctionType: 4, Domain: [0, 1]}, stream: '{ }')
      assert_kind_of(HexaPDF::Type::Function, function)
      assert_equal(:Function, function.type)
    end

    it "validates the FunctionType field" do
      function = @doc.wrap({FunctionType: 1, Domain: [0, 1]}, type: :Function, stream: '{ }')
      refute(function.validate(auto_correct: false))
    end
  end

  describe "call" do
    it "evaluates a simple Type 4 function" do
      function = make_function(domain: [0, 10], program: '{ 2.0 mul }')
      assert_equal([6.0], function.call(3))
    end

    it "accepts the input values as a single array" do
      function = make_function(domain: [0, 1, 0, 1], range: [0, 1],
                               program: '{ add 2 div }')
      assert_equal([0.75], function.call([0.5, 1.0]))
    end

    it "preserves integer results for integer-only arithmetic" do
      function = make_function(domain: [0, 10], program: '{ 2 add }')
      assert_instance_of(Integer, function.call(3).first)
      assert_equal([5], function.call(3))
    end

    it "produces real results when an operand is real" do
      function = make_function(domain: [0.0, 10.0], program: '{ 2.0 add }')
      assert_instance_of(Float, function.call(3).first)
    end

    it "clips the input values to the Domain intervals" do
      function = make_function(domain: [0, 1, -1, 1], program: '{ pop pop 7 }')
      assert_equal([7], function.call(5, -5))
    end

    it "clips the output values to the Range intervals" do
      function = make_function(domain: [0, 10], range: [0, 1],
                               program: '{ 5 exch pop }')
      assert_equal([1.0], function.call(5))
      function = make_function(domain: [0, 10], range: [0, 1],
                               program: '{ -3 exch pop }')
      assert_equal([0.0], function.call(5))
    end

    it "returns outputs without clipping if no Range is specified" do
      function = make_function(domain: [0, 1], program: '{ -5 exch pop }')
      assert_equal([-5], function.call(0))
    end

    it "uses a fresh stack for every invocation without stack residue" do
      function = make_function(domain: [0, 10], range: [0, 100],
                               program: '{ 10 add }')
      assert_equal([10], function.call(0))
      assert_equal([11], function.call(1))
      assert_equal([12], function.call(2))
    end

    it "succeeds on a later call even if an earlier call failed" do
      function = make_function(domain: [0, 1], range: [0, 100],
                               program: '{ 1 0 div }')
      assert_raises(HexaPDF::Error) { function.call(0) }
      function.stream = '{ 3 exch pop }'
      assert_equal([3], function.call(0))
    end

    it "raises an error if the number of inputs does not match the Domain" do
      function = make_function(domain: [0, 1, 0, 1], program: '{ pop pop }')
      error = assert_raises(HexaPDF::Error) { function.call(1) }
      assert_match(/number of function inputs/, error.message)
    end

    it "raises an error for invalid input values" do
      function = make_function(program: '{ }')
      error = assert_raises(HexaPDF::Error) { function.call(true) }
      assert_match(/Invalid function input/, error.message)
    end

    it "raises an error if the number of outputs does not match the Range" do
      function = make_function(domain: [0, 1], range: [0, 1, 0, 1],
                               program: '{ 1 exch pop }')
      error = assert_raises(HexaPDF::Error) { function.call(0) }
      assert_match(/number of function outputs/, error.message)
    end

    it "raises an error for a malformed Domain entry" do
      function = make_function(domain: [0, 1, 2], program: '{ pop pop }')
      error = assert_raises(HexaPDF::Error) { function.call(1, 2) }
      assert_match(/Domain/, error.message)
    end

    it "raises an error for unsupported function types" do
      function = @doc.wrap({FunctionType: 0, Domain: [0, 1], Size: 2},
                           type: :Function, stream: nil)
      error = assert_raises(HexaPDF::Error) { function.call(0) }
      assert_match(/Unsupported function type/, error.message)
    end
  end

  describe "color conversion sample" do
    it "converts an RGB color to CMYK using undercolor removal and black generation" do
      program = <<~POSTSCRIPT
        {
          dup
          2 index dup 2 index ge { exch pop } { pop } ifelse
          dup 3 index dup 2 index ge { exch pop } { pop } ifelse
          pop 1 exch sub
          1 4 index sub 1 index sub dup 0 lt { pop 0 } if
          1 4 index sub 2 index sub dup 0 lt { pop 0 } if
          1 4 index sub 3 index sub dup 0 lt { pop 0 } if
          7 4 roll 4 -1 roll pop pop pop
        }
      POSTSCRIPT
      function = make_function(domain: [0, 1, 0, 1, 0, 1],
                               range: [0, 1, 0, 1, 0, 1, 0, 1],
                               program: program)
      result = function.call(0.2, 0.4, 0.6)
      assert_equal(4, result.length)
      assert(result.all? {|value| value >= 0.0 && value <= 1.0 })
      assert_in_delta(0.4, result[0], 1e-9)
      assert_in_delta(0.2, result[1], 1e-9)
      assert_in_delta(0.0, result[2], 1e-9)
      assert_in_delta(0.4, result[3], 1e-9)
      assert_equal([0, 0, 0, 0], function.call(1, 1, 1).map(&:round))
      assert_equal([0, 0, 0, 1], function.call(0, 0, 0).map(&:round))
    end
  end

  describe "serialization" do
    it "can be written to and read back from a PDF document" do
      function = @doc.add({Type: :Function, FunctionType: 4, Domain: [0, 1], Range: [0, 1]},
                          stream: '{ dup mul }')
      @doc.catalog[:MyFunction] = function
      io = StringIO.new
      @doc.write(io)
      doc = HexaPDF::Document.new(io: StringIO.new(io.string))
      read_function = doc.catalog[:MyFunction]
      assert_kind_of(HexaPDF::Type::Function, read_function)
      assert_in_delta(0.49, read_function.call(0.7).first, 1e-9)
    end
  end
end
