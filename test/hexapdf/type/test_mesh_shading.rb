# -*- encoding: utf-8 -*-

require 'test_helper'
require 'zlib'
require 'hexapdf/document'
require 'hexapdf/type/mesh_shading'

describe HexaPDF::Type::MeshShading do
  before do
    @doc = HexaPDF::Document.new
    @shading = @doc.wrap({Type: :Shading, ShadingType: 7, ColorSpace: :DeviceRGB,
                          BitsPerCoordinate: 8, BitsPerComponent: 8,
                          BitsPerFlag: 2, Decode: decode(3)},
                         stream: '')
  end

  def decode(components, x_max: 1.0, y_max: 1.0)
    ([[0, x_max], [0, y_max]] + Array.new(components) { [0, 1] }).flatten
  end

  def encode(patch, components: 3, coordinate_bits: 8, component_bits: 8, flag_bits: 2)
    writer = HexaPDF::Utils::BitStreamWriter.new
    output = write_patch(writer, patch, components, coordinate_bits, component_bits, flag_bits)
    output << writer.finalize
  end

  def write_patch(writer, patch, components, coordinate_bits, component_bits, flag_bits)
    output = +''
    output << writer.write(patch.fetch(:flag, 0), flag_bits)
    patch.fetch(:points, []).each do |point|
      output << writer.write(quantize(point[0], coordinate_bits), coordinate_bits)
      output << writer.write(quantize(point[1], coordinate_bits), coordinate_bits)
    end
    patch.fetch(:colors, []).each do |color|
      color.each do |component|
        output << writer.write(quantize(component, component_bits), component_bits)
      end
    end
    output
  end

  def encode_patches(patches)
    writer = HexaPDF::Utils::BitStreamWriter.new
    output = +''
    patches.each do |patch|
      output << write_patch(writer, patch, 3, 8, 8, 2)
    end
    output << writer.finalize
  end

  def quantize(value, bits)
    [[(value * ((1 << bits) - 1)).round, 0].max, (1 << bits) - 1].min
  end

  def tensor_patch(y_scale: 1.0)
    points = Array.new(16) do |index|
      column = (index % 4) / 3.0
      row = (index / 4) / 3.0
      [column, y_scale * row + 0.4 * Math.sin(Math::PI * column) * Math.sin(Math::PI * row)]
    end
    colors = Array.new(4) { [0.0, 0.0, 0.0] }
    {points: points, colors: colors}
  end

  def tensor_value(points, u, v)
    x = y = 0.0
    4.times do |row|
      4.times do |column|
        weight = bernstein(column, u) * bernstein(row, v)
        x += weight * points[row * 4 + column][0]
        y += weight * points[row * 4 + column][1]
      end
    end
    [x, y]
  end

  def bernstein(index, value)
    [1, 3, 3, 1][index] * (1 - value) ** (3 - index) * value ** index
  end

  def distance_to_triangle(point, triangle)
    best = Float::INFINITY
    vertices = triangle.points
    3.times do |index|
      a = vertices[index]
      b = vertices[(index + 1) % 3]
      edge_x = b[0] - a[0]
      edge_y = b[1] - a[1]
      length = edge_x * edge_x + edge_y * edge_y
      t = length.zero? ? 0.0 : (((point[0] - a[0]) * edge_x + (point[1] - a[1]) * edge_y) /
                              length).clamp(0, 1)
      closest = [a[0] + edge_x * t, a[1] + edge_y * t]
      best = [best, Math.hypot(point[0] - closest[0], point[1] - closest[1])].min
    end
    best
  end

  it 'parses tensor control points, colors and bit-packed data' do
    data = encode(tensor_patch)
    patch = @shading.patches(data).first
    assert_equal(7, patch.type)
    assert_equal(16, patch.points.length)
    assert_equal(4, patch.colors.length)
    assert_in_delta(0, patch.points[0][0], 0.01)
    assert_in_delta(1, patch.points[15][0], 0.01)
  end

  it 'reads compressed streams' do
    raw = encode(tensor_patch)
    compressed = Zlib.deflate(raw)
    source = compressed
    @shading.data.stream = HexaPDF::StreamData.new(proc { source }, filter: :FlateDecode)
    assert_equal(1, @shading.patches.length)
  end

  it 'tessellates curved tensor patches and tightens with tolerance' do
    data = encode(tensor_patch)
    coarse = @shading.triangles(data: data, tolerance: 0.5, color_tolerance: 0.5)
    fine = @shading.triangles(data: data, tolerance: 0.02, color_tolerance: 0.02)
    assert_operator(fine.length, :>, coarse.length)
    samples = 12.times.flat_map do |row|
      12.times.map {|column| tensor_value(tensor_patch[:points], column / 11.0, row / 11.0) }
    end
    errors = samples.map {|point| fine.map {|triangle| distance_to_triangle(point, triangle) }.min }
    assert_operator(errors.max, :<, 0.02)
  end

  it 'applies coordinate transforms and nonuniform scales' do
    data = encode(tensor_patch)
    triangles = @shading.triangles(data: data, tolerance: 0.02,
                                   matrix: [3, 0, 0, 2, 10, 20])
    xs = triangles.flat_map(&:points).map(&:first)
    ys = triangles.flat_map(&:points).map(&:last)
    assert_in_delta(10.0, xs.min, 0.001)
    assert_in_delta(20.0, ys.min, 0.02)
    assert_operator(xs.max, :>, 13.5)
    assert_operator(ys.max, :>=, 21.5)
  end

  it 'uses identical subdivision points along a reused Coons patch edge' do
    @shading[:ShadingType] = 6
    colors = [[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]]
    first = {flag: 0, points: [
      [0.0, 0.0], [0.3, 0.0], [0.7, 0.0], [1.0, 0.0],
      [1.0, 0.3], [1.0, 0.7], [1.0, 1.0],
      [0.7, 1.0], [0.3, 1.0], [0.0, 1.0],
      [0.0, 0.7], [0.0, 0.3]
    ], colors: colors}
    second = {flag: 1, points: [
      [-0.3, 0.0], [-0.7, 0.0], [-1.0, 0.0],
      [-1.0, 0.3], [-1.0, 0.7], [-1.0, 1.0],
      [-0.7, 1.0], [-0.3, 1.0]
    ], colors: [[0, 0, 1], [0, 1, 1]]}
    data = encode_patches([first, second])
    triangles = @shading.triangles(data: data, tolerance: 0.01, color_tolerance: 0.01)
    left = triangles.select {|triangle| triangle.points.any? {|point| point[0] <= 0 } }
    right = triangles.select {|triangle| triangle.points.any? {|point| point[0] >= 0 } }
    left_edges = left.flat_map {|triangle| triangle.points }.uniq.select {|point| point[0].zero? }
    right_edges = right.flat_map {|triangle| triangle.points }.uniq.select {|point| point[0].zero? }
    assert_equal(left_edges.sort, right_edges.sort)
    assert_operator(left_edges.length, :>, 2)
  end

  it 'reuses a tensor product patch edge with consistent subdivision points' do
    first = tensor_patch
    first[:points] = Array.new(16) do |index|
      u = (index % 4) / 3.0
      v = (index / 4) / 3.0
      [u, v + 0.2 * u * (1 - u)]
    end
    second_points = Array.new(12) do |index|
      column = index % 4 / 3.0 - 1.0
      row = index / 4 / 3.0
      [column, row]
    end
    second = {flag: 1, points: second_points,
              colors: [[1, 1, 1], [0, 1, 1]]}
    triangles = @shading.triangles(data: encode_patches([first, second]),
                                   tolerance: 0.01, color_tolerance: 0.01)
    shared_edge = first[:points].values_at(12, 8, 4, 0).reverse
    samples = 1.upto(3).map do |index|
      t = index / 4.0
      [0, 1, 2, 3].map do |point_index|
        bernstein(point_index, t)
      end.zip(shared_edge).map do |weight, point|
        point.map {|value| value * weight }
      end.inject {|a, b| [a[0] + b[0], a[1] + b[1]] }
    end
    all_points = triangles.flat_map(&:points)
    boundary = samples.map do |sample|
      all_points.select {|point| point.zip(sample).all? {|actual, expected| (actual - expected).abs < 0.001 } }
    end
    assert_operator(boundary.length, :>, 2)
    assert(boundary.all? {|matches| matches.length >= 2 })
  end

  it 'separates truncated patches from degenerate patches' do
    degenerate = tensor_patch
    degenerate[:points] = degenerate[:points].map {|point| [point[0], 0] }
    assert_equal(0, @shading.triangles(data: encode(degenerate), tolerance: 0.01).length)

    truncated = encode(tensor_patch)
    assert_raises(HexaPDF::MalformedPDFError) do
      @shading.patches(truncated[0..-3])
    end
  end
end
