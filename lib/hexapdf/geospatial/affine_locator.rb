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
  module Geospatial

    # Transforms points between the local page coordinate system of a geospatial viewport and the
    # geographic/projected coordinate system documented in its GEO measure dictionary using a
    # two-dimensional affine transformation.
    #
    # A locator is usually obtained from a viewport (or a page) and is valid exactly within the
    # viewport's coordinate system, i.e. all points share the same viewport and therefore the
    # same affine relation.
    #
    # The locator's status (see #status and HexaPDF::Geospatial::STATUSES) indicates whether the
    # transformation could be determined. Query methods always return a
    # HexaPDF::Geospatial::Result without raising an exception for malformed data.
    class AffineLocator

      # The viewport dictionary this locator was created from, or +nil+ for a bare measure.
      attr_reader :viewport

      # The GEO measure dictionary.
      attr_reader :measure

      # The coordinate-system dictionary (/GeoCS), if present.
      attr_reader :coordinate_system_dictionary

      # The lower-left origin [x, y] of the viewport's /BBox in page user space.
      attr_reader :origin

      # The portrayal display unit (/PDU), i.e. the number of page user space units per local
      # control-point unit.
      attr_reader :pdu

      # The page /UserUnit (number of multiples of 1/72 inch per page user space unit).
      attr_reader :user_unit

      # One of the symbols in HexaPDF::Geospatial::STATUSES.
      attr_reader :status

      # The number of control point pairs used for the fit.
      attr_reader :point_count

      # The root-mean-square residual of the control points in coordinate-system units, or +nil+
      # if the locator is not usable.
      attr_reader :rmse

      # The maximum absolute residual of the control points in coordinate-system units, or +nil+
      # if the locator is not usable.
      attr_reader :max_residual

      # The per-control-point residuals as arrays of [index, x_residual, y_residual, total], in
      # coordinate-system units.
      attr_reader :residuals

      # The fitted affine coefficients [a, b, c, d, e, f] mapping local PDU coordinates to
      # coordinate-system values as stored in /GPTS, or +nil+ if the locator is not usable.
      attr_reader :coefficients

      # Creates a new locator from a viewport dictionary (HexaPDF::Type::Viewport) or a GEO
      # measure dictionary.
      #
      # +origin+:: The page-space origin of the local coordinate system. Defaults to the
      #            lower-left corner of the viewport's /BBox or [0, 0] for bare measures.
      # +user_unit+:: The page's /UserUnit value (defaults to 1).
      def initialize(object, origin: nil, user_unit: 1)
        @user_unit = user_unit.to_f
        if object.respond_to?(:geo?)
          @viewport = nil
          @measure = object
        else
          @viewport = object
          @measure = object[:Measure]
        end
        @origin = origin
        @pdu = 1.0
        @status = :invalid_viewport
        @point_count = 0
        @rmse = @max_residual = nil
        @residuals = []
        @coefficients = nil
        @coordinate_system_dictionary = nil
        setup
      end

      # Returns +true+ if the locator can be used for coordinate conversion.
      def valid?
        @status == :ok
      end

      # Returns the kind of the coordinate system (+:geographic+, +:projected+ or +:unknown+).
      def coordinate_system_kind
        (@coordinate_system_dictionary &&
          @coordinate_system_dictionary.coordinate_system_kind) || :unknown
      end

      # Returns +true+ if the coordinate system values are angular (latitude/longitude). For such
      # systems the public interface uses longitude/latitude order even though /GPTS stores
      # latitude/longitude.
      def geographic?
        coordinate_system_kind == :geographic
      end

      # The valid region of this locator as an array of [x, y] vertices in local (PDU) control
      # point coordinates. This is the /Bounds polygon if present, otherwise the viewport /BBox.
      attr_reader :bounds

      # :call-seq:
      #    locator.page_to_geo(x, y)            -> Result
      #    locator.page_to_geo([x, y])         -> Result
      #    locator.page_to_geo(x, y, clamp: false) -> Result
      #
      # Converts a point in (unrotated) page user space to the documented coordinate system.
      #
      # If the point is not inside the valid region, the result's status is +:out_of_bounds+ and
      # +point+ is +nil+. With +clamp: true+ the converted coordinate is still returned and only
      # the +inside+ flag is set to +false+.
      def page_to_geo(x = nil, y = nil, clamp: false)
        x, y = x if y.nil? && x.kind_of?(Array)
        return failed unless valid?
        local = page_to_local(x, y)
        convert(local, clamp: clamp)
      end

      # :call-seq:
      #    locator.geo_to_page(x, y)            -> Result
      #    locator.geo_to_page([longitude, latitude]) -> Result
      #
      # Converts a coordinate-system point back to (unrotated) page user space. For geographic
      # coordinate systems the input is expected in longitude/latitude order.
      #
      # If the reverse-mapped point is not inside the valid region, the result's status is
      # +:out_of_bounds+ and +point+ is +nil+. With +clamp: true+ the page point is still returned
      # and only the +inside+ flag is set to +false+.
      def geo_to_page(x = nil, y = nil, clamp: false)
        x, y = x if y.nil? && x.kind_of?(Array)
        return failed unless valid?
        stored = geographic? ? [y, x] : [x, y]
        local = apply_inverse(stored[0], stored[1])
        inside = local && point_inside?(local)
        return Result.new(:out_of_bounds, nil, false) unless inside || clamp
        Result.new(inside ? :ok : :out_of_bounds, local_to_page(local[0], local[1]), !!inside)
      end

      # Converts a page user space point to local (PDU, /BBox-relative) control point
      # coordinates.
      def page_to_local(x, y)
        [(x - @origin[0]).to_f / @pdu, (y - @origin[1]).to_f / @pdu]
      end

      # Converts local (PDU, /BBox-relative) coordinates to page user space.
      def local_to_page(x, y)
        [x * @pdu + @origin[0], y * @pdu + @origin[1]]
      end

      # Returns +true+ if the page user space point lies inside the valid region.
      def page_point_inside?(x, y)
        valid? && point_inside?(page_to_local(x, y))
      end

      private

      def failed
        Result.new(@status, nil, false)
      end

      def setup
        return unless @measure.respond_to?(:[])
        return unless @measure.geo?

        lpts = numeric_array(@measure[:LPTS])
        gpts = numeric_array(@measure[:GPTS])
        return unless lpts && gpts
        return unless lpts.length.even? && gpts.length.even?

        local = lpts.each_slice(2).to_a
        geo = gpts.each_slice(2).to_a
        return unless local.length == geo.length
        @point_count = local.length
        if @point_count < 2
          @status = :insufficient_points
          return
        end

        @coordinate_system_dictionary = @measure[:GeoCS]
        pdu = @measure[:PDU]
        @pdu = pdu.kind_of?(Numeric) && pdu > 0 ? pdu.to_f : 1.0
        bbox = @viewport && @viewport[:BBox]
        @origin ||= bbox ? [bbox.left.to_f, bbox.bottom.to_f] : [0.0, 0.0]
        @origin = [@origin[0].to_f, @origin[1].to_f]
        @bounds = extract_bounds(local)

        fit(local, geo)
      end

      def extract_bounds(local)
        bounds = numeric_array(@measure[:Bounds])
        if bounds && bounds.length.even? && bounds.length >= 6
          bounds.each_slice(2).map {|x, y| [x.to_f, y.to_f] }
        elsif @viewport && @viewport[:BBox]
          box = @viewport[:BBox]
          [[0.0, 0.0], [box.width.to_f / @pdu, 0.0],
           [box.width.to_f / @pdu, box.height.to_f / @pdu], [0.0, box.height.to_f / @pdu]]
        else
          local
        end
      end

      def numeric_array(value)
        return unless value.respond_to?(:length) && value.respond_to?(:[])
        array = Array(value)
        array if array.all? {|entry| entry.kind_of?(Numeric) }
      end

      def fit(local, geo)
        if @point_count == 2
          fit_similarity(local, geo)
        else
          fit_affine(local, geo)
        end
      end

      # Determines the similarity transformation (rotation, uniform scale, translation) from two
      # control point pairs.
      def fit_similarity(local, geo)
        (x1, y1), (x2, y2) = local
        (u1, v1), (u2, v2) = geo
        dx = x2 - x1
        dy = y2 - y1
        denom = dx * dx + dy * dy
        if denom <= EPSILON
          @status = :collinear_points
          return
        end
        a = ((u2 - u1) * dx + (v2 - v1) * dy).to_f / denom
        b = ((v2 - v1) * dx - (u2 - u1) * dy).to_f / denom
        c = -b
        d = a
        e = u1 - a * x1 - c * y1
        f = v1 - b * x1 - d * y1
        if a.abs + b.abs <= EPSILON
          @status = :non_invertible
        else
          finalize_fit([a, b, c, d, e, f], local, geo)
        end
      end

      # Fits a general affine transformation. With three non-collinear control points the fit is
      # exact, otherwise least squares is used.
      def fit_affine(local, geo)
        n = @point_count
        # Normal equations of the least-squares problem  [x y 1] * coeffs = u  (and = v).
        s_x  = local.sum {|x, _| x.to_f }
        s_y  = local.sum {|_, y| y.to_f }
        s_xx = local.sum {|x, _| x.to_f * x }
        s_xy = local.sum {|x, y| x.to_f * y }
        s_yy = local.sum {|_, y| y.to_f * y }
        normal = [s_xx, s_xy, s_x,
                  s_xy, s_yy, s_y,
                  s_x,  s_y,  n.to_f]
        s_u  = geo.sum {|u, _| u.to_f }
        s_v  = geo.sum {|_, v| v.to_f }
        s_xu = local.zip(geo).sum {|(x, _), (u, _)| x.to_f * u }
        s_yu = local.zip(geo).sum {|(_, y), (u, _)| y.to_f * u }
        s_xv = local.zip(geo).sum {|(x, _), (_, v)| x.to_f * v }
        s_yv = local.zip(geo).sum {|(_, y), (_, v)| y.to_f * v }

        unless local_points_independent?(local)
          @status = :collinear_points
          return
        end
        params_u = Geospatial.solve_linear_system(normal, [s_xu, s_yu, s_u])
        params_v = Geospatial.solve_linear_system(normal, [s_xv, s_yv, s_v])
        unless params_u && params_v
          @status = :non_invertible
          return
        end

        a, c, e = params_u
        b, d, f = params_v
        finalize_fit([a, b, c, d, e, f], local, geo)
      end

      # Returns +true+ if the local control points span the plane, i.e. at least three of them are
      # not collinear (which is equivalent to the least-squares design matrix having full rank).
      def local_points_independent?(local)
        scale = local.flat_map {|x, y| [x.abs, y.abs] }.max.to_f
        local.combination(3).any? do |(x1, y1), (x2, y2), (x3, y3)|
          ((x2 - x1) * (y3 - y1) - (y2 - y1) * (x3 - x1)).abs > EPSILON * scale
        end
      end

      def finalize_fit(coeffs, local, geo)
        @coefficients = coeffs
        @residuals = local.zip(geo).each_with_index.map do |((x, y), (u, v)), index|
          pu, pv = apply_forward(x, y)
          ru = u - pu
          rv = v - pv
          [index, ru, rv, Math.sqrt(ru * ru + rv * rv)]
        end
        @max_residual = @residuals.map {|_, _, _, total| total }.max
        @rmse = Math.sqrt(@residuals.sum {|_, ru, rv, _| ru * ru + rv * rv } / @point_count)

        a, b, c, d, = @coefficients
        determinant = (a * d - b * c).to_f
        scale = [a.abs, b.abs, c.abs, d.abs].max
        if determinant.abs <= EPSILON * scale
          @status = :non_invertible
        else
          @inverse_matrix = [a, b, c, d, determinant]
          @status = :ok
        end
      end

    def convert(local, clamp:)
      x, y = local
      inside = point_inside?(local)
      unless inside || clamp
        return Result.new(:out_of_bounds, nil, false)
      end
      u, v = apply_forward(x, y)
      point = geographic? ? [v, u] : [u, v]
      Result.new(inside ? :ok : :out_of_bounds, point, inside)
    end

    def apply_forward(x, y)
      a, b, c, d, e, f = @coefficients
      [a * x + c * y + e, b * x + d * y + f]
    end

    def apply_inverse(u, v)
      return unless @inverse_matrix
      a, b, c, d, det = @inverse_matrix
      x = (d * u - c * v + (c * @coefficients[5] - d * @coefficients[4])) / det
      y = (a * v - b * u + (b * @coefficients[4] - a * @coefficients[5])) / det
      [x, y]
    end

    def point_inside?(local)
      Geospatial.point_in_polygon?(local, @bounds)
    end

    end
  end
end
