# -*- encoding: utf-8; frozen_string_literal: true -*-

module HexaPDF
  module Type
    class Shading

      # A single patch of a Type 6 (Coons patch mesh) or Type 7 (tensor-product patch mesh)
      # shading.
      #
      # The patch is defined over the unit square; the parameter position (0, 0) corresponds
      # to corner c0, (1, 0) to c1, (1, 1) to c2 and (0, 1) to c3.
      class Patch

        # The kind of patch: +:coons+ for Type 6 shadings, +:tensor+ for Type 7 shadings.
        attr_reader :type

        # The control points of the patch as [x, y] pairs, in the order defined by the PDF
        # specification (12 points for Coons patches, 16 for tensor-product patches).
        attr_reader :points

        # The colors of the four corners as arrays of color input components, in the order
        # c0 (top-left), c1 (top-right), c2 (bottom-right), c3 (bottom-left).
        attr_reader :colors

        def initialize(type, points, colors)
          @type = type
          @points = points
          @colors = colors
        end

        # Returns the four corner control points [P00, P10, P11, P01] of the patch.
        def corners
          if type == :coons
            [points[0], points[3], points[6], points[9]]
          else
            [points[0], points[3], points[15], points[12]]
          end
        end

        # Evaluates the patch surface at the parameter position (+u+, +v+), with +u+ and +v+
        # in the range [0, 1], and returns the position as [x, y] in shading space.
        def evaluate(u, v)
          type == :coons ? evaluate_coons(u, v) : evaluate_tensor(u, v)
        end

        # Returns the color input components at the parameter position (+u+, +v+), bilinearly
        # interpolated from the corner colors.
        #
        # If the shading defines a color function, it has to be applied to the returned
        # components (see Shading#color_transform).
        def color_at(u, v)
          c0, c1, c2, c3 = colors
          w00 = (1 - u) * (1 - v)
          w10 = u * (1 - v)
          w11 = u * v
          w01 = (1 - u) * v
          c0.each_index.map do |i|
            w00 * c0[i] + w10 * c1[i] + w11 * c2[i] + w01 * c3[i]
          end
        end

        private

        # Coons patch interpolation of the four boundary curves:
        #
        #   S(u, v) = SC(u, v) + SB(u, v) - ST(u, v)
        #
        # where SC interpolates the left/right edge curves along u, SB interpolates the
        # top/bottom edge curves along v and ST is the bilinear interpolation of the corner
        # points.
        def evaluate_coons(u, v)
          p = points
          top = cubic_bezier(p[0], p[1], p[2], p[3], u)
          bottom = cubic_bezier(p[9], p[10], p[11], p[6], u)
          left = cubic_bezier(p[0], p[11], p[10], p[9], v)
          right = cubic_bezier(p[3], p[4], p[5], p[6], v)
          c00 = p[0]
          c10 = p[3]
          c11 = p[6]
          c01 = p[9]
          w00 = (1 - u) * (1 - v)
          w10 = u * (1 - v)
          w11 = u * v
          w01 = (1 - u) * v
          [
            (1 - v) * top[0] + v * bottom[0] + (1 - u) * left[0] + u * right[0] -
              (w00 * c00[0] + w10 * c10[0] + w11 * c11[0] + w01 * c01[0]),
            (1 - v) * top[1] + v * bottom[1] + (1 - u) * left[1] + u * right[1] -
              (w00 * c00[1] + w10 * c10[1] + w11 * c11[1] + w01 * c01[1]),
          ]
        end

        # Tensor-product interpolation of the 4x4 control point grid with cubic Bernstein
        # polynomials.
        def evaluate_tensor(u, v)
          bu = bernstein(u)
          bv = bernstein(v)
          x = 0.0
          y = 0.0
          4.times do |row|
            4.times do |col|
              weight = bu[col] * bv[row]
              point = points[row * 4 + col]
              x += weight * point[0]
              y += weight * point[1]
            end
          end
          [x, y]
        end

        def cubic_bezier(p0, p1, p2, p3, t)
          b = bernstein(t)
          [b[0] * p0[0] + b[1] * p1[0] + b[2] * p2[0] + b[3] * p3[0],
           b[0] * p0[1] + b[1] * p1[1] + b[2] * p2[1] + b[3] * p3[1]]
        end

        def bernstein(t)
          mt = 1 - t
          [mt * mt * mt, 3 * mt * mt * t, 3 * mt * t * t, t * t * t]
        end

      end

    end
  end
end
