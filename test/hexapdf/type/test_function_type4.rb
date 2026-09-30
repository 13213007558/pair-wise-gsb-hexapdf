# -*- encoding: utf-8 -*-

require 'test_helper'
require 'stringio'
require 'hexapdf/document'

describe HexaPDF::Type::Function::Type4 do
  before do
    @doc = HexaPDF::Document.new
  end

  def function(source, domain: [-10, 10], range: [0, 100])
    @doc.wrap({FunctionType: 4, Domain: domain, Range: range},
              type: :XXFunctionType4, stream: source)
  end

  it "evaluates a manually calculable Type 4 function" do
    function = function("{ dup mul 2 3 add mul }")
    assert_equal([45], function.call(3))
  end

  it "is wrapped automatically when read back from a PDF file" do
    function = @doc.wrap({FunctionType: 4, Domain: [-1, 1], Range: [0, 1]},
                         type: :XXFunctionType4, stream: "{2 mul}")
    reference = @doc.add(function)
    @doc.pages.add[:TestFunction] = reference

    io = StringIO.new
    @doc.write(io)
    document = HexaPDF::Document.new(io: StringIO.new(io.string))
    loaded = document.object(reference.oid)
    assert_kind_of(HexaPDF::Type::Function::Type4, loaded)
    assert_equal([1], loaded.call(2))
  end

  it "clips input before execution and output after execution" do
    function = function("{20 add}")
    assert_equal([10], function.call(-100))
    assert_equal([30], function.call(100))
    assert_equal([27], function.call(7))
    assert_equal([100], function("{95 add}").call(10))
  end

  it "preserves integer and real results" do
    function = function("{2.5 mul}", range: [-100.0, 100.0])
    assert_equal([5.0], function.call(2))
    assert_instance_of(Float, function.call(2).first)
  end

  it "evaluates nested conditionals with clipped inputs" do
    source = <<~POSTSCRIPT
      {
        dup 0 ge
        {dup 5 gt {pop 10} {2 mul} ifelse}
        {-1 mul} ifelse
      }
    POSTSCRIPT
    function = function(source)
    assert_equal([10], function.call(20))
    assert_equal([10], function.call(5))
    assert_equal([4], function.call(2))
    assert_equal([8], function.call(-8))
    assert_equal([10], function.call(-20))
  end

  it "does not retain the previous operand stack on repeated calls" do
    function = @doc.wrap({FunctionType: 4, Domain: [0, 10]},
                         type: :XXFunctionType4, stream: "{dup add}")
    assert_equal([14], function.call(7))
    assert_equal([18], function.call(9))
  end

  it "requires numeric outputs even without Range" do
    function = @doc.wrap({FunctionType: 4, Domain: [0, 10]},
                         type: :XXFunctionType4, stream: "{1 2 lt}")
    assert_raises(HexaPDF::Type::Function::PostScriptCalculator::TypeError) do
      function.call(1)
    end
  end

  it "propagates interpreter errors" do
    assert_raises(HexaPDF::Type::Function::PostScriptCalculator::SyntaxError) do
      function("{invalid}").call(1)
    end
    error = HexaPDF::Type::Function::PostScriptCalculator::DivisionByZeroError
    assert_raises(error) { function("{1 0 div}").call(1) }
  end

  it "validates Domain and Range dimensions" do
    assert_raises(HexaPDF::Error) do
      function("{1}", domain: [0, 1, 2]).call(1)
    end
    assert_raises(HexaPDF::Error) do
      function("{1 2}", range: [0, 1]).call(1)
    end
  end
end
