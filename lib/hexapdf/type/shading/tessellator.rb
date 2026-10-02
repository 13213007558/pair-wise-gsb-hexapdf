# -*- encoding: utf-8; frozen_string_literal: true -*-
#
#--
# This file is part of HexaPDF.
#
# HexaPDF - A Versatile PDF Creation and Manipulation Library For Ruby
# Copyright (C) 2014-2026 Thomas Leitner
#
# HexaPDF is free software: you can redistribute it and/or modify it
# under the terms of the GNU Affero General Public License version 3 as
# published by the Free Software Foundation with the addition of the
# following permission added to Section 15 as permitted in Section 7(a):
# FOR ANY PART OF THE COVERED WORK IN WHICH THE COPYRIGHT IS OWNED BY
# THOMAS LEITNER, THOMAS LEITNER DISCLAIMS THE WARRANTY OF NON
# INFRINGEMENT OF THIRD PARTY RIGHTS.
#
# HexaPDF is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public
# License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with HexaPDF. If not, see <http://www.gnu.org/licenses/>.
#
# The interactive user interfaces in modified source and object code
# versions of HexaPDF must display Appropriate Legal Notices, as required
# under Section 5 of the GNU Affero General Public License version 3.
#
# In accordance with Section 7(b) of the GNU Affero General Public
# License, a covered work must retain the producer line in every PDF that
# is created or manipulated using HexaPDF.
#
# If the GNU Affero General Public License doesn't fit your need,
# commercial licenses are available at <https://gettalong.at/hexapdf/>.
#++

