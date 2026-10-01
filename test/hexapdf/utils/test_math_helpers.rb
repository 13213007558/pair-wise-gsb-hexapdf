# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/utils/math_helpers'

describe HexaPDF::Utils::MathHelpers do
  before do
    @mod = HexaPDF::Utils::MathHelpers
  end

  it "converts between degrees and radians" do
    assert_in_delta(Math::PI, @mod.deg_to_rad(180), 1e-12)
    assert_in_delta(180, @mod.rad_to_deg(Math::PI), 1e-12)
  end

  describe "::solve_linear_system3" do
    it "solves a system of three linear equations" do
      matrix = [[2, 1, 0], [-1, 2, 0], [1, 0, 1]]
      result = @mod.solve_linear_system3(matrix, [1, 4, 3])
      assert_in_delta(-0.4, result[0], 1e-12)
      assert_in_delta(1.8, result[1], 1e-12)
      assert_in_delta(3.4, result[2], 1e-12)
    end

    it "returns nil for a singular matrix" do
      assert_nil(@mod.solve_linear_system3([[1, 2, 3], [4, 5, 6], [7, 8, 9]], [1, 2, 3]))
      assert_nil(@mod.solve_linear_system3([[0, 0, 0], [0, 0, 0], [0, 0, 0]], [0, 0, 0]))
    end

    it "does not modify the matrix or vector" do
      matrix = [[2, 0, 0], [0, 4, 0], [0, 0, 8]]
      vector = [2, 8, 16]
      @mod.solve_linear_system3(matrix, vector)
      assert_equal([[2, 0, 0], [0, 4, 0], [0, 0, 8]], matrix)
      assert_equal([2, 8, 16], vector)
    end
  end
end
