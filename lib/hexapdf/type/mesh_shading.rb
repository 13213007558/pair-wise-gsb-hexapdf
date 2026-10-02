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

require 'hexapdf/stream'
require 'hexapdf/utils/bit_stream'
require 'hexapdf/content/transformation_matrix'

module HexaPDF
  module Type
    class MeshShading < Stream
      require 'hexapdf/type/mesh_shading/tessellator'

      Patch = Struct.new(:type, :flag, :points, :colors, :edges, :index, keyword_init: true)
      Triangle = Struct.new(:points, :colors, keyword_init: true) do
        def [](index)
          [points[index], colors[index]]
        end
      end

      define_field :ShadingType, type: Integer, required: true, allowed_values: [6, 7]
      define_field :ColorSpace, type: [Symbol, PDFArray], required: true
      define_field :BitsPerCoordinate, type: Integer, required: true
      define_field :BitsPerComponent, type: Integer, required: true
      define_field :BitsPerFlag, type: Integer, default: 2
      define_field :Decode, type: PDFArray, required: true
      define_field :Matrix, type: PDFArray, default: [1, 0, 0, 1, 0, 0]

      def patches(data = nil)
        return parse(data) if data
        @patches ||= parse(HexaPDF::Filter.string_from_source(stream_decoder))
      end

      def triangles(tolerance:, color_tolerance: tolerance, matrix: nil, data: nil)
        Tessellator.new(self).triangles(patches(data), tolerance: tolerance,
                                        color_tolerance: color_tolerance, matrix: matrix)
      end

      private

      def parse(data)
        data = (data || ''.b).to_s.b
        type = required_integer(:ShadingType, [6, 7])
        coordinate_bits = required_integer(:BitsPerCoordinate, [1, 2, 3, 4, 8, 12, 16, 24, 32])
        component_bits = required_integer(:BitsPerComponent, [1, 2, 4, 8, 12, 16])
        flag_bits = required_integer(:BitsPerFlag, [1, 2, 4, 8])
        components = color_components
        decode = Array(self[:Decode]).map(&:to_f)
        if decode.length != 4 + components * 2
          raise HexaPDF::Error, "Invalid Decode array length #{decode.length}"
        end

        reader = Utils::BitStreamReader.new(data)
        patches = []
        total_bits = data.bytesize * 8
        consumed_bits = 0
        while total_bits - consumed_bits >= 8 || (consumed_bits.zero? && total_bits >= flag_bits)
          flag = read_bits(reader, flag_bits, 'patch flag')
          consumed_bits += flag_bits
          if flag > (type == 6 ? 2 : 3) || (!flag.zero? && patches.empty?)
            raise HexaPDF::MalformedPDFError, "Invalid mesh patch flag #{flag}"
          end
          points_in_patch = point_count(type, flag)
          colors_in_patch = color_count(type, flag)
          patch_bits = points_in_patch * coordinate_bits * 2 +
                       colors_in_patch * components * component_bits
          if consumed_bits + patch_bits > total_bits
            raise HexaPDF::MalformedPDFError, 'Truncated mesh stream while reading patch data'
          end
          points = Array.new(points_in_patch) { read_point(reader, coordinate_bits, decode) }
          colors = Array.new(colors_in_patch) do
            read_color(reader, component_bits, components, decode)
          end
          consumed_bits += patch_bits
          patches << build_patch(type, flag, points, colors, patches.last, patches.length)
        end
        patches
      end

      def required_integer(name, allowed_values)
        value = self[name]
        unless value.kind_of?(Integer) && allowed_values.include?(value)
          raise HexaPDF::Error, "Invalid #{name} value #{value.inspect}"
        end
        value
      end

      def color_components
        space = self[:ColorSpace]
        if space.kind_of?(Array)
          case space[0]
          when :Indexed then return 1
          when :ICCBased then return Integer(space[1][:N])
          when :Separation, :DeviceN then return space.length - 2
          else space = space[0]
          end
        end
        case space
        when :DeviceGray, :CalGray, :Indexed then 1
        when :DeviceRGB, :CalRGB, :Lab then 3
        when :DeviceCMYK then 4
        else raise HexaPDF::Error, "Unsupported mesh shading color space #{space.inspect}"
        end
      end

      def point_count(type, flag)
        counts = type == 6 ? [12, 8, 4] : [16, 12, 8, 4]
        counts.fetch(flag)
      end

      def color_count(type, flag)
        counts = type == 6 ? [4, 2, 0] : [4, 2, 1, 0]
        counts.fetch(flag)
      end

      def read_bits(reader, bits, description)
        value = reader.read(bits)
        return value unless value.nil?
        raise HexaPDF::MalformedPDFError, "Truncated mesh stream while reading #{description}"
      end

      def scale_value(raw, bits, low, high)
        low + raw * (high - low) / ((1 << bits) - 1).to_f
      end

      def read_point(reader, bits, decode)
        x = scale_value(read_bits(reader, bits, 'x coordinate'), bits, decode[0], decode[1])
        y = scale_value(read_bits(reader, bits, 'y coordinate'), bits, decode[2], decode[3])
        [x, y]
      end

      def read_color(reader, bits, components, decode)
        Array.new(components) do |index|
          raw = read_bits(reader, bits, 'color component')
          offset = 4 + index * 2
          scale_value(raw, bits, decode[offset], decode[offset + 1])
        end
      end

      def build_patch(type, flag, stream_points, stream_colors, previous, index)
        if type == 6
          build_coons_patch(flag, stream_points, stream_colors, previous, index)
        else
          build_tensor_patch(flag, stream_points, stream_colors, previous, index)
        end
      end

      def build_coons_patch(flag, points, colors, previous, index)
        boundary = Array.new(12)
        corners = Array.new(4)
        case flag
        when 0
          boundary.replace(points)
          corners.replace(colors)
        when 1
          boundary[0..3] = [previous.points[9], previous.points[10],
                            previous.points[11], previous.points[0]]
          fill(boundary, [4, 5, 6, 7, 8, 9, 10, 11], points)
          corners[0] = previous.colors[0]
          corners[1] = previous.colors[3]
          corners[2], corners[3] = colors
        when 2
          boundary[0..3] = [previous.points[9], previous.points[10],
                            previous.points[11], previous.points[0]]
          boundary[6..9] = previous.points[6..9]
          fill(boundary, [4, 5, 10, 11], points)
          corners[0] = previous.colors[0]
          corners[3] = previous.colors[3]
          corners[1] = previous.colors[2]
          corners[2] = previous.colors[1]
        end
        Patch.new(type: 6, flag: flag, points: boundary, colors: corners,
                  edges: coons_edges(boundary), index: index)
      end

      def coons_edges(points)
        [points.values_at(0, 1, 2, 3), points.values_at(3, 4, 5, 6),
         points.values_at(6, 7, 8, 9), points.values_at(9, 10, 11, 0)]
      end

      def build_tensor_patch(flag, points, colors, previous, index)
        grid = Array.new(16)
        corners = Array.new(4)
        case flag
        when 0
          grid.replace(points)
          corners.replace(colors)
        when 1
          grid[0..3] = [previous.points[0], previous.points[4], previous.points[8],
                        previous.points[12]]
          fill(grid, [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], points)
          corners[0] = previous.colors[0]
          corners[1] = previous.colors[3]
          corners[2], corners[3] = colors
        when 2
          grid[0..3] = [previous.points[0], previous.points[4], previous.points[8],
                        previous.points[12]]
          grid[12..15] = [previous.points[3], previous.points[7], previous.points[11],
                          previous.points[15]]
          fill(grid, (4..11).to_a, points)
          corners[0] = previous.colors[0]
          corners[1] = previous.colors[3]
          corners[3] = previous.colors[2]
          corners[2] = colors[0]
        when 3
          grid[12..15] = previous.points[0..3]
          fill(grid, [4, 5, 9, 10], points)
          corners.replace(previous.colors)
        end
        Patch.new(type: 7, flag: flag, points: grid, colors: corners,
                  edges: tensor_edges(grid), index: index)
      end

      def tensor_edges(grid)
        [grid.values_at(0, 1, 2, 3), grid.values_at(3, 7, 11, 15),
         grid.values_at(15, 14, 13, 12), grid.values_at(12, 8, 4, 0)]
      end

      def fill(target, positions, values)
        positions.each_with_index {|position, index| target[position] = values[index] }
      end
    end
  end
end
