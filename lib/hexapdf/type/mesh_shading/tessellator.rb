# -*- encoding: utf-8; frozen_string_literal: true -*-
#
#--
# This file is part of HexaPDF.
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
# by Section 5 of the GNU Affero General Public License version 3.
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
    class MeshShading < Stream
      class Tessellator
        PreparedPatch = Struct.new(:patch, :geometry, :colors, :degenerate, :levels,
                                   keyword_init: true)
        Vertex = Struct.new(:point, :color, keyword_init: true)

        def initialize(shading)
          @shading = shading
          @edge_cache = {}
        end

        def triangles(patches, tolerance:, color_tolerance: tolerance, matrix: nil)
          transformation = resolve_matrix(matrix)
          prepared = patches.map {|patch| prepare_patch(patch, transformation) }
          prepared.each {|patch| assign_levels(patch, tolerance, color_tolerance) }
          synchronize_shared_edges(prepared)
          prepared.reject(&:degenerate).flat_map {|patch| build_triangles(patch) }
        end

        private

        def resolve_matrix(matrix)
          values = case matrix
                   when nil then Array(@shading[:Matrix])
                   when HexaPDF::Content::TransformationMatrix then matrix.to_a
                   else Array(matrix)
                   end
          unless values.length == 6 && values.all? {|value| value.kind_of?(Numeric) }
            raise HexaPDF::Error, 'Mesh transformation matrix needs six numeric entries'
          end
          values
        end

        def transform(point, matrix)
          [matrix[0] * point[0] + matrix[2] * point[1] + matrix[4],
           matrix[1] * point[0] + matrix[3] * point[1] + matrix[5]]
        end

        def prepare_patch(patch, matrix)
          points = patch.points.map {|point| transform(point, matrix) }
          geometry = patch.type == 7 ? points : coons_geometry_net(patch.points)
          geometry = geometry.map {|point| transform(point, matrix) }
          patch.points = points
          PreparedPatch.new(patch: patch_with_points(patch, points), geometry: geometry,
                            colors: color_net(patch), degenerate: degenerate?(points),
                            levels: {})
        end

        def patch_with_points(patch, points)
          patch.dup.tap {|copy| copy.edges = edges_for(patch, points) }
        end

        def edges_for(patch, points)
          if patch.type == 6
            [points.values_at(0, 1, 2, 3), points.values_at(3, 4, 5, 6),
             points.values_at(6, 7, 8, 9), points.values_at(9, 10, 11, 0)]
          else
            [points.values_at(0, 1, 2, 3), points.values_at(3, 7, 11, 15),
             points.values_at(15, 14, 13, 12), points.values_at(12, 8, 4, 0)]
          end
        end

        def color_net(patch)
          bottom_left, bottom_right, top_right, top_left = patch.colors
          Array.new(16) do |index|
            row = index / 4
            column = index % 4
            s = [0.0, 1.0 / 3, 2.0 / 3, 1.0][column]
            t = [0.0, 1.0 / 3, 2.0 / 3, 1.0][row]
            bottom_left.zip(bottom_right, top_right, top_left).map do |a, b, c, d|
              (1 - s) * (1 - t) * a + s * (1 - t) * b + s * t * c + (1 - s) * t * d
            end
          end
        end

        def coons_geometry_net(points)
          bottom = points[0..3]
          right = points[3..6]
          top = points[6..9]
          left = [points[9], points[10], points[11], points[0]]
          net = Array.new(16)
          set_row(net, 0, bottom)
          set_row(net, 3, top.reverse)
          net[3] = right[0]
          net[7] = right[1]
          net[11] = right[2]
          net[15] = right[3]
          net[4] = left[1]
          net[8] = left[2]
          net[12] = left[3]
          [1, 2].each do |row|
            v = row.to_f / 3
            [1, 2].each do |column|
              u = column.to_f / 3
              bilinear = add(scale(bottom[0], (1 - u) * (1 - v)),
                             add(scale(bottom[3], u * (1 - v)),
                                 add(scale(top[3], u * v), scale(top[0], (1 - u) * v))))
              v_ruled = add(scale(bezier(left, v), 1 - u), scale(bezier(right, v), u))
              u_ruled = add(scale(bezier(bottom, u), 1 - v), scale(bezier(top, u), v))
              net[row * 4 + column] = subtract(add(v_ruled, u_ruled), bilinear)
            end
          end
          net
        end

        def set_row(net, row, values)
          values.each_with_index {|value, column| net[row * 4 + column] = value }
        end

        def add(a, b)
          [a[0] + b[0], a[1] + b[1]]
        end

        def subtract(a, b)
          [a[0] - b[0], a[1] - b[1]]
        end

        def scale(point, factor)
          [point[0] * factor, point[1] * factor]
        end

        def degenerate?(points)
          xs = points.map {|point| point[0] }
          ys = points.map {|point| point[1] }
          (xs.max - xs.min).zero? || (ys.max - ys.min).zero?
        end

        def assign_levels(patch, tolerance, color_tolerance)
          return if patch.degenerate
          level = [surface_level(patch.geometry, tolerance),
                   surface_level(patch.colors, color_tolerance)].max
          patch.levels[:grid] = level
          4.times do |edge|
            patch.levels[edge] = [level, edge_level(patch.geometry, edge, tolerance),
                                  edge_level(patch.colors, edge, color_tolerance)].max
          end
        end

        def surface_level(net, tolerance)
          return 1 unless tolerance.positive?
          column_bounds = [0, 1, 2, 3].map {|fixed| second_derivative(net, fixed, :column) }
          row_bounds = [0, 1, 2, 3].map {|fixed| second_derivative(net, fixed, :row) }
          bound = [(column_bounds + row_bounds).max * 9.0, mixed_derivative(net) * 9.0].max
          level_for_bound(bound, tolerance, 64.0)
        end

        def edge_level(net, edge, tolerance)
          return 1 unless tolerance.positive?
          values = edge_values(net, edge)
          first = vector_subtract(values[2], scale_vector(values[1], 2), values[0])
          second = vector_subtract(values[3], scale_vector(values[2], 2), values[1])
          level_for_bound([norm(first), norm(second)].max * 6.0, tolerance, 48.0)
        end

        def level_for_bound(bound, tolerance, allowance)
          return 1 if bound <= allowance * tolerance
          level = Math.sqrt(bound / (2.0 * tolerance)).ceil
          [level, 1].max
        end

        def second_derivative(net, fixed, direction)
          values = if direction == :column
                     (0..3).map {|index| net[fixed * 4 + index] }
                   else
                     (0..3).map {|index| net[index * 4 + fixed] }
                   end
          second_differences(values).map {|value| norm(value) }.max
        end

        def mixed_derivative(net)
          values = 0.upto(1).flat_map do |row|
            0.upto(1).flat_map do |column|
              3.times.flat_map do |row_offset|
                3.times.map do |column_offset|
                  row_weight = [1, -3, 3, -1][row_offset]
                  column_weight = [1, -3, 3, -1][column_offset]
                  weight = row_weight * column_weight
                  scale_vector(net[(row + row_offset) * 4 + column + column_offset], weight)
                end
              end
            end
          end
          values.map {|value| norm(value) }.max
        end

        def second_differences(values)
          [vector_subtract(values[2], scale_vector(values[1], 2), values[0]),
           vector_subtract(values[3], scale_vector(values[2], 2), values[1])]
        end

        def edge_values(net, edge)
          case edge
          when 0 then net.values_at(0, 1, 2, 3)
          when 1 then net.values_at(3, 7, 11, 15)
          when 2 then net.values_at(15, 14, 13, 12)
          when 3 then net.values_at(12, 8, 4, 0)
          end
        end

        def synchronize_shared_edges(prepared)
          edge_map = {}
          prepared.each do |patch|
            next if patch.degenerate
            patch.patch.edges.each_with_index do |edge, index|
              key = edge_key(edge)
              if (shared = edge_map[key])
                level = [patch.levels[index], shared[:level]].max
                patch.levels[index] = level
                shared[:patch].levels[shared[:index]] = level
                patch.levels[:grid] = [patch.levels[:grid], level].max
                shared[:patch].levels[:grid] = [shared[:patch].levels[:grid], level].max
              else
                edge_map[key] = {patch: patch, index: index, level: patch.levels[index]}
              end
            end
          end
        end

        def edge_key(edge)
          rounded = edge.map {|point| point.map {|value| value.round(10) } }
          [rounded, rounded.reverse].min
        end

        def build_triangles(patch)
          level = patch.levels[:grid]
          grid = Array.new(level + 1) { Array.new(level + 1) }
          vertices = edge_vertices(patch, level)
          4.times {|edge| assign_edge(grid, edge, level, vertices[edge]) }
          (1...level).each do |row|
            (1...level).each do |column|
              grid[row][column] = evaluate_vertex(patch, row.to_f / level, column.to_f / level)
            end
          end
          result = []
          (0...level).each do |row|
            (0...level).each do |column|
              result << triangle(grid[row][column], grid[row][column + 1], grid[row + 1][column])
              result << triangle(grid[row][column + 1], grid[row + 1][column + 1],
                                 grid[row + 1][column])
            end
          end
          result
        end

        def edge_vertices(patch, level)
          4.times.map do |edge|
            curve = patch.patch.edges[edge]
            rounded = curve.map {|point| point.map {|value| value.round(10) } }
            canonical = [rounded, rounded.reverse].min
            reversed = rounded != canonical
            color_values = edge_values(patch.colors, edge)
            color_values = color_values.reverse if reversed
            points = @edge_cache[[canonical, level]] ||= (0..level).map do |offset|
              t = offset.to_f / level
              bezier(canonical, t)
            end
            ordered_points = reversed ? points.reverse : points
            (0..level).map do |offset|
              Vertex.new(point: ordered_points[offset], color: bezier(color_values, offset.to_f / level))
            end
          end
        end

        def assign_edge(grid, edge, level, vertices)
          (0..level).each do |offset|
            case edge
            when 0 then grid[0][offset] = vertices[offset]
            when 1 then grid[offset][level] = vertices[offset]
            when 2 then grid[level][level - offset] = vertices[offset]
            when 3 then grid[level - offset][0] = vertices[offset]
            end
          end
        end

        def evaluate_vertex(patch, s, t)
          Vertex.new(point: evaluate(patch.geometry, s, t), color: evaluate(patch.colors, s, t))
        end

        def bezier(values, t)
          inverse = 1 - t
          a = scale_vector(values[0], inverse * inverse * inverse)
          b = scale_vector(values[1], 3 * inverse * inverse * t)
          c = scale_vector(values[2], 3 * inverse * t * t)
          d = scale_vector(values[3], t * t * t)
          vector_add(vector_add(a, b), vector_add(c, d))
        end

        def evaluate(net, s, t)
          component_count = net[0].length
          Array.new(component_count) do |component|
            sum = 0.0
            4.times do |row|
              4.times do |column|
                sum += bernstein(row, t) * bernstein(column, s) * net[row * 4 + column][component]
              end
            end
            sum
          end
        end

        def bernstein(index, value)
          inverse = 1 - value
          powers = [inverse * inverse * inverse, inverse * inverse * value,
                    inverse * value * value, value * value * value]
          [1, 3, 3, 1][index] * powers[index]
        end

        def triangle(a, b, c)
          MeshShading::Triangle.new(points: [a.point, b.point, c.point],
                                    colors: [a.color, b.color, c.color])
        end

        def vector_add(a, b)
          a.zip(b).map {|x, y| x + y }
        end

        def vector_subtract(first, *rest)
          rest.reduce(first) {|result, vector| result.zip(vector).map {|x, y| x - y } }
        end

        def scale_vector(vector, factor)
          vector.map {|value| value * factor }
        end

        def norm(vector)
          Math.sqrt(vector.sum {|value| value * value })
        end
      end
    end
  end
end