module HexaPDF
  module Type
    class Shading

      # Tessellates the patches of a patch mesh shading (shading type 6 or 7) into triangles
      # within a given error tolerance. See Shading#triangles for details.
      #
      # The tessellation of a patch works on its parameter domain (the unit square):
      #
      # * Each of the four boundary curves is split into a number of segments that only
      #   depends on the curve itself and the tolerance. Adjacent patches therefore use
      #   identical split points along their shared edge and no seams appear.
      #
      # * The interior is covered by a regular grid whose resolution is derived from bounds
      #   of the second derivatives of the geometry and of the color gradient.
      #
      # * The strips between the (possibly coarser) boundary polylines and the interior grid
      #   are triangulated separately; long boundary chords are subdivided using collinear
      #   Steiner points so that the error bound also holds there.
      #
      # Both Coons patches and tensor-product patches are evaluated through their bicubic
      # Bezier control net; colors are interpolated bilinearly between the corner colors.
      class Tessellator

        # A vertex of the tessellation.
        #
        # s, t:: The parameters of the vertex in the unit square.
        # point:: The [x, y] position of the vertex.
        # color:: The color of the vertex as an array of color components.
        Vertex = Struct.new(:s, :t, :point, :color)

        # Creates a new tessellator for the given error +tolerance+ and the optional
        # +transformation_matrix+ (a HexaPDF::Content::TransformationMatrix) which is
        # applied to the control points before tessellation so that the tolerance is
        # measured in the transformed coordinate system.
        def initialize(tolerance, transformation_matrix = nil)
          @tolerance = tolerance
          @matrix = transformation_matrix
        end

        # Tessellates the given Shading::Patch of the given shading type (6 or 7) and
        # returns an array of Shading::Triangle objects.
        def tessellate(patch, shading_type)
          points = patch.points.map {|x, y| @matrix ? @matrix.evaluate(x, y) : [x, y] }
          return [] if degenerate?(points)

          @net = (shading_type == 6 ? coons_control_net(points) : tensor_control_net(points))
          @colors = patch.colors

          n_bottom = edge_divisions(@net[0][0], @net[1][0], @net[2][0], @net[3][0])
          n_top = edge_divisions(@net[0][3], @net[1][3], @net[2][3], @net[3][3])
          n_left = edge_divisions(@net[0][0], @net[0][1], @net[0][2], @net[0][3])
          n_right = edge_divisions(@net[3][0], @net[3][1], @net[3][2], @net[3][3])
          ni_u, ni_v = interior_divisions
          n_u = [n_bottom, n_top, ni_u].max
          n_v = [n_left, n_right, ni_v].max

          bottom = edge_chain([@net[0][0], @net[1][0], @net[2][0], @net[3][0]], n_bottom, n_u, 0)
          top = edge_chain([@net[0][3], @net[1][3], @net[2][3], @net[3][3]], n_top, n_u, 1)
          left = edge_chain([@net[0][0], @net[0][1], @net[0][2], @net[0][3]], n_left, n_v, 2)
          right = edge_chain([@net[3][0], @net[3][1], @net[3][2], @net[3][3]], n_right, n_v, 3)

          triangles = []
          if n_u >= 2 && n_v >= 2
            grid = (1...n_u).map do |i|
              (1...n_v).map {|j| surface_vertex(i.to_f / n_u, j.to_f / n_v) }
            end
            vertex_at = lambda {|i, j| grid[i - 1][j - 1] }
            (1..(n_u - 2)).each do |i|
              (1..(n_v - 2)).each do |j|
                v00 = vertex_at.call(i, j)
                v10 = vertex_at.call(i + 1, j)
                v01 = vertex_at.call(i, j + 1)
                v11 = vertex_at.call(i + 1, j + 1)
                triangles << build_triangle(v00, v10, v11)
                triangles << build_triangle(v00, v11, v01)
              end
            end
            bottom_inner = [bottom[0]] + (1...n_u).map {|i| vertex_at.call(i, 1) } + [bottom[-1]]
            top_inner = [top[0]] + (1...n_u).map {|i| vertex_at.call(i, n_v - 1) } + [top[-1]]
            left_inner = [left[0]] + (1...n_v).map {|j| vertex_at.call(1, j) } + [left[-1]]
            right_inner = [right[0]] + (1...n_v).map {|j| vertex_at.call(n_u - 1, j) } + [right[-1]]
            triangles.concat(walk_strip(bottom, bottom_inner, 0))
            triangles.concat(walk_strip(top_inner, top, 0))
            triangles.concat(walk_strip(left, left_inner, 1))
            triangles.concat(walk_strip(right_inner, right, 1))
          elsif n_v == 1
            triangles.concat(walk_strip(bottom, top, 0))
          else
            triangles.concat(walk_strip(left, right, 1))
          end
          triangles.compact!
          triangles
        end

        private

        # Returns the bicubic control net of a Coons patch from its 12 control points. The
        # interior control points are derived from the boundary control points so that the
        # resulting Bezier surface is identical to the Coons patch surface.
        def coons_control_net(p)
          net = [[p[0], p[11], p[10], p[9]],
                 [p[1], nil, nil, p[8]],
                 [p[2], nil, nil, p[7]],
                 [p[3], p[4], p[5], p[6]]]
          net[1][1] = interior_point(net[0][0], net[0][1], net[1][0], net[0][3], net[3][0],
                                     net[1][3], net[3][1], net[3][3])
          net[2][1] = interior_point(net[3][0], net[2][0], net[3][1], net[0][0], net[3][3],
                                     net[0][1], net[2][3], net[0][3])
          net[1][2] = interior_point(net[0][3], net[0][2], net[1][3], net[0][0], net[3][3],
                                     net[1][0], net[3][2], net[3][0])
          net[2][2] = interior_point(net[3][3], net[2][3], net[3][2], net[0][3], net[3][0],
                                     net[2][0], net[0][2], net[0][0])
          net
        end

        # Returns the bicubic control net of a tensor-product patch from its 16 control
        # points.
        def tensor_control_net(p)
          [[p[0], p[1], p[2], p[3]],
           [p[4], p[5], p[6], p[7]],
           [p[8], p[9], p[10], p[11]],
           [p[12], p[13], p[14], p[15]]]
        end

        # Computes one interior control point of the bicubic control net of a Coons patch.
        #
        # c:: The corner nearest to the interior point.
        # e1, e2:: The boundary control points adjacent to the corner.
        # a1, a2:: The two corners adjacent to the corner.
        # f1, f2:: The boundary control points on the edges not touching the corner.
        # o:: The opposite corner.
        def interior_point(c, e1, e2, a1, a2, f1, f2, o)
          [(-4 * c[0] + 6 * (e1[0] + e2[0]) - 2 * (a1[0] + a2[0]) + 3 * (f1[0] + f2[0]) - o[0]) / 9.0,
           (-4 * c[1] + 6 * (e1[1] + e2[1]) - 2 * (a1[1] + a2[1]) + 3 * (f1[1] + f2[1]) - o[1]) / 9.0]
        end

        # Returns true if the patch is degenerate, i.e. if all its control points coincide.
        def degenerate?(points)
          min_x = max_x = points[0][0]
          min_y = max_y = points[0][1]
          points.each do |(x, y)|
            min_x = x if x < min_x
            max_x = x if x > max_x
            min_y = y if y < min_y
            max_y = y if y > max_y
          end
          min_x == max_x && min_y == max_y
        end

        # Returns the number of segments into which the cubic Bezier curve with the given
        # control points has to be split so that the resulting polyline approximates the
        # curve within the tolerance. The result is always a power of two and only depends
        # on the curve itself, so adjacent patches sharing an edge use identical split
        # points.
        def edge_divisions(p0, p1, p2, p3)
          segments = [[p0, p1, p2, p3]]
          divisions = 1
          until segments.all? {|(a, b, c, d)| curve_flat?(a, b, c, d) }
            segments = segments.flat_map {|(a, b, c, d)| split_curve(a, b, c, d) }
            divisions *= 2
          end
          divisions
        end

        # Returns true if the cubic Bezier curve is approximated by its chord within the
        # tolerance (using the convex hull property as a conservative bound).
        def curve_flat?(p0, p1, p2, p3)
          point_line_distance(p1, p0, p3) <= @tolerance &&
            point_line_distance(p2, p0, p3) <= @tolerance
        end

        # Returns the distance of +point+ from the line through +a+ and +b+ (or from the
        # point +a+ itself if +a+ and +b+ coincide).
        def point_line_distance(point, a, b)
          dx = b[0] - a[0]
          dy = b[1] - a[1]
          length = Math.sqrt(dx * dx + dy * dy)
          if length == 0.0
            Math.sqrt((point[0] - a[0])**2 + (point[1] - a[1])**2)
          else
            ((point[0] - a[0]) * dy - (point[1] - a[1]) * dx).abs / length
          end
        end

        # Splits the cubic Bezier curve at its midpoint into two curves (de Casteljau).
        def split_curve(p0, p1, p2, p3)
          p01 = midpoint(p0, p1)
          p12 = midpoint(p1, p2)
          p23 = midpoint(p2, p3)
          p012 = midpoint(p01, p12)
          p123 = midpoint(p12, p23)
          p0123 = midpoint(p012, p123)
          [[p0, p01, p012, p0123], [p0123, p123, p23, p3]]
        end

        def midpoint(a, b)
          [(a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0]
        end

        # Returns the required number of subdivisions of the parameter domain in u and v
        # direction for the interior of the patch, based on bounds of the second
        # derivatives of the geometry and of the color gradient.
        def interior_divisions
          m_uu = m_vv = m_uv = 0.0
          4.times do |j|
            2.times do |i|
              m_uu = [m_uu, 6 * vector_norm(second_difference(@net[i][j], @net[i + 1][j],
                                                              @net[i + 2][j]))].max
              m_vv = [m_vv, 6 * vector_norm(second_difference(@net[j][i], @net[j][i + 1],
                                                              @net[j][i + 2]))].max
            end
          end
          3.times do |i|
            3.times do |j|
              mixed = [@net[i + 1][j + 1][0] - @net[i + 1][j][0] - @net[i][j + 1][0] + @net[i][j][0],
                       @net[i + 1][j + 1][1] - @net[i + 1][j][1] - @net[i][j + 1][1] + @net[i][j][1]]
              m_uv = [m_uv, 9 * vector_norm(mixed)].max
            end
          end
          m_color = 0.0
          c0, c1, c2, c3 = @colors
          c0.each_index do |k|
            m_color = [m_color, (c0[k] - c1[k] + c2[k] - c3[k]).abs].max
          end

          n_u = n_v = 1
          loop do
            geometry_error = 0.5 * (m_uu / (n_u * n_u).to_f + 2.0 * m_uv / (n_u * n_v).to_f +
                                    m_vv / (n_v * n_v).to_f)
            color_error = m_color / (n_u * n_v).to_f
            break if geometry_error <= @tolerance && color_error <= @tolerance
            if m_uu / (n_u * n_u).to_f >= m_vv / (n_v * n_v).to_f
              n_u *= 2
            else
              n_v *= 2
            end
          end
          [n_u, n_v]
        end

        def second_difference(p0, p1, p2)
          [p2[0] - 2 * p1[0] + p0[0], p2[1] - 2 * p1[1] + p0[1]]
        end

        def vector_norm(v)
          Math.sqrt(v[0] * v[0] + v[1] * v[1])
        end

        # Returns the polyline approximating one boundary curve of the patch, as an array of
        # Vertex objects. The curve is split into +divisions+ curve segments; if the
        # interior grid is finer (+grid_divisions+), additional collinear Steiner points are
        # inserted on the chords so that no chain segment is longer than 1/+grid_divisions+
        # in parameter space. The +side+ (0: bottom, 1: top, 2: left, 3: right) determines
        # the mapping of the curve parameter to the (s, t) parameters of the patch.
        def edge_chain(curve, divisions, grid_divisions, side)
          curve_points = (0..divisions).map do |k|
            bezier_point(curve, k.to_f / divisions)
          end
          steiner = grid_divisions / divisions
          chain = []
          divisions.times do |k|
            chain << edge_vertex(curve_points[k], k.to_f / divisions, side)
            (1...steiner).each do |j|
              fraction = j.to_f / steiner
              point = interpolate(curve_points[k], curve_points[k + 1], fraction)
              chain << edge_vertex(point, (k + fraction) / divisions, side)
            end
          end
          chain << edge_vertex(curve_points[divisions], 1.0, side)
          chain
        end

        def edge_vertex(point, u, side)
          case side
          when 0 then surface_vertex(u, 0.0, point)
          when 1 then surface_vertex(u, 1.0, point)
          when 2 then surface_vertex(0.0, u, point)
          else surface_vertex(1.0, u, point)
          end
        end

        # Returns the vertex at parameters (+s+, +t+); the position is taken from +point+ if
        # given, otherwise it is evaluated on the bicubic surface.
        def surface_vertex(s, t, point = nil)
          Vertex.new(s, t, point || bicubic_point(s, t), bilinear_color(s, t))
        end

        def interpolate(a, b, fraction)
          [a[0] + (b[0] - a[0]) * fraction, a[1] + (b[1] - a[1]) * fraction]
        end

        # Evaluates the cubic Bezier curve with the given four control points at +u+.
        def bezier_point(curve, u)
          v = 1.0 - u
          b0 = v * v * v
          b1 = 3.0 * v * v * u
          b2 = 3.0 * v * u * u
          b3 = u * u * u
          [b0 * curve[0][0] + b1 * curve[1][0] + b2 * curve[2][0] + b3 * curve[3][0],
           b0 * curve[0][1] + b1 * curve[1][1] + b2 * curve[2][1] + b3 * curve[3][1]]
        end

        # Evaluates the bicubic Bezier control net at parameters (+s+, +t+).
        def bicubic_point(s, t)
          bs = bernstein(s)
          bt = bernstein(t)
          x = y = 0.0
          4.times do |i|
            4.times do |j|
              weight = bs[i] * bt[j]
              x += weight * @net[i][j][0]
              y += weight * @net[i][j][1]
            end
          end
          [x, y]
        end

        def bernstein(u)
          v = 1.0 - u
          [v * v * v, 3.0 * v * v * u, 3.0 * v * u * u, u * u * u]
        end

        # Returns the bilinearly interpolated color at parameters (+s+, +t+).
        def bilinear_color(s, t)
          c0, c1, c2, c3 = @colors
          w0 = (1.0 - s) * (1.0 - t)
          w1 = s * (1.0 - t)
          w2 = s * t
          w3 = (1.0 - s) * t
          c0.each_index.map do |k|
            w0 * c0[k] + w1 * c1[k] + w2 * c2[k] + w3 * c3[k]
          end
        end

        # Triangulates the strip between the two chains of vertices and returns the
        # triangles. Both chains have to be monotone in the coordinate with the given index
        # (0 for s, 1 for t) and have to share their first and last vertices.
        def walk_strip(chain_a, chain_b, coordinate)
          triangles = []
          i = j = 0
          last_a = chain_a.length - 1
          last_b = chain_b.length - 1
          while i < last_a || j < last_b
            if j == last_b || (i < last_a && chain_a[i + 1][coordinate] <= chain_b[j + 1][coordinate])
              triangles << build_triangle(chain_a[i], chain_b[j], chain_a[i + 1])
              i += 1
            else
              triangles << build_triangle(chain_a[i], chain_b[j], chain_b[j + 1])
              j += 1
            end
          end
          triangles
        end

        # Builds a Shading::Triangle from three vertices; returns nil if the triangle is
        # degenerate in parameter space (this happens at the corners of the interior grid
        # where two chains share a vertex).
        def build_triangle(v1, v2, v3)
          return nil if same_position?(v1, v2) || same_position?(v2, v3) || same_position?(v1, v3)
          Triangle.new([v1.point, v2.point, v3.point], [v1.color, v2.color, v3.color])
        end

        def same_position?(v1, v2)
          v1.s == v2.s && v1.t == v2.t
        end

      end

    end
  end
end
