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
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
# for more details.
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
# commercial licenses are available at <https://gettalong.at/>.
#++

require 'hexapdf/error'
require 'hexapdf/utils/math_helpers'

module HexaPDF
  module Geo

    # A locator reads the GEO measure information of a viewport and converts page points to the
    # geographic coordinates recorded in the document and vice versa.
    #
    # Only two-dimensional affine mappings within a single viewport are supported. The linear
    # (/LPTS) and geographic (/GPTS) point pairs of the GEO measure dictionary are used as
    # control points:
    #
    # * Two pairs define a similarity transformation (rotation, uniform scaling and
    #   translation).
    # * Three pairs define a general affine transformation.
    # * More than three pairs are least-squares fitted; the residuals are available through
    #   #residuals, #rmse and #max_residual.
    #
    # The geographic coordinate systems are identified by the /GCS and /DCS entries but are not
    # interpreted in any way: coordinates are always returned as recorded in the document and no
    # coordinate reference system guessing or datum conversion is performed. In particular,
    # longitude/latitude values are not assumed to be projected Cartesian coordinates.
    #
    # Page handling:
    #
    # * The page's /Rotate entry is respected. By default, page points are interpreted in the
    #   rotated (displayed) coordinate space with the origin at the bottom-left corner of the
    #   displayed page; set +display: false+ to work directly in the default, unrotated user
    #   space in which the viewport is defined.
    # * The page's /UserUnit entry is respected. By default, page points are specified in points
    #   (1/72 inch); set +units: :pdf+ to work in the page's PDF user space units
    #   (1 unit = /UserUnit * 1/72 inch).
    #
    # The state of the locator is available through #status and #valid?:
    #
    # :ok::                The mapping was successfully computed.
    # :no_measure::        The viewport has no GEO measure dictionary.
    # :missing_points::    /LPTS or /GPTS is missing, empty or has an odd number of values.
    # :mismatched_points:: /LPTS and /GPTS contain a different number of point pairs.
    # :collinear_points::  The linear control points are collinear (or coincident), so no
    #                      two-dimensional affine mapping can be determined.
    # :singular_mapping::  The resulting mapping is not invertible.
    # :invalid_bounds::    The viewport's /BBox or the measure's /Bounds polygon is malformed.
    #
    # See: HexaPDF::Type::Viewport, HexaPDF::Type::Measure::Geo, PDF2.0 s12.9.3
    class Locator

      include HexaPDF::Utils::MathHelpers

      # Represents a result of a forward or inverse point transformation.
      #
      # +status+ is either :ok (the point lies within the valid boundary) or :outside_bounds
      # (the point was still transformed, but lies outside the boundary polygon).
      #
      # +page_point+ is always given in points in the requested page coordinate space, +geo_point+
      # in the coordinates recorded in the document.
      class Result

        # The transformation status (:ok or :outside_bounds).
        attr_reader :status

        # The page point [x, y] in the requested coordinate space and units.
        attr_reader :page_point

        # The geographic point [x, y] in document-recorded coordinates.
        attr_reader :geo_point

        def initialize(status, page_point, geo_point) #:notnew:
          @status = status
          @page_point = page_point
          @geo_point = geo_point
        end

        # Returns whether the queried point lies within the viewport's valid boundary.
        def inside?
          @status == :ok
        end

      end

      # The status of the locator (see the class documentation for possible values).
      attr_reader :status

      # The viewport dictionary this locator was created from.
      attr_reader :viewport

      # The page the viewport belongs to, or +nil+ if none was provided.
      attr_reader :page

      # The GEO measure dictionary used by the locator, or +nil+ if it is missing.
      attr_reader :measure

      # The control points as an Array of [linear_point, geographic_point] pairs, where each
      # point is an [x, y] pair in default user space units (linear) and document coordinates
      # (geographic).
      attr_reader :control_points

      # The per-control-point residual vectors, i.e. an Array of [dx, dy] pairs in geographic
      # coordinate units. These are all zero for exact (two- and three-point) fits.
      attr_reader :residuals

      # The root mean squared residual magnitude in geographic coordinate units.
      attr_reader :rmse

      # The maximum per-control-point residual magnitude in geographic coordinate units.
      attr_reader :max_residual

      # The valid boundary polygon as an Array of [x, y] points in the page's default user
      # space units (i.e. multiplied by /UserUnit gives points).
      attr_reader :bounds

      # The geographic coordinate system the returned coordinates are expressed in, i.e. the
      # display coordinate system /DCS if present, otherwise the geographic coordinate system
      # /GCS. The value is the raw PDF value (a Symbol or String).
      attr_reader :coordinate_system

      # The base geographic coordinate system (/GCS) as recorded in the document.
      attr_reader :geographic_coordinate_system

      # The /UserUnit value of the page, or 1.0 if there is no page.
      attr_reader :user_unit

      # The clockwise page rotation in degrees (a multiple of 90).
      attr_reader :rotation

      # :call-seq:
      #   Locator.new(viewport, page: nil, display: true, units: :point,
      #              epsilon: 1e-9) -> locator
      #
      # Creates a new locator for the given viewport dictionary.
      #
      # See the class documentation for the meaning of +display+, +units+ and the possible
      # status values. +epsilon+ is the relative threshold used for collinearity and
      # invertibility checks.
      def initialize(viewport, page: nil, display: true, units: :point, epsilon: 1e-9)
        @viewport = viewport
        @page = page
        @display = display
        @units = units
        @epsilon = epsilon
        @control_points = []
        @residuals = []
        @rmse = 0.0
        @max_residual = 0.0
        @forward = @inverse = nil
        @user_unit = page&.key?(:UserUnit) ? page[:UserUnit].to_f : 1.0
        @rotation = page ? (page[:Rotate] || 0) % 360 : 0

        @measure = viewport&.[](:Measure)
        @status = compute
      end

      # Returns +true+ if the locator is ready to transform points, i.e. if #status is :ok.
      def valid?
        @status == :ok
      end

      # Returns an array [a, b, c, d, e, f] representing the fitted affine transformation from
      # default-user-space points to geographic coordinates, or +nil+ if the locator is invalid.
      def affine_matrix
        @forward&.dup
      end

      # Converts a page point [x, y] to geographic coordinates and returns a Result.
      #
      # Raises an error if the locator is not valid; check #status or #valid? beforehand.
      def forward(x, y, display: @display, units: @units)
        check_valid!
        page_point, native_point = page_to_native(x, y, display, units)
        geo_point = apply_matrix(@forward, native_point)
        inside = point_in_polygon?(native_point, @bounds)
        Result.new(inside ? :ok : :outside_bounds, page_point, geo_point)
      end

      # Converts geographic coordinates [x, y] to a page point and returns a Result.
      #
      # The result's status reflects whether the computed page point lies within the viewport's
      # valid boundary. Raises an error if the locator is not valid.
      def inverse(x, y, display: @display, units: @units)
        check_valid!
        native_point = apply_matrix(@inverse, [x, y])
        inside = point_in_polygon?(native_point, @bounds)
        page_point = native_to_page(native_point, display, units)
        Result.new(inside ? :ok : :outside_bounds, page_point, [x, y])
      end

      private

      def check_valid!
        return if @status == :ok
        raise HexaPDF::Error, "GEO viewport mapping is not usable (status: #{@status})"
      end

      def compute
        return :no_measure unless @viewport && @measure && @measure[:Subtype] == :GEO

        status = setup_bounds
        return status unless status == :ok

        lpts = numeric_pairs(@measure[:LPTS])
        gpts = numeric_pairs(@measure[:GPTS])
        return :missing_points if lpts.nil? || gpts.nil? || lpts.length < 2
        return :mismatched_points if lpts.length != gpts.length

        @control_points = lpts.zip(gpts)

        return fit_similarity(lpts, gpts) if lpts.length == 2
        fit_affine(lpts, gpts)
      end

      def numeric_pairs(value)
        return nil unless value.respond_to?(:length) && value.length >= 4 &&
          value.length <= 20 && value.length.even?
        values = value.map {|item| item }
        return nil unless values.all?(Numeric)
        values.each_slice(2).to_a
      end

      def polygon_pairs(value)
        return nil unless value.respond_to?(:length) && value.length >= 6 &&
          value.length.even?
        values = value.map {|item| item }
        return nil unless values.all?(Numeric)
        values.each_slice(2).to_a
      end

      def invalid_bbox?(bbox)
        !bbox.respond_to?(:length) || bbox.length != 4 ||
          4.times.any? {|index| !bbox[index].kind_of?(Numeric) }
      end

      def setup_bounds
        bbox = @viewport[:BBox]
        if invalid_bbox?(bbox) && @measure.key?(:BBox)
          bbox = @measure[:BBox]
        end
        if invalid_bbox?(bbox)
          return :invalid_bounds
        end

        if @measure.key?(:Bounds)
          bounds = polygon_pairs(@measure[:Bounds])
          return :invalid_bounds if bounds.nil?
          @bounds = bounds
        else
          left, bottom, right, top = 4.times.map {|index| bbox[index].to_f }
          @bounds = [[left, bottom], [right, bottom], [right, top], [left, top]]
        end
        @geographic_coordinate_system = @measure[:GCS] || :GCS_WGS84
        @coordinate_system = @measure[:DCS] || @geographic_coordinate_system
        :ok
      end

      # Fits a similarity transformation (rotation, uniform scaling, translation) from the two
      # control points.
      def fit_similarity(lpts, gpts)
        l1x, l1y = lpts[0]
        l2x, l2y = lpts[1]
        g1x, g1y = gpts[0]
        g2x, g2y = gpts[1]
        ux = l2x - l1x
        uy = l2y - l1y
        vx = g2x - g1x
        vy = g2y - g1y
        u2 = ux * ux + uy * uy
        linear_scale = Math.sqrt([l1x.abs, l1y.abs, l2x.abs, l2y.abs, 1.0].max)
        return :collinear_points if u2 <= (@epsilon * linear_scale)**2

        s = (vx * ux + vy * uy) / u2
        r = (vy * ux - vx * uy) / u2
        geo_scale = [g1x.abs, g1y.abs, g2x.abs, g2y.abs, 1.0].max
        return :singular_mapping if s * s + r * r <= (@epsilon * geo_scale / linear_scale)**2

        e = g1x - (s * l1x + r * l1y)
        f = g1y - (-r * l1x + s * l1y)
        @forward = [s, r, -r, s, e, f]
        setup_inverse
        setup_residuals(gpts)
        :ok
      end

      # Least-squares fits a general affine transformation from three or more control points.
      def fit_affine(lpts, gpts)
        return :collinear_points unless non_collinear?(lpts)

        sum_x = sum_y = sum_xx = sum_xy = sum_yy = 0.0
        sum_gx = sum_gy = sum_xgx = sum_ygx = sum_xgy = sum_ygy = 0.0
        lpts.each_with_index do |(x, y), i|
          gx, gy = gpts[i]
          sum_x += x; sum_y += y
          sum_xx += x * x; sum_xy += x * y; sum_yy += y * y
          sum_gx += gx; sum_gy += gy
          sum_xgx += x * gx; sum_ygx += y * gx
          sum_xgy += x * gy; sum_ygy += y * gy
        end
        n = lpts.length
        matrix = [[sum_xx, sum_xy, sum_x], [sum_xy, sum_yy, sum_y], [sum_x, sum_y, n.to_f]]
        x_solution = solve_linear_system3(matrix, [sum_xgx, sum_ygx, sum_gx], @epsilon)
        y_solution = solve_linear_system3(matrix, [sum_xgy, sum_ygy, sum_gy], @epsilon)
        return :singular_mapping if x_solution.nil? || y_solution.nil?

        a, c, e = x_solution
        b, d, f = y_solution
        determinant = a * d - b * c
        scale2 = a * a + b * b + c * c + d * d
        if scale2.zero? || determinant.abs <= @epsilon * scale2
          return :singular_mapping
        end

        @forward = [a, b, c, d, e, f]
        setup_inverse
        setup_residuals(gpts)
        :ok
      end

      def non_collinear?(points)
        origin = points[0]
        scale = 1.0
        points.each do |point|
          dx = (point[0] - origin[0]).abs
          dy = (point[1] - origin[1]).abs
          scale = [scale, dx, dy].max
        end
        threshold = @epsilon * scale * scale
        p1 = points.find do |point|
          (point[0] - origin[0]).abs > @epsilon * scale ||
            (point[1] - origin[1]).abs > @epsilon * scale
        end
        return false unless p1
        ux = p1[0] - origin[0]
        uy = p1[1] - origin[1]
        points.any? do |point|
          (ux * (point[1] - origin[1]) - uy * (point[0] - origin[0])).abs > threshold
        end
      end

      def setup_inverse
        a, b, c, d, e, f = @forward
        det = a * d - b * c
        @inverse = [d / det, -b / det, -c / det, a / det,
                    (c * f - d * e) / det, (b * e - a * f) / det]
      end

      def setup_residuals(gpts)
        sum = 0.0
        @control_points.each_with_index do |(linear, _geographic), i|
          predicted = apply_matrix(@forward, linear)
          dx = predicted[0] - gpts[i][0]
          dy = predicted[1] - gpts[i][1]
          @residuals << [dx, dy]
          sum += dx * dx + dy * dy
          @max_residual = [@max_residual, Math.sqrt(dx * dx + dy * dy)].max
        end
        @rmse = Math.sqrt(sum / @control_points.length)
      end

      def apply_matrix(matrix, point)
        a, b, c, d, e, f = matrix
        x, y = point
        [a * x + c * y + e, b * x + d * y + f]
      end

      def page_to_native(x, y, display, units)
        page_point = [x, y]
        if units == :pdf
          x *= @user_unit
          y *= @user_unit
        end
        unless display && @page
          return page_point, [x, y]
        end

        _left, bottom, right, top = crop_values
        native = case @rotation
                 when 0 then [x, y]
                 when 90 then [right - y, bottom + x]
                 when 180 then [right - x, top - y]
                 when 270 then [right - x, bottom + y]
                 end
        [page_point, native]
      end

      def native_to_page(point, display, units)
        x, y = point
        if display && @page
          _left, bottom, right, top = crop_values
          x, y = case @rotation
                 when 0 then [x, y]
                 when 90 then [y - bottom, right - x]
                 when 180 then [right - x, top - y]
                 when 270 then [right - x, y - bottom]
                 end
        end
        return [x / @user_unit, y / @user_unit] if units == :pdf
        [x, y]
      end

      def crop_values
        @crop_values ||= @page.box(:crop).map {|v| v.to_f * @user_unit }
      end

      # Ray-casting point-in-polygon test with an additional boundary check. The polygon is an
      # Array of [x, y] points; the last point is implicitly connected to the first.
      def point_in_polygon?(point, polygon)
        x, y = point
        scale = 1.0
        polygon.each {|px, py| scale = [scale, px.abs, py.abs].max }
        tolerance = @epsilon * scale
        inside = false
        previous = polygon.last
        polygon.each do |current|
          x1, y1 = previous
          x2, y2 = current
          if point_on_segment?(x, y, x1, y1, x2, y2, tolerance)
            return true
          end
          if (y1 > y) != (y2 > y) && x < (x2 - x1) * (y - y1) / (y2 - y1) + x1
            inside = !inside
          end
          previous = current
        end
        inside
      end

      def point_on_segment?(x, y, x1, y1, x2, y2, tolerance)
        cross = (y2 - y1) * (x - x1) - (x2 - x1) * (y - y1)
        length = Math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2)
        return false if length.zero? || cross.abs > tolerance * length
        dot = (x - x1) * (x2 - x1) + (y - y1) * (y2 - y1)
        dot >= -tolerance * length && dot <= length * length + tolerance * length
      end

    end

  end
end
