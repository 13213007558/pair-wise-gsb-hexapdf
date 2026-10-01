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

module HexaPDF

  # This module provides functionality for geospatially referenced PDFs.
  #
  # A geospatially referenced PDF contains one or more viewport dictionaries (see
  # HexaPDF::Type::Viewport), each associated with a GEO measure dictionary (see
  # HexaPDF::Type::Measure). Such a measure dictionary relates control points given in local
  # page coordinates (/LPTS) to coordinates in a geographic or projected coordinate system
  # (/GPTS).
  #
  # The relation used here is a two-dimensional affine transformation which is fitted from the
  # control points:
  #
  #   x_geo = a * x_local + c * y_local + e
  #   y_geo = b * x_local + d * y_local + f
  #
  # * Two control points determine a similarity transformation (rotation, uniform scaling and
  #   translation).
  # * Three non-collinear control points determine a general affine transformation exactly.
  # * More than three control points are fitted using least squares and the residuals are
  #   reported.
  #
  # Coordinate systems are never guessed: the values from /GPTS are mapped as documented and the
  # information from /GeoCS is exposed as-is. For geographic coordinate systems the PDF stores
  # the coordinates in latitude/longitude order whereas the public interface uses the usual
  # longitude/latitude order.
  module Geospatial

    autoload(:AffineLocator, 'hexapdf/geospatial/affine_locator')

    # Precision below which two values are considered equal when checking collinearity,
    # invertibility and boundary containment.
    EPSILON = 1e-10

    # The possible statuses of an AffineLocator or a coordinate query.
    #
    # :ok::                   The locator is ready (or the query succeeded).
    # :invalid_viewport::     The viewport/measure dictionary is not usable for geolocation.
    # :insufficient_points:: Fewer than two control point pairs are available.
    # :collinear_points::     The control points are collinear (or coincide), so a general
    #                         affine transformation cannot be determined.
    # :non_invertible::      The fitted mapping is degenerate and cannot be inverted for
    #                         reverse queries.
    # :out_of_bounds::       The queried point lies outside the valid region (/Bounds polygon or
    #                         viewport /BBox).
    STATUSES = [:ok, :invalid_viewport, :insufficient_points, :collinear_points,
                :non_invertible, :out_of_bounds].freeze

    # Result of a coordinate query.
    #
    # +status+ is one of the symbols in STATUSES. +point+ is the converted coordinate pair (in
    # longitude/latitude order for geographic coordinate systems) or +nil+ if the query did not
    # succeed. +inside+ indicates whether the queried point lies within the valid region.
    Result = Struct.new(:status, :point, :inside) do
      # Returns +true+ if the query succeeded.
      def success?
        status == :ok
      end
    end

    # :call-seq:
    #    Geospatial.affine_locator(viewport_or_measure, origin: nil, user_unit: 1) -> locator
    #
    # Creates an AffineLocator for the given viewport dictionary (HexaPDF::Type::Viewport) or GEO
    # measure dictionary (HexaPDF::Type::Measure with subtype /GEO).
    #
    # When a viewport is given, +origin+ defaults to the lower-left corner of its /BBox and the
    # /PDU scaling is taken from the measure dictionary. When a bare measure dictionary is given,
    # +origin+ defaults to [0, 0] and may be set to the lower-left corner of the associated
    # viewport's /BBox.
    def self.affine_locator(object, origin: nil, user_unit: 1)
      AffineLocator.new(object, origin: origin, user_unit: user_unit)
    end

    # Converts a point given in the displayed coordinate system (origin at the upper-left corner
    # of the page, x to the right and y downward) to unrotated page user space coordinates for
    # the given rotation in degrees (0, 90, 180 or 270, clockwise as per /Rotate) and box
    # [left, bottom, right, top].
    def self.display_to_page_point(x, y, rotation, box)
      left, bottom, right, top = box
      case rotation % 360
      when 0   then [left + x, top - y]
      when 90  then [right - y, bottom + x]
      when 180 then [right - x, bottom + y]
      when 270 then [left + y, top - x]
      else
        raise ArgumentError, "Page rotation has to be a multiple of 90 degrees"
      end
    end

    # Converts a point in unrotated page user space to the displayed coordinate system (origin at
    # the upper-left corner, x to the right and y downward).
    #
    # See ::display_to_page_point for the arguments.
    def self.page_to_display_point(x, y, rotation, box)
      left, bottom, right, top = box
      case rotation % 360
      when 0   then [x - left, top - y]
      when 90  then [y - bottom, right - x]
      when 180 then [right - x, y - bottom]
      when 270 then [top - y, x - left]
      else
        raise ArgumentError, "Page rotation has to be a multiple of 90 degrees"
      end
    end

    # :nodoc: internal helper
    #
    # Solves the linear equation system +matrix+ * x = +rhs+ using Gaussian elimination with
    # partial pivoting. +matrix+ is a row-major n*n array, +rhs+ an array of length n. Returns the
    # solution array or +nil+ if the matrix is singular (relative pivot magnitude below
    # threshold).
    def self.solve_linear_system(matrix, rhs)
      n = rhs.length
      m = Array.new(n) {|i| matrix[(i * n)...((i + 1) * n)].dup }
      b = rhs.dup
      scale = m.flatten.map(&:abs).max.to_f
      return nil if scale.zero?

      (0...n).each do |col|
        pivot = (col...n).max_by {|row| m[row][col].abs }
        if m[pivot][col].abs <= EPSILON * scale
          return nil
        end
        if pivot != col
          m[col], m[pivot] = m[pivot], m[col]
          b[col], b[pivot] = b[pivot], b[col]
        end

        ((col + 1)...n).each do |row|
          factor = m[row][col].to_f / m[col][col]
          next if factor.zero?
          m[row][col] = 0.0
          ((col + 1)...n).each {|j| m[row][j] -= factor * m[col][j] }
          b[row] -= factor * b[col]
        end
      end

      x = Array.new(n)
      (n - 1).downto(0) do |row|
        sum = ((row + 1)...n).sum {|j| m[row][j] * x[j] }
        x[row] = (b[row] - sum).to_f / m[row][row]
      end
      x
    end

    # :nodoc: internal helper
    #
    # Returns +true+ if the point +p+ lies inside (or on the boundary of) the polygon given as an
    # array of [x, y] vertices.
    def self.point_in_polygon?(point, polygon)
      px, py = point
      inside = false
      n = polygon.length
      scale = polygon.flat_map {|x, y| [x.abs, y.abs] }.max.to_f
      tolerance = EPSILON * [1.0, scale].max
      n.times do |i|
        x1, y1 = polygon[i]
        x2, y2 = polygon[(i + 1) % n]
        cross = (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)
        on_edge = cross.abs <= tolerance * [Math.hypot(x2 - x1, y2 - y1), 1.0].max &&
          px >= [x1, x2].min - tolerance && px <= [x1, x2].max + tolerance &&
          py >= [y1, y2].min - tolerance && py <= [y1, y2].max + tolerance
        return true if on_edge
        if ((y1 > py) != (y2 > py)) &&
            (px < (x2 - x1) * (py - y1).to_f / (y2 - y1) + x1)
          inside = !inside
        end
      end
      inside
    end

  end
end
