# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/document'

describe HexaPDF::Type::Shading do
  before do
    @doc = HexaPDF::Document.new

    # Control points of Coons patch A (flag 0) and Coons patch B (flag 1, sharing patch
    # A's curved right edge).
    @points_a = [[0, 0], [30, 20], [70, 20], [100, 0], [120, 30], [120, 70],
                 [100, 100], [70, 80], [30, 80], [0, 100], [20, 70], [20, 30]]
    @colors_a = [0.0, 1.0, 0.0, 1.0]
    @points_b = [[130, 20], [170, 20], [200, 0], [220, 30], [220, 70], [200, 100],
                 [170, 80], [130, 80]] # explicitly stored control points p1..p8
    @colors_b = [0.4, 0.8] # explicitly stored corner colors c1, c2

    # Control points of tensor-product patch A (flag 0) and patch B (flag 2, sharing
    # patch A's bottom row).
    @tensor_points_a = [[0, 0], [40, 10], [60, 10], [100, 0],
                        [10, 40], [30, 50], [70, 50], [90, 40],
                        [10, 60], [30, 70], [70, 70], [90, 60],
                        [0, 100], [40, 90], [60, 90], [100, 100]]
    @tensor_colors_a = [[1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 0]]
    @tensor_points_b = [[5, 120], [35, 130], [65, 130], [95, 120],
                        [5, 140], [35, 150], [65, 150], [95, 140],
                        [0, 180], [40, 170], [60, 170], [100, 180]] # p4..p15
    @tensor_colors_b = [[0, 1, 1], [1, 0, 1]] # c2, c3
  end

  # Packs [width, value] pairs MSB-first into a binary string, padding the last byte
  # with zero bits.
  def pack_bits(entries)
    bits = entries.map {|width, value| value.to_s(2).rjust(width, '0') }.join
    bits += '0' * ((8 - bits.length % 8) % 8)
    [bits].pack('B*')
  end

  # Encodes a patch with the given edge flag; coordinates are 16-bit values mapped from
  # the range 0..255 (raw = value * 257), colors 8-bit values mapped from 0..1.
  def coons_stream(patches)
    entries = []
    patches.each do |flag, points, colors|
      entries << [8, flag]
      points.each {|x, y| entries << [16, x * 257] << [16, y * 257] }
      colors.each {|color| entries << [8, (color * 255).round] }
    end
    pack_bits(entries)
  end

  def two_patch_stream
    coons_stream([[0, @points_a, @colors_a], [1, @points_b, @colors_b]])
  end

  def coons_shading(data, extra = {})
    @doc.wrap({ShadingType: 6, ColorSpace: :DeviceGray, BitsPerCoordinate: 16,
               BitsPerComponent: 8, BitsPerFlag: 8, Decode: [0, 255, 0, 255, 0, 1]}.
              merge(extra), type: :Shading, stream: data)
  end

  def two_patch_shading(extra = {})
    coons_shading(two_patch_stream, extra)
  end

  def tensor_stream(patches)
    entries = []
    patches.each do |flag, points, colors|
      entries << [8, flag]
      points.each {|x, y| entries << [16, x * 257] << [16, y * 257] }
      colors.each {|color| color.each {|comp| entries << [8, (comp * 255).round] } }
    end
    pack_bits(entries)
  end

  def tensor_shading(data, extra = {})
    @doc.wrap({ShadingType: 7, ColorSpace: :DeviceRGB, BitsPerCoordinate: 16,
               BitsPerComponent: 8, BitsPerFlag: 8,
               Decode: [0, 255, 0, 255, 0, 1, 0, 1, 0, 1]}.merge(extra),
              type: :Shading, stream: data)
  end

  def assert_point_equal(expected, actual, delta = 1.0e-9)
    assert_in_delta(expected[0], actual[0], delta)
    assert_in_delta(expected[1], actual[1], delta)
  end

  # Independent reference implementation of the Coons patch formula, using de Casteljau's
  # algorithm for the boundary curves.
  def reference_coons(p, u, v)
    bezier = lambda do |p0, p1, p2, p3, t|
      q = [p0, p1, p2, p3]
      3.times do
        q = q.each_cons(2).map {|a, b| [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t] }
      end
      q[0]
    end
    top = bezier.call(p[0], p[1], p[2], p[3], u)
    bottom = bezier.call(p[9], p[10], p[11], p[6], u)
    left = bezier.call(p[0], p[11], p[10], p[9], v)
    right = bezier.call(p[3], p[4], p[5], p[6], v)
    [0, 1].map do |k|
      (1 - v) * top[k] + v * bottom[k] + (1 - u) * left[k] + u * right[k] -
        ((1 - u) * (1 - v) * p[0][k] + u * (1 - v) * p[3][k] + u * v * p[6][k] +
         (1 - u) * v * p[9][k])
    end
  end

  # Maximum deviation between the exact patch surface and the bilinear interpolation of
  # the sampled grid, measured at the cell centers.
  def max_cell_error(mesh)
    max = 0.0
    mesh.patches.each do |sampled_patch|
      patch = sampled_patch.patch
      n = sampled_patch.subdivisions
      n.times do |j|
        n.times do |i|
          exact = patch.evaluate((i + 0.5) / n, (j + 0.5) / n)
          approx = [0, 1].map do |k|
            0.25 * (sampled_patch.vertex_at(i, j).position[k] +
                    sampled_patch.vertex_at(i + 1, j).position[k] +
                    sampled_patch.vertex_at(i + 1, j + 1).position[k] +
                    sampled_patch.vertex_at(i, j + 1).position[k])
          end
          max = [max, Math.hypot(exact[0] - approx[0], exact[1] - approx[1])].max
        end
      end
    end
    max
  end

  describe "parsing" do
    it "parses Type 6 patches including edge-flag reuse of points and colors" do
      patches = two_patch_shading.patches
      assert_equal(2, patches.length)
      patch_a, patch_b = patches
      assert_equal(:coons, patch_a.type)
      assert_equal(@points_a[3], patch_b.points[0])
      assert_equal(@points_a[4], patch_b.points[11])
      assert_equal(@points_a[5], patch_b.points[10])
      assert_equal(@points_a[6], patch_b.points[9])
      assert_equal([200, 0], patch_b.points[3])
      assert_equal([130, 80], patch_b.points[8])
      assert_equal(patch_a.colors[1], patch_b.colors[0])
      assert_equal(patch_a.colors[2], patch_b.colors[3])
      assert_in_delta(0.4, patch_b.colors[1][0])
      assert_in_delta(0.8, patch_b.colors[2][0])
    end

    it "reuses the previous patch's bottom edge and colors for edge flag 2" do
      points_c = [[110, 30], [110, 70], [90, 100], [60, 110], [30, 110], [0, 100],
                  [10, 70], [10, 30]]
      data = coons_stream([[0, @points_a, @colors_a], [2, points_c, [0.2, 0.6]]])
      patch_a, patch_c = coons_shading(data).patches
      assert_equal(patch_a.points[6], patch_c.points[0])
      assert_equal(patch_a.points[7], patch_c.points[1])
      assert_equal(patch_a.points[8], patch_c.points[2])
      assert_equal(patch_a.points[9], patch_c.points[3])
      assert_equal([110, 30], patch_c.points[4])
      assert_equal(patch_a.colors[2], patch_c.colors[0])
      assert_equal(patch_a.colors[3], patch_c.colors[1])
      assert_in_delta(0.2, patch_c.colors[2][0])
      assert_in_delta(0.6, patch_c.colors[3][0])
    end

    it "reuses the previous patch's top edge and colors for edge flag 3" do
      points_d = [[0, 0], [30, 20], [70, 20], [70, 80], [30, 80], [0, 100],
                  [20, 70], [20, 30]]
      data = coons_stream([[0, @points_a, @colors_a], [3, points_d, [0.4, 0.8]]])
      patch_a, patch_d = coons_shading(data).patches
      assert_equal(patch_a.points[0], patch_d.points[3])
      assert_equal(patch_a.points[1], patch_d.points[4])
      assert_equal(patch_a.points[2], patch_d.points[5])
      assert_equal(patch_a.points[3], patch_d.points[6])
      assert_equal([0, 0], patch_d.points[0])
      assert_equal([20, 30], patch_d.points[11])
      assert_equal(patch_a.colors[0], patch_d.colors[1])
      assert_equal(patch_a.colors[1], patch_d.colors[2])
      assert_in_delta(0.4, patch_d.colors[0][0])
      assert_in_delta(0.8, patch_d.colors[3][0])
    end

    it "decodes values with non-byte-aligned bit widths" do
      points = (0..11).map {|i| [i * 20, 315 - i * 20] }
      entries = [[2, 0]]
      points.each {|x, y| entries << [12, x * 13] << [12, y * 13] }
      [0, 4, 8, 12].each {|raw| entries << [4, raw] }
      shading = @doc.wrap({ShadingType: 6, ColorSpace: :DeviceGray, BitsPerCoordinate: 12,
                           BitsPerComponent: 4, BitsPerFlag: 2,
                           Decode: [0, 315, 0, 315, 0, 1]},
                          type: :Shading, stream: pack_bits(entries))
      patch = shading.patches[0]
      points.each_with_index {|point, i| assert_point_equal(point, patch.points[i]) }
      [0.0, 4 / 15.0, 8 / 15.0, 12 / 15.0].each_with_index do |color, i|
        assert_in_delta(color, patch.colors[i][0])
      end
    end

    it "parses Type 7 tensor-product patches" do
      data = tensor_stream([[0, @tensor_points_a, @tensor_colors_a],
                            [2, @tensor_points_b, @tensor_colors_b]])
      patch_a, patch_b = tensor_shading(data).patches
      assert_equal(:tensor, patch_a.type)
      assert_equal(16, patch_a.points.length)
      assert_equal([40, 10], patch_a.points[1])
      assert_equal([1, 0, 0], patch_a.colors[0])
      # Edge flag 2: the top row and its corner colors are reused from the previous
      # patch's bottom row; note the tensor corner color order (c3 at p12, c2 at p15).
      assert_equal(patch_a.points[12], patch_b.points[0])
      assert_equal(patch_a.points[13], patch_b.points[1])
      assert_equal(patch_a.points[14], patch_b.points[2])
      assert_equal(patch_a.points[15], patch_b.points[3])
      assert_equal([5, 120], patch_b.points[4])
      assert_equal(patch_a.colors[3], patch_b.colors[0])
      assert_equal(patch_a.colors[2], patch_b.colors[1])
      assert_equal([0, 1, 1], patch_b.colors[2])
      assert_equal([1, 0, 1], patch_b.colors[3])
    end

    it "raises an error naming the incomplete patch when the data is truncated" do
      truncated = two_patch_stream.byteslice(0, two_patch_stream.bytesize - 3)
      error = assert_raises(HexaPDF::Type::Shading::TruncatedDataError) do
        coons_shading(truncated).patches
      end
      assert_equal(1, error.patch_index)
      assert_match(/patch 1/, error.message)
    end

    it "raises an error naming the first patch when the data is truncated immediately" do
      truncated = two_patch_stream.byteslice(0, 10)
      error = assert_raises(HexaPDF::Type::Shading::TruncatedDataError) do
        coons_shading(truncated).patches
      end
      assert_equal(0, error.patch_index)
    end

    it "rejects an edge flag on the first patch" do
      error = assert_raises(HexaPDF::Error) do
        coons_shading(pack_bits([[8, 1], [16, 0]])).patches
      end
      assert_match(/previous patch/, error.message)
    end

    it "rejects an invalid edge flag value" do
      error = assert_raises(HexaPDF::Error) do
        coons_shading(pack_bits([[8, 5], [16, 0]])).patches
      end
      assert_match(/Invalid edge flag/, error.message)
    end

    it "rejects an empty shading stream" do
      error = assert_raises(HexaPDF::Error) { coons_shading('').patches }
      assert_match(/no patch data/, error.message)
    end

    it "rejects unsupported shading types" do
      error = assert_raises(HexaPDF::Error) { coons_shading('x' * 100, ShadingType: 4).patches }
      assert_match(/Unsupported shading type/, error.message)
    end

    it "rejects a missing Decode array" do
      shading = @doc.wrap({ShadingType: 6, ColorSpace: :DeviceGray, BitsPerCoordinate: 16,
                           BitsPerComponent: 8, BitsPerFlag: 8},
                          type: :Shading, stream: 'x' * 50)
      error = assert_raises(HexaPDF::Error) { shading.patches }
      assert_match(/Decode/, error.message)
    end

    it "rejects invalid bit widths" do
      error = assert_raises(HexaPDF::Error) do
        coons_shading('x' * 100, BitsPerCoordinate: 7).patches
      end
      assert_match(/BitsPerCoordinate/, error.message)
    end
  end

  describe "evaluation" do
    before do
      @patch = two_patch_shading.patches[0]
    end

    it "evaluates the corner positions" do
      assert_point_equal([0, 0], @patch.evaluate(0, 0))
      assert_point_equal([100, 0], @patch.evaluate(1, 0))
      assert_point_equal([100, 100], @patch.evaluate(1, 1))
      assert_point_equal([0, 100], @patch.evaluate(0, 1))
    end

    it "evaluates edge midpoints as cubic Bézier points" do
      assert_point_equal([50, 15], @patch.evaluate(0.5, 0))     # top edge
      assert_point_equal([115, 50], @patch.evaluate(1, 0.5))    # right edge
      assert_point_equal([27.5, 62.5], @patch.evaluate(0.5, 1)) # bottom edge
      assert_point_equal([15, 50], @patch.evaluate(0, 0.5))     # left edge
    end

    it "evaluates interior points with the Coons patch formula" do
      assert_point_equal([53.75, 38.75], @patch.evaluate(0.5, 0.5))
      assert_point_equal(reference_coons(@patch.points, 0.3, 0.7), @patch.evaluate(0.3, 0.7))
      assert_point_equal(reference_coons(@patch.points, 0.8, 0.2), @patch.evaluate(0.8, 0.2))
    end

    it "interpolates the corner colors bilinearly" do
      assert_equal([0.0], @patch.color_at(0, 0))
      assert_equal([1.0], @patch.color_at(1, 0))
      assert_in_delta(0.5, @patch.color_at(0.5, 0.5)[0])
      assert_in_delta(0.375, @patch.color_at(0.25, 0.25)[0])
    end

    it "evaluates tensor-product patches" do
      patch = tensor_shading(tensor_stream([[0, @tensor_points_a, @tensor_colors_a]])).patches[0]
      assert_point_equal([0, 0], patch.evaluate(0, 0))
      assert_point_equal([100, 0], patch.evaluate(1, 0))
      assert_point_equal([100, 100], patch.evaluate(1, 1))
      assert_point_equal([0, 100], patch.evaluate(0, 1))
      assert_point_equal([50, 55.625], patch.evaluate(0.5, 0.5))
      assert_equal([0.5, 0.5, 0.25], patch.color_at(0.5, 0.5))
    end
  end

  describe "sampling" do
    it "samples exact positions and colors at the grid vertices" do
      mesh = two_patch_shading.sample(tolerance: 0.5, max_subdivisions: 16)
      assert(mesh.tolerance_met?)
      n = mesh.subdivisions
      assert(n.even?)
      patch = mesh.patches[0]
      assert_equal(n, patch.subdivisions)
      assert_point_equal([0, 0], patch.vertex_at(0, 0).position)
      assert_point_equal([100, 0], patch.vertex_at(n, 0).position)
      assert_point_equal([100, 100], patch.vertex_at(n, n).position)
      assert_point_equal([0, 100], patch.vertex_at(0, n).position)
      assert_point_equal([50, 15], patch.vertex_at(n / 2, 0).position)
      assert_point_equal([115, 50], patch.vertex_at(n, n / 2).position)
      assert_point_equal([53.75, 38.75], patch.vertex_at(n / 2, n / 2).position)
      assert_in_delta(0.0, patch.vertex_at(0, 0).color[0])
      assert_in_delta(1.0, patch.vertex_at(n, 0).color[0])
      assert_in_delta(0.5, patch.vertex_at(n / 2, n / 2).color[0])
      assert_equal(n * n, patch.quads.length)
      assert_equal([0, 1, n + 2, n + 1], patch.quads.first)
    end

    it "samples the shared edge of adjacent patches identically so that no cracks appear" do
      mesh = two_patch_shading.sample(tolerance: 0.1, max_subdivisions: 32)
      assert(mesh.tolerance_met?)
      n = mesh.subdivisions
      edge_a = (0..n).map {|j| mesh.patches[0].vertex_at(n, j).position }
      edge_b = (0..n).map {|j| mesh.patches[1].vertex_at(0, j).position }
      assert_equal(edge_a, edge_b)
    end

    it "reduces the approximation error when the tolerance is reduced" do
      shading = two_patch_shading
      coarse = shading.sample(tolerance: 5.0, max_subdivisions: 64)
      fine = shading.sample(tolerance: 0.25, max_subdivisions: 64)
      assert(coarse.tolerance_met?)
      assert(fine.tolerance_met?)
      assert(fine.subdivisions > coarse.subdivisions)
      coarse_error = max_cell_error(coarse)
      fine_error = max_cell_error(fine)
      assert(coarse_error <= 5.0)
      assert(fine_error <= 0.25)
      assert(fine_error < coarse_error)
    end

    it "reports the unmet regions instead of claiming accuracy at the subdivision limit" do
      mesh = two_patch_shading.sample(tolerance: 1.0e-6, max_subdivisions: 2)
      refute(mesh.tolerance_met?)
      assert_equal(2, mesh.subdivisions)
      refute_empty(mesh.unmet_regions)
      mesh.unmet_regions.each do |region|
        assert_includes([0, 1], region.patch_index)
        region.u_range.each {|u| assert(u.between?(0.0, 1.0)) }
        region.v_range.each {|v| assert(v.between?(0.0, 1.0)) }
      end
      assert_equal(9, mesh.patches[0].vertices.length)
    end

    it "applies the color function after interpolating the corner colors" do
      function = {FunctionType: 2, Domain: [0, 1], C0: [0.0], C1: [1.0], N: 2}
      mesh = two_patch_shading(Function: function).sample(tolerance: 0.05, max_subdivisions: 64)
      assert(mesh.tolerance_met?)
      n = mesh.subdivisions
      assert(n.even?)
      # The interpolated input 0.5 maps to 0.5**2 = 0.25; applying the function to the
      # corner colors first would incorrectly yield 0.5.
      assert_in_delta(0.25, mesh.patches[0].vertex_at(n / 2, n / 2).color[0])
    end

    it "validates the sampling arguments" do
      assert_raises(ArgumentError) { two_patch_shading.sample(tolerance: 0) }
      assert_raises(ArgumentError) { two_patch_shading.sample(max_subdivisions: 0) }
    end
  end

  describe "color functions" do
    it "evaluates type 2 exponential functions and clips to the domain" do
      func = HexaPDF::Type::Shading::Function.create(
        @doc.wrap({FunctionType: 2, Domain: [0, 1], C0: [0.0], C1: [1.0], N: 2})
      )
      assert_in_delta(0.25, func.call([0.5])[0])
      assert_in_delta(1.0, func.call([2.0])[0])
    end

    it "evaluates type 3 stitching functions" do
      func = HexaPDF::Type::Shading::Function.create(
        @doc.wrap({FunctionType: 3, Domain: [0, 1], Bounds: [0.5], Encode: [0, 1, 0, 1],
                   Functions: [{FunctionType: 2, Domain: [0, 1], C0: [0.0], C1: [0.5], N: 1},
                               {FunctionType: 2, Domain: [0, 1], C0: [0.5], C1: [1.0], N: 1}]})
      )
      assert_in_delta(0.25, func.call([0.25])[0])
      assert_in_delta(0.75, func.call([0.75])[0])
    end

    it "evaluates type 0 sampled functions with linear interpolation" do
      func = HexaPDF::Type::Shading::Function.create(
        @doc.wrap({FunctionType: 0, Domain: [0, 1], Range: [0, 1], Size: [2],
                   BitsPerSample: 8}, stream: [255, 0].pack('C*'))
      )
      assert_in_delta(1.0, func.call([0.0])[0])
      assert_in_delta(0.0, func.call([1.0])[0])
      assert_in_delta(0.5, func.call([0.5])[0])
      assert_in_delta(0.75, func.call([0.25])[0])
    end

    it "evaluates an array of functions as one function per output component" do
      func = HexaPDF::Type::Shading::Function.create(
        @doc.wrap([{FunctionType: 2, Domain: [0, 1], C0: [0.0], C1: [1.0], N: 1},
                   {FunctionType: 2, Domain: [0, 1], C0: [1.0], C1: [0.0], N: 1}])
      )
      result = func.call([0.25])
      assert_in_delta(0.25, result[0])
      assert_in_delta(0.75, result[1])
    end

    it "raises an error for type 4 PostScript calculator functions" do
      assert_raises(HexaPDF::Error) do
        HexaPDF::Type::Shading::Function.create(
          @doc.wrap({FunctionType: 4, Domain: [0, 1], Range: [0, 1]})
        )
      end
    end
  end
end
