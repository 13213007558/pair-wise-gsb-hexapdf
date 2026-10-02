# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/document'
require 'hexapdf/type/shading'
require 'hexapdf/content/transformation_matrix'

describe HexaPDF::Type::Shading do
  before do
    @doc = HexaPDF::Document.new
  end

  # The default Decode array: coordinates in [0, 100], three color components in [0, 1].
  def default_decode
    [0, 100, 0, 100, 0, 1, 0, 1, 0, 1]
  end

  # Encodes [value, width] pairs into a bit stream (most significant bit first).
  def encode_bits(values)
    data = +''
    cache = 0
    bits = 0
    values.each do |value, width|
      cache = (cache << width) | value
      bits += width
      while bits >= 8
        bits -= 8
        data << ((cache >> bits) & 0xFF).chr
        cache &= (1 << bits) - 1
      end
    end
    data << (cache << (8 - bits)).chr if bits > 0
    data
  end

  def quantize(value, min, max, bits)
    ((value - min) / (max - min).to_f * ((1 << bits) - 1)).round
  end

  # Encodes one patch of a patch mesh. With the default bit widths every patch occupies a
  # whole number of bytes, so encoded patches can simply be concatenated into a mesh.
  def encode_patch(flag:, points:, colors:, bflag: 8, bpc: 16, bcomp: 8, decode: nil)
    decode ||= default_decode
    values = [[flag, bflag]]
    points.each do |x, y|
      values << [quantize(x, decode[0], decode[1], bpc), bpc]
      values << [quantize(y, decode[2], decode[3], bpc), bpc]
    end
    colors.each do |color|
      color.each_with_index do |component, index|
        values << [quantize(component, decode[4 + 2 * index], decode[5 + 2 * index], bcomp), bcomp]
      end
    end
    encode_bits(values)
  end

  def build_shading(type: 6, stream: nil, decode: nil, bpc: 16, bcomp: 8, bflag: 8,
                    color_space: :DeviceRGB)
    dict = {ShadingType: type, ColorSpace: color_space, BitsPerCoordinate: bpc,
            BitsPerComponent: bcomp, BitsPerFlag: bflag}
    dict[:Decode] = (decode || default_decode) unless decode == false
    @doc.wrap(dict, stream: stream || +'', type: HexaPDF::Type::Shading)
  end

  # The 12 control points of a curved Coons patch.
  def coons_points
    [[0, 0], [30, 10], [60, 10], [90, 0],
     [95, 30], [95, 60], [90, 90],
     [60, 95], [30, 95], [0, 90],
     [5, 60], [5, 30]]
  end

  # The 16 control points of a tensor-product patch (in stream order).
  def tensor_points
    [[0, 0], [5, 30], [5, 60], [0, 90],
     [30, 5], [30, 40], [30, 50], [30, 95],
     [60, 5], [60, 40], [60, 50], [60, 95],
     [90, 0], [95, 30], [95, 60], [90, 90]]
  end

  def rgb_colors
    [[0.0, 0.0, 0.5], [1.0, 0.0, 0.5], [1.0, 1.0, 0.5], [0.0, 1.0, 0.5]]
  end

  # Corner colors with a non-zero mixed derivative (a "saddle" color gradient).
  def saddle_colors
    [[0.0, 0.0, 0.0], [1.0, 0.2, 0.4], [0.0, 0.6, 0.8], [1.0, 0.4, 0.2]]
  end

  def assert_points_equal(expected, actual, delta = 0.001)
    assert_equal(expected.length, actual.length)
    expected.zip(actual) do |(ex, ey), (ax, ay)|
      assert_in_delta(ex, ax, delta)
      assert_in_delta(ey, ay, delta)
    end
  end

  def assert_colors_equal(expected, actual, delta = 0.005)
    assert_equal(expected.length, actual.length)
    expected.zip(actual) do |exp, act|
      exp.zip(act) {|e, a| assert_in_delta(e, a, delta) }
    end
  end

  # Evaluates a cubic Bezier curve at +u+.
  def bezier(p0, p1, p2, p3, u)
    v = 1.0 - u
    [v**3 * p0[0] + 3 * v * v * u * p1[0] + 3 * v * u * u * p2[0] + u**3 * p3[0],
     v**3 * p0[1] + 3 * v * v * u * p1[1] + 3 * v * u * u * p2[1] + u**3 * p3[1]]
  end

  # Evaluates the exact Coons patch surface defined by 12 control points at (s, t).
  def coons_surface(points, s, t)
    bottom = bezier(points[0], points[1], points[2], points[3], s)
    top = bezier(points[6], points[7], points[8], points[9], s)
    left = bezier(points[0], points[11], points[10], points[9], t)
    right = bezier(points[3], points[4], points[5], points[6], t)
    bilinear = interpolate_bilinear(points[0], points[3], points[6], points[9], s, t)
    [(1 - t) * bottom[0] + t * top[0] + (1 - s) * left[0] + s * right[0] - bilinear[0],
     (1 - t) * bottom[1] + t * top[1] + (1 - s) * left[1] + s * right[1] - bilinear[1]]
  end

  # Maps control net indices [i][j] of a tensor-product patch to stream point indices.
  def tensor_grid(i, j)
    [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10, 11], [12, 13, 14, 15]][i][j]
  end

  # Evaluates the exact tensor-product patch surface defined by 16 control points.
  def tensor_surface(points, s, t)
    bs = bernstein(s)
    bt = bernstein(t)
    x = y = 0.0
    4.times do |i|
      4.times do |j|
        weight = bs[i] * bt[j]
        point = points[tensor_grid(i, j)]
        x += weight * point[0]
        y += weight * point[1]
      end
    end
    [x, y]
  end

  def bernstein(u)
    v = 1.0 - u
    [v**3, 3 * v * v * u, 3 * v * u * u, u**3]
  end

  def interpolate_bilinear(c0, c1, c2, c3, s, t)
    w0 = (1 - s) * (1 - t)
    w1 = s * (1 - t)
    w2 = s * t
    w3 = (1 - s) * t
    c0.each_index.map {|k| w0 * c0[k] + w1 * c1[k] + w2 * c2[k] + w3 * c3[k] }
  end

  def bilinear_color(colors, s, t)
    interpolate_bilinear(colors[0], colors[1], colors[2], colors[3], s, t)
  end

  # Returns the maximum distance between the exact surface (given by the block, evaluated
  # at (s, t)) and the triangle mesh, sampled on a regular grid.
  def max_geometry_error(triangles, samples: 10)
    max = 0.0
    (0..samples).each do |si|
      (0..samples).each do |ti|
        point = yield(si.to_f / samples, ti.to_f / samples)
        distance = closest_triangle(point, triangles)[0]
        max = distance if distance > max
      end
    end
    max
  end

  # Returns the maximum difference between the exact color gradient and the color
  # interpolated on the triangle mesh, sampled on a regular grid.
  def max_color_error(triangles, colors, samples: 10)
    max = 0.0
    (0..samples).each do |si|
      (0..samples).each do |ti|
        s = si.to_f / samples
        t = ti.to_f / samples
        point = yield(s, t)
        _, closest, triangle = closest_triangle(point, triangles)
        interpolated = barycentric_color(closest, triangle)
        expected = bilinear_color(colors, s, t)
        error = interpolated.zip(expected).map {|a, b| (a - b).abs }.max
        max = error if error > max
      end
    end
    max
  end

  # Returns [distance, closest_point, triangle] for the triangle closest to +point+.
  def closest_triangle(point, triangles)
    best = nil
    triangles.each do |triangle|
      closest, distance = closest_point_on_triangle(point, triangle.points)
      best = [distance, closest, triangle] if !best || distance < best[0]
    end
    best
  end

  def closest_point_on_triangle(point, triangle)
    a, b, c = triangle
    return [point, 0.0] if point_in_triangle?(point, a, b, c)
    [[a, b], [b, c], [c, a]].map do |p1, p2|
      q = closest_point_on_segment(point, p1, p2)
      [q, Math.sqrt((point[0] - q[0])**2 + (point[1] - q[1])**2)]
    end.min_by {|_, distance| distance }
  end

  def closest_point_on_segment(point, a, b)
    dx = b[0] - a[0]
    dy = b[1] - a[1]
    length_squared = dx * dx + dy * dy
    return a.dup if length_squared == 0.0
    t = ((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / length_squared
    t = 0.0 if t < 0.0
    t = 1.0 if t > 1.0
    [a[0] + t * dx, a[1] + t * dy]
  end

  def point_in_triangle?(p, a, b, c)
    d1 = (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])
    d2 = (c[0] - b[0]) * (p[1] - b[1]) - (c[1] - b[1]) * (p[0] - b[0])
    d3 = (a[0] - c[0]) * (p[1] - c[1]) - (a[1] - c[1]) * (p[0] - c[0])
    (d1 >= 0 && d2 >= 0 && d3 >= 0) || (d1 <= 0 && d2 <= 0 && d3 <= 0)
  end

  def barycentric_color(point, triangle)
    a, b, c = triangle.points
    denominator = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
    return triangle.colors[0] if denominator.abs < 1e-15
    w0 = ((b[1] - c[1]) * (point[0] - c[0]) + (c[0] - b[0]) * (point[1] - c[1])) / denominator
    w1 = ((c[1] - a[1]) * (point[0] - c[0]) + (a[0] - c[0]) * (point[1] - c[1])) / denominator
    w2 = 1.0 - w0 - w1
    c0, c1, c2 = triangle.colors
    c0.each_index.map {|k| w0 * c0[k] + w1 * c1[k] + w2 * c2[k] }
  end

  describe "patches" do
    it "parses a type 6 patch with edge flag 0" do
      stream = encode_patch(flag: 0, points: coons_points, colors: rgb_colors)
      patches = build_shading(stream: stream).patches
      assert_equal(1, patches.length)
      assert_equal(0, patches[0].flag)
      assert_equal(12, patches[0].points.length)
      assert_equal(4, patches[0].colors.length)
      assert_points_equal(coons_points, patches[0].points)
      assert_colors_equal(rgb_colors, patches[0].colors)
    end

    it "parses a type 7 patch with edge flag 0" do
      stream = encode_patch(flag: 0, points: tensor_points, colors: rgb_colors)
      patches = build_shading(type: 7, stream: stream).patches
      assert_equal(1, patches.length)
      assert_equal(0, patches[0].flag)
      assert_equal(16, patches[0].points.length)
      assert_points_equal(tensor_points, patches[0].points)
      assert_colors_equal(rgb_colors, patches[0].colors)
    end

    it "reuses the edge of the previous type 6 patch for edge flags 1, 2 and 3" do
      q1 = [[100, 10], [100, 20], [95, 40], [65, 45], [35, 45], [5, 40], [0, 20], [0, 10]]
      q2 = [[96, 50], [96, 60], [91, 80], [66, 85], [36, 85], [6, 80], [1, 60], [1, 50]]
      q3 = [[90, 90], [90, 95], [85, 99], [60, 99], [30, 99], [0, 95], [0, 90], [0, 85]]
      d1 = [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]]
      d2 = [[0.7, 0.8, 0.9], [0.2, 0.4, 0.6]]
      d3 = [[0.3, 0.3, 0.3], [0.6, 0.6, 0.6]]
      stream = encode_patch(flag: 0, points: coons_points, colors: rgb_colors) +
        encode_patch(flag: 1, points: q1, colors: d1) +
        encode_patch(flag: 2, points: q2, colors: d2) +
        encode_patch(flag: 3, points: q3, colors: d3)
      patches = build_shading(stream: stream).patches
      assert_equal([0, 1, 2, 3], patches.map(&:flag))

      assert_equal(patches[0].points[3..6], patches[1].points[0..3])
      assert_equal(patches[0].colors[1..2], patches[1].colors[0..1])
      assert_points_equal(q1, patches[1].points[4..11])
      assert_colors_equal(d1, patches[1].colors[2..3])

      assert_equal(patches[1].points[6..9], patches[2].points[0..3])
      assert_equal(patches[1].colors[2..3], patches[2].colors[0..1])
      assert_points_equal(q2, patches[2].points[4..11])
      assert_colors_equal(d2, patches[2].colors[2..3])

      assert_equal([patches[2].points[9], patches[2].points[10], patches[2].points[11],
                    patches[2].points[0]], patches[3].points[0..3])
      assert_equal([patches[2].colors[3], patches[2].colors[0]], patches[3].colors[0..1])
      assert_points_equal(q3, patches[3].points[4..11])
      assert_colors_equal(d3, patches[3].colors[2..3])
    end

    it "reuses the edge of the previous type 7 patch for edge flags 1, 2 and 3" do
      q1 = 12.times.map {|i| [i * 8.0, 10.0 + (i % 3) * 5] }
      q2 = 12.times.map {|i| [i * 8.0, 40.0 + (i % 3) * 5] }
      q3 = 12.times.map {|i| [i * 8.0, 70.0 + (i % 3) * 5] }
      d1 = [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]]
      d2 = [[0.7, 0.8, 0.9], [0.2, 0.4, 0.6]]
      d3 = [[0.3, 0.3, 0.3], [0.6, 0.6, 0.6]]
      stream = encode_patch(flag: 0, points: tensor_points, colors: rgb_colors) +
        encode_patch(flag: 1, points: q1, colors: d1) +
        encode_patch(flag: 2, points: q2, colors: d2) +
        encode_patch(flag: 3, points: q3, colors: d3)
      patches = build_shading(type: 7, stream: stream).patches
      assert_equal([0, 1, 2, 3], patches.map(&:flag))

      assert_equal(patches[0].points[12..15], patches[1].points[0..3])
      assert_equal(patches[0].colors[1..2], patches[1].colors[0..1])
      assert_points_equal(q1, patches[1].points[4..15])

      assert_equal([patches[1].points[15], patches[1].points[11], patches[1].points[7],
                    patches[1].points[3]], patches[2].points[0..3])
      assert_equal(patches[1].colors[2..3], patches[2].colors[0..1])
      assert_points_equal(q2, patches[2].points[4..15])

      assert_equal([patches[2].points[3], patches[2].points[2], patches[2].points[1],
                    patches[2].points[0]], patches[3].points[0..3])
      assert_equal([patches[2].colors[3], patches[2].colors[0]], patches[3].colors[0..1])
      assert_points_equal(q3, patches[3].points[4..15])
    end

    it "derives the number of color components from the Decode array" do
      gray_decode = [0, 100, 0, 100, 0, 1]
      stream = encode_patch(flag: 0, points: coons_points,
                            colors: [[0.2], [0.4], [0.6], [0.8]], decode: gray_decode)
      patches = build_shading(stream: stream, decode: gray_decode,
                              color_space: :DeviceGray).patches
      assert_equal([1], patches[0].colors.map(&:length).uniq)
      assert_in_delta(0.4, patches[0].colors[1][0], 0.005)

      cmyk_decode = [0, 100, 0, 100, 0, 1, 0, 1, 0, 1, 0, 1]
      colors = [[0.1, 0.2, 0.3, 0.4], [0.5, 0.6, 0.7, 0.8],
                [0.9, 0.1, 0.2, 0.3], [0.4, 0.5, 0.6, 0.7]]
      stream = encode_patch(flag: 0, points: coons_points, colors: colors, decode: cmyk_decode)
      patches = build_shading(stream: stream, decode: cmyk_decode,
                              color_space: :DeviceCMYK).patches
      assert_equal([4], patches[0].colors.map(&:length).uniq)
      assert_colors_equal(colors, patches[0].colors)
    end

    it "handles different bit widths" do
      stream = encode_patch(flag: 0, points: coons_points, colors: rgb_colors,
                            bflag: 2, bpc: 32, bcomp: 12)
      patches = build_shading(stream: stream, bflag: 2, bpc: 32, bcomp: 12).patches
      assert_equal(1, patches.length)
      assert_points_equal(coons_points, patches[0].points, 0.0001)
      assert_colors_equal(rgb_colors, patches[0].colors, 0.0005)
    end

    it "reads compressed stream data" do
      stream = encode_patch(flag: 0, points: coons_points, colors: rgb_colors)
      compressed = Zlib::Deflate.deflate(stream)
      shading = build_shading(stream: HexaPDF::StreamData.new(proc { compressed },
                                                              filter: :FlateDecode))
      assert_equal(1, shading.patches.length)
      assert_points_equal(coons_points, shading.patches[0].points)
    end

    it "returns an empty array for an empty stream" do
      assert_equal([], build_shading.patches)
      assert_equal([], build_shading.triangles)
    end

    it "raises an error for shading types without a patch mesh" do
      error = assert_raises(HexaPDF::Error) { build_shading(type: 4).patches }
      assert_match(/patch mesh/, error.message)
      assert_raises(HexaPDF::Error) { build_shading(type: 5).triangles }
    end

    it "raises an error for missing or invalid dictionary entries" do
      assert_raises(HexaPDF::MalformedPDFError) { build_shading(decode: false).patches }
      assert_raises(HexaPDF::MalformedPDFError) do
        build_shading(decode: [0, 100, 0, 100, 0]).patches
      end
      shading = @doc.wrap({ShadingType: 6, ColorSpace: :DeviceRGB, Decode: default_decode},
                          stream: +'', type: HexaPDF::Type::Shading)
      assert_raises(HexaPDF::MalformedPDFError) { shading.patches }
    end

    it "raises an error for a truncated stream" do
      stream = encode_patch(flag: 0, points: coons_points, colors: rgb_colors)
      truncated = stream.byteslice(0, 30)
      assert_raises(HexaPDF::MalformedPDFError) { build_shading(stream: truncated).patches }
      assert_raises(HexaPDF::MalformedPDFError) { build_shading(stream: truncated).triangles }
      truncated = stream.byteslice(0, 55)
      assert_raises(HexaPDF::MalformedPDFError) { build_shading(stream: truncated).patches }
    end

    it "raises an error for an invalid edge flag" do
      stream = encode_bits([[7, 8]]) + encode_patch(flag: 0, points: coons_points,
                                                    colors: rgb_colors)
      assert_raises(HexaPDF::MalformedPDFError) { build_shading(stream: stream).patches }
    end

    it "raises an error if the first patch reuses an edge" do
      stream = encode_patch(flag: 1, points: coons_points[4..11], colors: rgb_colors[2..3])
      assert_raises(HexaPDF::MalformedPDFError) { build_shading(stream: stream).patches }
    end

    it "stops parsing if less than one edge flag of data is left" do
      assert_equal([], build_shading(stream: "\x00".b, bflag: 16).patches)
    end
  end

  describe "triangles" do
    # Returns the vertices of the tessellation that lie on the given boundary curve
    # (given as four Bezier control points).
    def boundary_vertices(triangles, curve)
      min_x, max_x = curve.map {|p| p[0] }.minmax
      min_y, max_y = curve.map {|p| p[1] }.minmax
      samples = (0..2000).map {|k| bezier(curve[0], curve[1], curve[2], curve[3], k / 2000.0) }
      triangles.flat_map(&:points).uniq.select do |v|
        v[0] >= min_x - 0.5 && v[0] <= max_x + 0.5 && v[1] >= min_y - 0.5 &&
          v[1] <= max_y + 0.5 &&
          samples.any? {|sp| (sp[0] - v[0]).abs < 0.1 && (sp[1] - v[1]).abs < 0.1 }
      end
    end

    # Returns true if +point+ lies on the polyline (within a small margin).
    def point_on_polyline?(point, polyline)
      polyline.each_cons(2).any? do |a, b|
        closest = closest_point_on_segment(point, a, b)
        (closest[0] - point[0]).abs < 1e-9 && (closest[1] - point[1]).abs < 1e-9
      end
    end

    it "tessellates a flat patch into two triangles" do
      points = [[0, 0], [30, 0], [60, 0], [90, 0], [90, 30], [90, 60], [90, 90],
                [60, 90], [30, 90], [0, 90], [0, 60], [0, 30]]
      colors = [[0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0]]
      shading = build_shading(stream: encode_patch(flag: 0, points: points, colors: colors))
      assert_equal(2, shading.triangles(tolerance: 1.0).length)
    end

    it "requires a positive tolerance" do
      shading = build_shading
      assert_raises(ArgumentError) { shading.triangles(tolerance: 0) }
      assert_raises(ArgumentError) { shading.triangles(tolerance: -1) }
    end

    it "approximates a curved Coons patch within the tolerance" do
      shading = build_shading(stream: encode_patch(flag: 0, points: coons_points,
                                                   colors: rgb_colors))
      patches = shading.patches
      triangles = shading.triangles(tolerance: 0.5)
      assert(triangles.length > 10)
      error = max_geometry_error(triangles) {|s, t| coons_surface(patches[0].points, s, t) }
      assert(error <= 0.5, "geometry error #{error} exceeds the tolerance")
    end

    it "approximates a strongly curved tensor-product patch within the tolerance" do
      points = tensor_points
      points[5] = [30, 80]
      points[10] = [60, 10]
      shading = build_shading(type: 7, stream: encode_patch(flag: 0, points: points,
                                                            colors: rgb_colors))
      patches = shading.patches
      triangles = shading.triangles(tolerance: 0.5)
      error = max_geometry_error(triangles) {|s, t| tensor_surface(patches[0].points, s, t) }
      assert(error <= 0.5, "geometry error #{error} exceeds the tolerance")
      color_error = max_color_error(triangles, patches[0].colors) do |s, t|
        tensor_surface(patches[0].points, s, t)
      end
      assert(color_error <= 0.5, "color error #{color_error} exceeds the tolerance")
    end

    it "approximates the color gradient within the tolerance" do
      # Affine (rectangular) geometry so that the parameters can be recovered exactly
      points = [[0, 0], [30, 0], [60, 0], [90, 0], [90, 30], [90, 60], [90, 90],
                [60, 90], [30, 90], [0, 90], [0, 60], [0, 30]]
      # A Decode range of [0, 90] makes the coordinates exactly representable
      decode = [0, 90, 0, 90, 0, 1, 0, 1, 0, 1]
      shading = build_shading(stream: encode_patch(flag: 0, points: points,
                                                   colors: saddle_colors, decode: decode),
                              decode: decode)
      colors = shading.patches[0].colors
      triangles = shading.triangles(tolerance: 0.1)
      triangles.each do |triangle|
        triangle.points.zip(triangle.colors) do |(x, y), color|
          expected = bilinear_color(colors, x / 90.0, y / 90.0)
          3.times {|k| assert_in_delta(expected[k], color[k], 1e-9) }
        end
      end
      error = max_color_error(triangles, colors) {|s, t| [90.0 * s, 90.0 * t] }
      assert(error <= 0.1, "color error #{error} exceeds the tolerance")
    end

    it "uses identical split points on the shared edge of adjacent patches" do
      p1_new = [[125, 35], [125, 65], [120, 95], [90, 100], [60, 100], [30, 95],
                [25, 65], [25, 35]]
      stream = encode_patch(flag: 0, points: coons_points, colors: rgb_colors) +
        encode_patch(flag: 1, points: p1_new, colors: [[0.5, 0.5, 0.5], [0.2, 0.8, 0.4]])
      shading = build_shading(stream: stream)
      patches = shading.patches
      tessellator = HexaPDF::Type::Shading::Tessellator.new(0.3)
      triangles0 = tessellator.tessellate(patches[0], 6)
      triangles1 = tessellator.tessellate(patches[1], 6)
      assert_equal(triangles0.length + triangles1.length,
                   shading.triangles(tolerance: 0.3).length)
      shared_curve = patches[0].points[3..6]
      vertices0 = boundary_vertices(triangles0, shared_curve)
      vertices1 = boundary_vertices(triangles1, shared_curve)
      coarse, fine = [vertices0, vertices1].sort_by(&:length)
      assert(coarse.length > 2, "the shared edge should be subdivided")
      # The split points of the shared edge are identical on both sides; additional
      # (Steiner) points of the finer side lie exactly on the shared polyline, so the
      # geometric boundary of both patches is identical and no seam appears.
      coarse.each do |v|
        assert(fine.any? {|w| (w[0] - v[0]).abs < 1e-9 && (w[1] - v[1]).abs < 1e-9 },
               "split point #{v.inspect} missing on the other side of the shared edge")
      end
      polyline = coarse.sort_by {|x, y| [y, x] }
      fine.each do |v|
        assert(point_on_polyline?(v, polyline),
               "vertex #{v.inspect} deviates from the shared edge polyline")
      end
    end

    it "handles different coordinate scales via the Decode array" do
      decode = [0, 1000, 0, 1000, 0, 1, 0, 1, 0, 1]
      big_points = coons_points.map {|x, y| [x * 10, y * 10] }
      stream = encode_patch(flag: 0, points: big_points, colors: rgb_colors, decode: decode)
      shading = build_shading(stream: stream, decode: decode)
      small = build_shading(stream: encode_patch(flag: 0, points: coons_points,
                                                 colors: rgb_colors))
      big_count = shading.triangles(tolerance: 1.0).length
      small_count = small.triangles(tolerance: 1.0).length
      assert(big_count > small_count, "a larger coordinate range should need more triangles")
      patches = shading.patches
      triangles = shading.triangles(tolerance: 1.0)
      error = max_geometry_error(triangles, samples: 8) do |s, t|
        coons_surface(patches[0].points, s, t)
      end
      assert(error <= 1.0, "geometry error #{error} exceeds the tolerance")
    end

    it "applies a transformation matrix to the control points" do
      points = [[0, 0], [30, 0], [60, 0], [90, 0], [90, 30], [90, 60], [90, 90],
                [60, 90], [30, 90], [0, 90], [0, 60], [0, 30]]
      colors = [[0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0]]
      shading = build_shading(stream: encode_patch(flag: 0, points: points, colors: colors))
      matrix = HexaPDF::Content::TransformationMatrix.new(2, 0, 0, 2, 10, 20)
      triangles = shading.triangles(tolerance: 1.0, transformation_matrix: matrix)
      assert_equal(2, triangles.length)
      expected = shading.triangles(tolerance: 1.0).flat_map(&:points).map do |x, y|
        matrix.evaluate(x, y)
      end.sort
      actual = triangles.flat_map(&:points).sort
      expected.zip(actual) do |(ex, ey), (ax, ay)|
        assert_in_delta(ex, ax, 1e-9)
        assert_in_delta(ey, ay, 1e-9)
      end
    end

    it "measures the tolerance in the transformed coordinate system" do
      shading = build_shading(stream: encode_patch(flag: 0, points: coons_points,
                                                   colors: rgb_colors))
      matrix = HexaPDF::Content::TransformationMatrix.new(10, 0, 0, 10, 0, 0)
      plain = shading.triangles(tolerance: 1.0).length
      scaled = shading.triangles(tolerance: 1.0, transformation_matrix: matrix).length
      assert(scaled > plain, "upscaling should increase the triangle count")
      patches = shading.patches
      triangles = shading.triangles(tolerance: 1.0, transformation_matrix: matrix)
      error = max_geometry_error(triangles, samples: 8) do |s, t|
        matrix.evaluate(*coons_surface(patches[0].points, s, t))
      end
      assert(error <= 1.0, "geometry error #{error} exceeds the tolerance")
    end

    it "never reduces precision when the tolerance is tightened" do
      points = tensor_points
      points[5] = [30, 80]
      points[10] = [60, 10]
      shading = build_shading(type: 7, stream: encode_patch(flag: 0, points: points,
                                                            colors: rgb_colors))
      patches = shading.patches
      previous_count = 0
      previous_error = Float::INFINITY
      [2.0, 0.5, 0.125].each do |tolerance|
        triangles = shading.triangles(tolerance: tolerance)
        assert(triangles.length >= previous_count, "tighter tolerance produced fewer triangles")
        error = max_geometry_error(triangles, samples: 8) do |s, t|
          tensor_surface(patches[0].points, s, t)
        end
        assert(error <= tolerance, "geometry error #{error} exceeds the tolerance")
        assert(error <= previous_error + 1e-9, "tighter tolerance reduced the precision")
        previous_count = triangles.length
        previous_error = error
      end
    end

    it "tessellates patches that are only curved in one parameter direction" do
      # Straight in s direction, curved in t direction; the left edge bulges outward so
      # that the polyline approximation has a measurable error
      points = [[20, 0], [40, 0], [60, 0], [80, 0],
                [72, 30], [72, 60], [80, 90],
                [60, 90], [40, 90], [20, 90],
                [10, 60], [10, 30]]
      colors = [[0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0]]
      shading = build_shading(stream: encode_patch(flag: 0, points: points, colors: colors))
      triangles = shading.triangles(tolerance: 0.5)
      assert(triangles.length > 2)
      patches = shading.patches
      error = max_geometry_error(triangles) {|s, t| coons_surface(patches[0].points, s, t) }
      assert(error <= 0.5, "geometry error #{error} exceeds the tolerance")
    end

    it "skips degenerate patches but still parses them" do
      stream = encode_patch(flag: 0, points: [[50, 50]] * 12, colors: rgb_colors)
      shading = build_shading(stream: stream)
      assert_equal(1, shading.patches.length)
      assert_equal([], shading.triangles(tolerance: 1.0))
    end

    it "handles patches with degenerate edges" do
      points = coons_points
      points[0] = points[1] = points[2] = points[3] = [0, 0]
      shading = build_shading(stream: encode_patch(flag: 0, points: points,
                                                   colors: rgb_colors))
      assert(shading.triangles(tolerance: 1.0).length > 0)
    end
  end
end
