# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/document'
require 'hexapdf/type/shading'

describe HexaPDF::Type::Shading do
  before do
    @doc = HexaPDF::Document.new
  end

  def pack_values(values, bits)
    values.map do |value|
      integer = (value.to_f * ((1 << bits) - 1)).round
      (bits / 8).times.map do |index|
        ((integer >> (bits - (index + 1) * 8)) & 0xFF).chr(Encoding::BINARY)
      end.join
    end.join
  end

  def packed(flag, coordinates, values, coordinate_bits: 8, component_bits: 8)
    [flag].pack('C') + pack_values(coordinates.flatten, coordinate_bits) +
      pack_values(values.flatten, component_bits)
  end

  def shading(type, stream, function: nil)
    dictionary = {
      Type: :Shading,
      ShadingType: type,
      ColorSpace: :DeviceGray,
      BitsPerCoordinate: 8,
      BitsPerComponent: 8,
      Decode: [0.0, 2.0, 0.0, 1.0, 0.0, 1.0]
    }
    dictionary[:Function] = function if function
    @doc.add(dictionary, stream: stream)
  end

  def shared_stream(type: 6)
    coordinates = [
      [0.0, 0.0],
      [0.25, 0.0], [0.75, 0.0],
      [1.0, 0.0],
      [1.25, 0.25], [1.25, 0.75],
      [1.0, 1.0],
      [0.75, 1.0], [0.25, 1.0], [0.0, 1.0], [0.0, 0.75], [0.0, 0.25]
    ]
    values = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7]
    second_coordinates = [
      [1.25, 0.25], [1.25, 0.75],
      [1.0, 1.0],
      [1.25, 0.0],
      [2.25, 0.25], [2.0, 1.0],
      [1.75, 1.0], [1.25, 1.0]
    ]
    second_values = [0.4, 0.35, 0.3, 0.4, 0.5, 0.45]
    if type == 7
      coordinates.concat([[0.4, 0.4], [0.6, 0.4], [0.4, 0.6], [0.6, 0.6]])
      second_coordinates.concat([[1.4, 0.4], [1.6, 0.4], [1.4, 0.6], [1.6, 0.6]])
    end
    packed(0, coordinates, values) + packed(1, second_coordinates, second_values)
  end

  it "parses a type 6 Coons patch through Decode and derives interior controls" do
    mesh = shading(6, shared_stream(type: 6))
    patch = mesh.each_patch.first

    assert_in_delta(0.49411764705882355, patch.geometry[1][3][0], 1e-6)
    assert_in_delta(1.0, patch.geometry[0][3][1], 1e-6)
    assert_in_delta(0.4, patch.colors[1][3][0], 1e-6)
    assert_in_delta(0.0, patch.geometry[3][0][0], 1e-6)
  end

  it "parses a type 7 tensor-product patch with four extra interior geometry points" do
    mesh = shading(7, shared_stream(type: 7))
    patch = mesh.each_patch.first

    assert_equal([0.0, 0.10196078431372549], patch.geometry[2][1])
    assert_equal([0.6, 0.6], patch.geometry[2][2])
    assert_in_delta(0.4, patch.colors[1][3][0], 1e-6)
  end

  it "reuses a preceding patch's edge geometry and colors without reversal" do
    mesh = shading(6, shared_stream(type: 6))
    first, second = mesh.each_patch.to_a

    4.times do |row|
      assert_equal(first.geometry[3 - row][3], second.geometry[3 - row][0])
      assert_equal(first.colors[3 - row][3], second.colors[3 - row][0])
    end
    assert_equal(1, second.flag)
  end

  it "samples corners, edge midpoints and interiors and keeps shared edges crack-free" do
    mesh = shading(6, shared_stream(type: 6))
    result = mesh.sample(tolerance: 0.01, max_subdivisions: 2)
    first = result.samples[0, 25]
    second = result.samples[25, 25]

    assert_in_delta(0.0, first[0].position[0], 1e-9)
    assert_in_delta(1.0, first[0].position[1], 1e-9)
    assert_in_delta(0.6, first[24].position[1], 1e-9)
    assert_in_delta(0.0, first[0].color.components.first, 1e-9)
    assert_in_delta(1.0, first[20].position[1], 1e-9)
    assert_in_delta(0.5, first[12].position[1], 1e-9)
    assert_in_delta(0.625, first[12].position[0], 1e-6)
    assert_in_delta(0.3, first[12].color.components.first, 1e-6)

    shared_first = first[10]
    shared_second = second[0]
    assert_equal(shared_first.position, shared_second.position)
    assert_equal(shared_first.color.components, shared_second.color.components)
    assert_empty(result.unresolved_ranges)
  end

  it "interpolates parameters before evaluating a PDF function" do
    function = {FunctionType: 2, Domain: [0, 1], C0: [0.0], C1: [10.0], N: 1}
    coordinates = Array.new(12) {[0.0, 0.0]}
    values = [0.2] * 8
    mesh = shading(6, packed(0, coordinates, values), function: function)
    sample = mesh.sample(max_subdivisions: 0).samples.first

    assert_in_delta(2.0, sample.color.components.first, 1e-6)
    assert_in_delta(0.2, sample.parameters.first, 1e-6)
  end

  it "identifies the patch and missing field when data is truncated" do
    coordinates = Array.new(6) {[0.0, 0.0]}
    error = assert_raises(HexaPDF::Error) do
      shading(6, packed(0, coordinates, [])).each_patch.to_a
    end
    assert_match(/patch 0/i, error.message)
    assert_match(/coordinate X/, error.message)
  end

  it "returns unresolved parametric ranges when the subdivision limit is too small" do
    mesh = shading(6, shared_stream(type: 6))
    result = mesh.sample(tolerance: 0.01, max_subdivisions: 0)

    refute_empty(result.unresolved_ranges)
    range = result.unresolved_ranges.first
    assert_equal(0, range[0])
    assert_equal([0.0, 1.0, 0.0, 1.0], range[1, 4])
    assert_operator(range[5], :>, 0.01)
  end
end
