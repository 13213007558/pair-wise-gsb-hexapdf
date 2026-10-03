# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/document'
require 'hexapdf/type/functions'

describe HexaPDF::Type::Functions do
  before do
    @doc = HexaPDF::Document.new
  end

  it "returns a PostScriptCalculatorFunction for function type 4" do
    obj = @doc.wrap({FunctionType: 4, Domain: [0, 1], Range: [0, 1]}, stream: '{ 2 mul }')
    function = HexaPDF::Type::Functions.get(obj)
    assert_kind_of(HexaPDF::Type::Functions::PostScriptCalculatorFunction, function)
    assert_equal([0.4], function.call(0.2))
  end

  it "returns the object itself if it is already a specific function object" do
    wrapped = @doc.wrap({FunctionType: 4, Domain: [0, 1]}, stream: '{ 2 mul }')
    obj = HexaPDF::Type::Functions.get(wrapped)
    assert_same(obj, HexaPDF::Type::Functions.get(obj))
  end

  it "works with an unwrapped hash" do
    function = HexaPDF::Type::Functions.get({FunctionType: 4, Domain: [0, 1], Range: [0, 4]})
    assert_kind_of(HexaPDF::Type::Functions::PostScriptCalculatorFunction, function)
  end

  it "raises an error for unsupported function types" do
    [0, 2, 3].each do |type|
      obj = @doc.wrap({FunctionType: type, Domain: [0, 1]})
      error = assert_raises(HexaPDF::Error) { HexaPDF::Type::Functions.get(obj) }
      assert_match(/unsupported function type/, error.message)
    end
  end
end
