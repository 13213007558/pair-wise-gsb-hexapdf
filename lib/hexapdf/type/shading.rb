# -*- coding: utf-8; frozen_string_literal: true -*-
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
# under Section 5 of the GNU Affero General Public License version 3.
#
# In accordance with Section 7(b) of the GNU Affero General Public
# License, a covered work must retain the producer line in every PDF that
# is created or manipulated using HexaPDF.
#
# If the GNU Affero General Public License doesn't fit your need,
# commercial licenses are available at <https://gettalong.at/hexapdf/>.
#++

require 'hexapdf/stream'
require 'hexapdf/utils/bit_stream'
require 'hexapdf/content/color_space'
require 'hexapdf/type/function'

module HexaPDF
  module Type

    # Represents a PDF shading dictionary/stream.
    #
    # The mesh parsers support shading types 6 (Coons patch mesh) and 7 (tensor-product patch
    # mesh). They decode geometry and colors from the packed bit stream but do not perform screen
    # rasterization.
    #
    # See: PDF2.0 s8.7.4.5.6, s8.7.4.5.7
    class Shading < Stream

      # A point in PDF shading coordinate space together with its decoded color components.
      Sample = Struct.new(:position, :color, :parameters, keyword_init: true)

      # The result of sampling a patch mesh.
      #
      # +unresolved_ranges+ contains one [patch_index, u_min, u_max, v_min, v_max, error] entry for
      # every cell whose geometric error is greater than the requested tolerance.
      SamplingResult = Struct.new(:samples, :unresolved_ranges, keyword_init: true)

      # A decoded Coons or tensor-product patch.
      #
      # +geometry+ and +colors+ are 4x4 arrays. Coons patches have only 12 distinct boundary
      # coordinates and 8 distinct boundary colors; the inner tensor control values are derived
      # according to the Coons equation.
      Patch = Struct.new(:index, :flag, :geometry, :colors, keyword_init: true)

      define_type :Shading

      define_field :ShadingType, type: Integer, required: true
      define_field :ColorSpace,  type: [Symbol, PDFArray, Dictionary], required: true
      define_field :Background,  type: PDFArray
      define_field :BBox,        type: PDFArray
      define_field :AntiAlias,  type: [TrueClass, FalseClass], default: false
      define_field :Function,    type: [Dictionary, PDFArray]

      # Yields every decoded patch in the mesh stream.
      def each_patch
        return patches.each unless block_given?
        patches.each {|patch| yield(patch) }
        self
      end

      # Samples every patch at a shared, uniformly subdivided level.
      #
      # +tolerance+ is measured in the shading coordinate system. Subdivision is shared for all
      # patches, so adjacent patches evaluate shared boundaries with identical points and colors.
      # If +max_subdivisions+ is insufficient, the affected parametric cell ranges are returned in
      # SamplingResult#unresolved_ranges instead of silently claiming convergence.
      def sample(tolerance: 1.0, max_subdivisions: 16)
        level = [[max_subdivisions.to_i, 0].max, 32].min
        subdivisions = 1 << level
        samples = []
        unresolved = []

        each_patch do |patch|
          cell_errors = patch_cell_errors(patch.geometry, subdivisions)
          cell_errors.each_with_index do |error_row, row|
            error_row.each_with_index do |error, column|
              next if error <= tolerance
              scale = 1.0 / subdivisions
              unresolved << [patch.index, column * scale, (column + 1) * scale,
                            row * scale, (row + 1) * scale, error]
            end
          end

          (subdivisions + 1).times do |row_index|
            v = row_index.to_f / subdivisions
            (subdivisions + 1).times do |column_index|
              u = column_index.to_f / subdivisions
              parameters = surface_value(patch.colors, u, v)
              samples << Sample.new(position: surface_value(patch.geometry, u, v),
                                   color: color_for(parameters), parameters: parameters)
            end
          end
        end

        SamplingResult.new(samples: samples, unresolved_ranges: unresolved)
      end

      private

      def patches
        @patches ||= parse_patches
      end

      def parse_patches
        unless [6, 7].include?(self[:ShadingType])
          raise HexaPDF::Error, "Unsupported shading type #{self[:ShadingType].inspect}"
        end
        unless [1, 2, 4, 8, 12, 16, 24, 32].include?(bits_coordinate) &&
            [1, 2, 4, 8, 12, 16].include?(bits_color)
          raise HexaPDF::Error, "Invalid BitsPerCoordinate or BitsPerComponent in shading"
        end
        unless decode_array.length == 4 + 2 * value_component_count
          raise HexaPDF::Error, "Invalid Decode array length in shading"
        end

        parser = MeshParser.new(self)
        parser.parse
      end

      def bits_coordinate
        self[:BitsPerCoordinate]
      end

      def bits_color
        self[:BitsPerComponent]
      end

      def decode_array
        Array(self[:Decode])
      end

      def coordinate_decode
        decode_array[0, 4]
      end

      def value_decode
        decode_array[4..]
      end

      def direct_color?
        !key?(:Function)
      end

      def value_component_count
        if direct_color?
          color_component_count
        else
          Array(Array(self[:Function]).first[:Domain] || [0, 1]).length / 2
        end
      end

      def color_component_count
        definition = self[:ColorSpace]
        family = definition.kind_of?(Array) ? definition[0] : definition
        case family
        when :DeviceGray then 1
        when :CalGray then 1
        when :DeviceRGB, :CalRGB, :Lab then 3
        when :DeviceCMYK then 4
        when :ICCBased then definition[1][:N]
        when :Indexed, :I then definition[1][:N] || 3
        when :Separation, :DeviceN then 1
        else
          raise HexaPDF::Error, "Unsupported shading color space #{family.inspect}"
        end
      end

      def color_for(parameters)
        values = direct_color? ? parameters : Type::Function.for(self[:Function]).evaluate(parameters)
        color_space.prenormalized_color(*values)
      end

      def color_space
        definition = self[:ColorSpace]
        family = definition.kind_of?(Array) ? definition[0] : definition
        GlobalConfiguration.constantize('color_space.map', family) do
          Content::ColorSpace::Universal
        end.new(definition)
      end

      def surface_value(grid, u, v)
        rows = grid.map {|row| evaluate_axis(row, u) }
        if rows.first.is_a?(Array)
          rows.first.length.times.map do |component|
            scalar_axis(rows.map {|point| point[component] }, v)
          end
        else
          scalar_axis(rows, v)
        end
      end

      def evaluate_axis(values, t)
        one_minus = 1.0 - t
        return scalar_axis(values, t) if values.none? {|value| value.is_a?(Array) }
        first = values[0]
        if first.kind_of?(Array)
          first.length.times.map do |index|
            component_at(values, 0, index) * one_minus ** 3 +
              3.0 * component_at(values, 1, index) * t * one_minus ** 2 +
              3.0 * component_at(values, 2, index) * t ** 2 * one_minus +
              component_at(values, 3, index) * t ** 3
          end
        else
          values[0] * one_minus ** 3 + 3.0 * values[1] * t * one_minus ** 2 +
            3.0 * values[2] * t ** 2 * one_minus + values[3] * t ** 3
        end
      end

      def scalar_axis(values, t)
        values[0] * (1 - t) ** 3 + 3 * values[1] * t * (1 - t) ** 2 +
          3 * values[2] * t ** 2 * (1 - t) + values[3] * t ** 3
      end

      def component_at(values, index, component)
        values[index][component]
      end

      def patch_cell_errors(grid, subdivisions)
        scale = 1.0 / subdivisions
        Array.new(subdivisions) do |row|
          Array.new(subdivisions) do |column|
            u0 = column * scale
            u1 = (column + 1) * scale
            v0 = row * scale
            v1 = (row + 1) * scale
            cell = subdivisions == 1 ? grid : sub_grid(grid, u0, u1, v0, v1)
            corners = [cell[0][0], cell[0][3], cell[3][0], cell[3][3]]
            dimension = corners.first.length
            bilinear_center = dimension.times.map do |component|
              corners.sum {|point| point[component] } / 4.0
            end
            [curve_error(cell[0]), curve_error(cell[3]),
             curve_error(cell.map {|cell_row| cell_row[0] }),
             curve_error(cell.map {|cell_row| cell_row[3] }),
             distance(surface_value(cell, 0.5, 0.5), bilinear_center)].max
          end
        end
      end

      def sub_grid(grid, u0, u1, v0, v1)
        _, u_tail = split_grid_along_u(grid, u0)
        u_cell, _ = split_grid_along_u(u_tail, (u1 - u0) / (1.0 - u0))
        _, v_tail = split_grid_along_v(u_cell, v0)
        v_cell, _ = split_grid_along_v(v_tail, (v1 - v0) / (1.0 - v0))
        v_cell
      end

      def split_grid_along_u(grid, parameter)
        rows = grid.map {|row| split_cubic(row, parameter) }
        [rows.map(&:first), rows.map(&:last)]
      end

      def split_grid_along_v(grid, parameter)
        first_rows = Array.new(4) { [] }
        second_rows = Array.new(4) { [] }
        grid.transpose.each do |column|
          left, right = split_cubic(column, parameter)
          left.each_with_index {|point, row| first_rows[row] << point }
          right.each_with_index {|point, row| second_rows[row] << point }
        end
        [first_rows, second_rows]
      end

      def split_cubic(controls, parameter)
        p01 = lerp(controls[0], controls[1], parameter)
        p12 = lerp(controls[1], controls[2], parameter)
        p23 = lerp(controls[2], controls[3], parameter)
        p012 = lerp(p01, p12, parameter)
        p123 = lerp(p12, p23, parameter)
        p0123 = lerp(p012, p123, parameter)
        [[controls[0], p01, p012, p0123], [p0123, p123, p23, controls[3]]]
      end

      def lerp(first, second, parameter)
        first.zip(second).map {|a, b| a + (b - a) * parameter }
      end

      def curve_error(controls)
        start_point = controls[0]
        end_point = controls[3]
        [controls[1], controls[2]].map do |point|
          distance_to_line(point, start_point, end_point)
        end.max
      end

      def distance_to_line(point, start_point, end_point)
        direction = end_point.zip(start_point).map {|finish, start| finish - start }
        length_squared = direction.sum {|value| value ** 2 }
        return distance(point, start_point) if length_squared.zero?
        relative = point.zip(start_point, direction).sum do |value, start, delta|
          (value - start) * delta
        end / length_squared
        projected = start_point.zip(direction).map {|start, delta| start + relative.clamp(0, 1) * delta }
        distance(point, projected)
      end

      def distance(a, b)
        Math.sqrt(a.zip(b).sum {|x, y| (x - y) ** 2 })
      end

      # Parses packed type 6 and type 7 patch mesh streams.
      class MeshParser

        COONS_COORDINATE_COUNTS = [
          [(0..3), (1..3), (1..3), (1..2)],
          [(1..3), (1..3), (1..2), (0...0)],
          [(0...0), (1..3), (1..3), (1..2)],
          [(0...0), (1..3), (0...0), (0...0)]
        ].freeze
        TENSOR_COORDINATE_COUNTS = COONS_COORDINATE_COUNTS
        COONS_COLOR_COUNTS = [
          [[0, 1, 3], [1, 3], [1, 3], [1]],
          [[0, 1, 3], [1, 3], [1], []],
          [[], [1, 3], [1, 3], [1]],
          [[0, 1, 3], [], [], []]
        ].freeze
        TENSOR_COLOR_COUNTS = [
          [[0, 1, 3], [1, 3], [1, 3], [1]],
          [[0, 1, 3], [1, 3], [1], []],
          [[], [1, 3], [1, 3], [1]],
          [[0, 1, 3], [], [], []]
        ].freeze

        def initialize(shading)
          @shading = shading
          @reader = Utils::BitStreamReader.new(shading.stream)
          @previous = nil
          @patches = []
        end

        def parse
          index = 0
          while @reader.remaining_bits >= 8
          flag = read_value(8, "patch #{index} edge flag")
          unless flag.zero? || @previous
            raise HexaPDF::Error, "Patch #{index} uses edge flag #{flag} without a previous patch"
          end
            unless [0, 1, 2, 3].include?(flag)
              raise HexaPDF::Error, "Invalid patch flag #{flag} in patch #{index}"
            end
            @patches << parse_patch(index, flag)
            index += 1
          end
          @patches
        end

        private

        def parse_patch(index, flag)
          geometry = Array.new(4) { Array.new(4) }
          colors = Array.new(4) { Array.new(4) }
          boundary = Array.new(4) { Array.new(4) }
          boundary_colors = Array.new(4) { Array.new(4) }

          parse_boundary(index, flag, boundary, boundary_colors)
          assign_boundary(geometry, boundary)
          assign_boundary(colors, boundary_colors)
          complete_grid_boundaries(geometry)
          complete_grid_boundaries(colors)
          if @shading[:ShadingType] == 6
            geometry[1][1] ||= lerp_point(geometry[1][0], geometry[1][3], 0.5)
            geometry[1][2] ||= geometry[1][1]
            geometry[2][1] ||= lerp_point(geometry[2][0], geometry[2][3], 0.5)
            geometry[2][2] ||= geometry[2][1]
            fill_coons_interior(geometry)
            colors[1][1] ||= lerp_point(colors[1][0], colors[1][3], 0.5)
            colors[1][2] ||= colors[1][1]
            colors[2][1] ||= lerp_point(colors[2][0], colors[2][3], 0.5)
            colors[2][2] ||= colors[2][1]
            fill_coons_interior(colors)
          else
            parse_tensor_interior(index, geometry)
            fill_coons_interior(colors)
          end

          patch = Patch.new(index: index, flag: flag, geometry: geometry, colors: colors)
          @previous = patch
          patch
        end

        def parse_boundary(index, flag, boundary, colors)
          type6 = @shading[:ShadingType] == 6
          coordinate_counts = type6 ? COONS_COORDINATE_COUNTS[flag] : TENSOR_COORDINATE_COUNTS[flag]
          color_counts = type6 ? COONS_COLOR_COUNTS[flag] : TENSOR_COLOR_COUNTS[flag]
          if flag == 1
            boundary[3] = reverse_edge(@previous.geometry, :right)
            colors[3] = reverse_edge(@previous.colors, :right)
          elsif flag == 2
            boundary[2] = reverse_edge(@previous.geometry, :right)
            colors[2] = reverse_edge(@previous.colors, :right)
          elsif flag == 3
            boundary[3] = reverse_edge(@previous.geometry, :right)
            boundary[2] = reverse_edge(@previous.geometry, :bottom)
            colors[3] = reverse_edge(@previous.colors, :right)
            colors[2] = reverse_edge(@previous.colors, :bottom)
          end

          coordinate_counts.each_with_index do |range, edge|
            range_entries(range).each {|point| boundary[edge][point] = read_point(index) }
          end
          color_counts.each_with_index do |range, edge|
            range_entries(range).each {|point| colors[edge][point] = read_color_values(index) }
          end
          complete_boundary_geometry(boundary)
          complete_boundary_colors(colors)
        end

        def complete_boundary_geometry(edges)
          4.times do
            edges[1][0] ||= edges[0][3]
            edges[2][0] ||= edges[1][3]
            edges[3][0] ||= edges[0][0]
            edges[0][3] ||= edges[1][0]
            edges[1][3] ||= edges[2][0]
            edges[2][3] ||= edges[3][3]
            edges[3][3] ||= edges[2][3]
          end
          [0, 1, 2].each do |edge|
            edges[edge][2] ||= edges[edge][1] if edges[edge][1]
          end
        end

        def lerp_point(first, second, parameter)
          first.zip(second).map {|a, b| a + (b - a) * parameter }
        end

        def range_entries(range)
          return range if range.is_a?(Array)
          return [] if range.begin > range.end || (range.exclude_end? && range.begin == range.end)
          range.to_a
        end

        def complete_boundary_corners(edges)
          3.times do |edge|
            edges[edge + 1][0] ||= edges[edge][3]
            edges[edge][3] ||= edges[edge + 1][0]
          end
          edges[3][0] ||= edges[2][0]
          edges[3][3] ||= edges[0][0]
        end

        def complete_boundary_colors(edges)
          4.times do
            edges[0][3] ||= edges[1][0]
            edges[1][0] ||= edges[0][3]
            edges[1][3] ||= edges[2][0]
            edges[2][0] ||= edges[1][3]
            edges[2][3] ||= edges[3][0]
            edges[3][0] ||= edges[2][3]
            edges[0][0] ||= edges[3][3]
          end
          edges[3][3] ||= edges[0][0]
          edges.each do |edge|
            next unless edge[0] && edge[3]
            edge[1] ||= edge[2] || lerp_point(edge[0], edge[3], 0.5)
            edge[2] ||= edge[1]
          end
        end

        def assign_boundary(grid, edges)
          grid[3] = edges[0]
          grid[1][3] = edges[1][1]
          grid[2][3] = edges[1][2]
          grid[0][3] = edges[1][3]
          grid[0][2] = edges[2][1]
          grid[0][1] = edges[2][2]
          grid[0][0] = edges[2][3]
          grid[1][0] = edges[3][1]
          grid[2][0] = edges[3][2]
          grid[3][0] = edges[3][3]
        end

        def complete_grid_boundaries(grid)
          grid[3][3] ||= grid[3][0] || grid[0][3]
          grid[0][3] ||= grid[3][3] || grid[0][0]
          grid[3][0] ||= grid[3][3] || grid[0][0]
          grid[0][0] ||= grid[3][0] || grid[0][3]
          [0, 3].each do |row|
            next unless grid[row][0] && grid[row][3]
            grid[row][1] ||= lerp_point(grid[row][0], grid[row][3], 1.0 / 3.0)
            grid[row][2] ||= lerp_point(grid[row][0], grid[row][3], 2.0 / 3.0)
          end
          [0, 3].each do |column|
            next unless grid[0][column] && grid[3][column]
            grid[1][column] ||= lerp_point(grid[0][column], grid[3][column], 2.0 / 3.0)
            grid[2][column] ||= lerp_point(grid[0][column], grid[3][column], 1.0 / 3.0)
          end
          [1, 2].each do |row|
            next unless grid[row][0] && grid[row][3]
            grid[row][1] ||= lerp_point(grid[row][0], grid[row][3], 0.5)
            grid[row][2] ||= grid[row][1]
          end
        end

        def reverse_edge(grid, edge)
          case edge
          when :right then [grid[3][3], grid[2][3], grid[1][3], grid[0][3]]
          when :top then [grid[0][3], grid[0][2], grid[0][1], grid[0][0]]
          when :bottom then [grid[3][3], grid[3][2], grid[3][1], grid[3][0]]
          else raise HexaPDF::Error, "Unsupported shared edge #{edge}"
          end
        end

        def parse_tensor_interior(index, geometry)
          [[2, 1], [2, 2], [1, 1], [1, 2]].each do |row, column|
            geometry[row][column] = read_point(index)
          end
        end

        def fill_coons_interior(grid)
          2.times do |row|
            bottom_weight = row.zero? ? Rational(2, 3) : Rational(1, 3)
            top_weight = 1 - bottom_weight
            2.times do |column|
              i = row + 1
              j = column + 1
              left_weight = column.zero? ? Rational(2, 3) : Rational(1, 3)
              right_weight = 1 - left_weight
              weights = [bottom_weight, top_weight, left_weight, right_weight,
                         -bottom_weight * left_weight, -bottom_weight * right_weight,
                         -top_weight * left_weight, -top_weight * right_weight]
              grid[i][j] = weighted_components(weights, grid[3][j], grid[0][j], grid[i][0],
                                              grid[i][3], grid[3][0], grid[3][3],
                                              grid[0][0], grid[0][3])
            end
          end
        end

        def weighted_components(weights, *values)
          first = values.first
          if first.kind_of?(Array)
            first.length.times.map do |component|
              values.each_with_index.sum do |value, index|
                weights[index] * value[component]
              end
            end.map(&:to_f)
          else
            values.each_with_index.sum {|value, index| weights[index] * value }.to_f
          end
        end

        def read_point(index)
          x = read_decoded(@shading.send(:bits_coordinate), @shading.send(:coordinate_decode), 0,
                           index, 'coordinate X')
          y = read_decoded(@shading.send(:bits_coordinate), @shading.send(:coordinate_decode), 2,
                           index, 'coordinate Y')
          [x, y]
        end

        def read_color_values(index)
          count = @shading.send(:value_component_count)
          Array.new(count) do |component|
            read_decoded(@shading.send(:bits_color), @shading.send(:value_decode),
                         component * 2, index, "color component #{component}")
          end
        end

        def read_decoded(bits, decode, pair_index, patch_index, description)
          raw = read_value(bits, "patch #{patch_index} #{description}")
          lower, upper = decode[pair_index], decode[pair_index + 1]
          lower + raw.to_f / (2 ** bits - 1) * (upper - lower)
        end

        def read_value(bits, what)
          unless @reader.read?(bits)
            raise HexaPDF::Error, "Truncated shading data: missing #{what}"
          end
          @reader.read(bits)
        end

      end

    end
  end
end
