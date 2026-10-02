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

require 'hexapdf/error'
require 'hexapdf/stream'
require 'hexapdf/utils/bit_stream'

module HexaPDF
  module Type

    # Represents a shading dictionary or stream.
    #
    # For shading types 6 (Coons patch meshes) and 7 (tensor-product patch meshes) this class
    # provides access to the geometric data encoded in the (possibly compressed) bit stream of
    # the shading:
    #
    # * The #patches method parses the bit stream and returns the individual patches with their
    #   edge (reuse) flags, control points and colors. The values are decoded using the /Decode
    #   array; the number of color components is derived from its length.
    #
    # * The #triangles method tessellates the patch mesh into triangles so that the geometric
    #   and color approximation errors stay within a given tolerance. Adjacent patches sharing
    #   an edge use identical split points along that edge (the split points only depend on the
    #   shared edge curve itself), so no seams appear between neighboring patches. An optional
    #   transformation matrix can be applied to the control points before tessellation, in
    #   which case the tolerance is measured in the transformed coordinate system.
    #
    # Degenerate patches (all control points coincident) are silently skipped during
    # tessellation. A truncated or otherwise invalid bit stream raises a
    # HexaPDF::MalformedPDFError instead.
    #
    # See: PDF2.0 s8.7.4.1, s8.7.4.5.6, s8.7.4.5.7
    class Shading < Stream

      # A single patch of a patch mesh shading.
      #
      # flag::   The edge flag (0-3) indicating whether the patch shares an edge with the
      #          preceding patch.
      # points:: The control points of the patch as [x, y] pairs (12 for Coons patch meshes,
      #          16 for tensor-product patch meshes), decoded using the /Decode array.
      # colors:: The colors of the four patch corners, each an array of color components,
      #          decoded using the /Decode array.
      Patch = Struct.new(:flag, :points, :colors)

      # A single triangle of a tessellated patch mesh shading.
      #
      # points:: The three corner points of the triangle as [x, y] pairs.
      # colors:: The colors of the three corners, each an array of color components.
      Triangle = Struct.new(:points, :colors)

      define_field :ShadingType, type: Integer, required: true,
                   allowed_values: [1, 2, 3, 4, 5, 6, 7]
      define_field :ColorSpace, type: [Symbol, PDFArray], required: true
      define_field :Background, type: PDFArray
      define_field :BBox, type: :Rectangle
      define_field :AntiAlias, type: Boolean, default: false
      define_field :BitsPerCoordinate, type: Integer
      define_field :BitsPerComponent, type: Integer
      define_field :BitsPerFlag, type: Integer
      define_field :Decode, type: PDFArray
      define_field :Function, type: [Stream, Dictionary, PDFArray]

      # Parses the bit stream of the shading and returns the encoded patches as an array of
      # Patch objects.
      #
      # Only patch mesh shadings (shading type 6 or 7) contain patches; for all other shading
      # types a HexaPDF::Error is raised. A truncated or invalid bit stream raises a
      # HexaPDF::MalformedPDFError.
      def patches
        parse_patch_mesh
      end

      # Tessellates the patch mesh of the shading into triangles within the given error
      # +tolerance+ and returns an array of Triangle objects.
      #
      # The tolerance specifies the maximum allowed distance between the exact patch surface
      # (respectively the exact color gradient) and its triangle approximation. It is measured
      # in the coordinate system defined by +transformation_matrix+ (a
      # HexaPDF::Content::TransformationMatrix) or, if none is given, in the coordinate system
      # of the shading itself. A smaller tolerance leads to more triangles and a better
      # approximation; tightening the tolerance never reduces the achieved precision.
      #
      # Degenerate patches (all control points coincident) are skipped and contribute no
      # triangles. A truncated or invalid bit stream raises a HexaPDF::MalformedPDFError.
      def triangles(tolerance: 1.0, transformation_matrix: nil)
        unless tolerance.positive?
          raise ArgumentError, "tolerance must be a positive number"
        end

        tessellator = Tessellator.new(tolerance, transformation_matrix)
        type = self[:ShadingType]
        parse_patch_mesh.flat_map do |patch|
          tessellator.tessellate(patch, type)
        end
      end

      private

      # Maps the edge flag to the indices of the four reused control points of the previous
      # patch, for Coons patch meshes (type 6) and tensor-product patch meshes (type 7).
      REUSED_POINTS = {
        6 => {1 => [3, 4, 5, 6], 2 => [6, 7, 8, 9], 3 => [9, 10, 11, 0]},
        7 => {1 => [12, 13, 14, 15], 2 => [15, 11, 7, 3], 3 => [3, 2, 1, 0]},
      }.freeze

      # Maps the edge flag to the indices of the two reused corner colors of the previous
      # patch (the same for shading types 6 and 7).
      REUSED_COLORS = {1 => [1, 2], 2 => [2, 3], 3 => [3, 0]}.freeze

      # The number of control points of a single patch, per shading type.
      POINT_COUNT = {6 => 12, 7 => 16}.freeze

      # Parses the patch mesh bit stream and returns the array of Patch objects.
      def parse_patch_mesh
        type = self[:ShadingType]
        unless type == 6 || type == 7
          raise HexaPDF::Error, "Shading type #{type} does not describe a patch mesh"
        end

        bits_flag = self[:BitsPerFlag]
        bits_coord = self[:BitsPerCoordinate]
        bits_comp = self[:BitsPerComponent]
        decode = self[:Decode] && document.unwrap(self[:Decode])
        unless bits_flag && bits_coord && bits_comp &&
            decode.kind_of?(Array) && decode.length >= 6 && decode.length.even?
          raise HexaPDF::MalformedPDFError, "Invalid patch mesh shading dictionary"
        end
        components = (decode.length - 4) / 2

        reader = HexaPDF::Utils::BitStreamReader.new(stream)
        read_point = lambda do
          x = reader.read(bits_coord)
          y = x && reader.read(bits_coord)
          unless y
            raise HexaPDF::MalformedPDFError, "Truncated patch mesh shading stream"
          end
          [decode[0] + x * (decode[1] - decode[0]) / ((1 << bits_coord) - 1).to_f,
           decode[2] + y * (decode[3] - decode[2]) / ((1 << bits_coord) - 1).to_f]
        end
        read_color = lambda do
          Array.new(components) do |index|
            value = reader.read(bits_comp)
            unless value
              raise HexaPDF::MalformedPDFError, "Truncated patch mesh shading stream"
            end
            min = decode[4 + 2 * index]
            max = decode[5 + 2 * index]
            min + value * (max - min) / ((1 << bits_comp) - 1).to_f
          end
        end

        point_count = POINT_COUNT[type]
        reused_points = REUSED_POINTS[type]
        patches = []
        # A valid stream ends with less than one byte of padding, so anything less can be
        # ignored; everything else is either a complete patch or a truncated stream.
        while reader.remaining_bits >= 8
          flag = reader.read(bits_flag)
          break unless flag
          if flag > 3
            raise HexaPDF::MalformedPDFError, "Invalid edge flag in patch mesh shading stream"
          end

          if flag == 0
            points = Array.new(point_count) { read_point.call }
            colors = Array.new(4) { read_color.call }
          else
            previous = patches.last
            unless previous
              raise HexaPDF::MalformedPDFError,
                    "Edge flag in first patch of patch mesh shading stream"
            end
            points = reused_points[flag].map {|index| previous.points[index] }
            (point_count - 4).times { points << read_point.call }
            colors = REUSED_COLORS[flag].map {|index| previous.colors[index] }
            2.times { colors << read_color.call }
          end
          patches << Patch.new(flag, points, colors)
        end
        patches
      end

    end

  end
end

require 'hexapdf/type/shading/tessellator'
