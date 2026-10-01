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

require 'hexapdf/dictionary'

module HexaPDF
  module Type

    # A viewport dictionary specifies a rectangular region of a page and may associate
    # measurement information with that region.
    #
    # Viewports are listed in the /VP entry of a page. The /Measure entry of a geospatially
    # enabled viewport contains a Measure dictionary with subtype :GEO whose /LPTS and /GPTS
    # entries define the mapping from page points to geographic coordinates.
    #
    # The geospatial mapping can be used through #geo_locator which returns a
    # HexaPDF::Geo::Locator.
    #
    # See: PDF2.0 s14.9.5, s12.9.3
    class Viewport < Dictionary

      define_type :Viewport

      define_field :Type,    type: Symbol, default: type
      define_field :BBox,    type: PDFArray, required: true
      define_field :Name,    type: String
      define_field :Measure, type: :Measure

      # Returns the effective boundary polygon of the viewport in default (unrotated, 1/72 inch)
      # user space coordinates.
      #
      # If the associated GEO measure dictionary contains a /Bounds entry with at least six
      # values, that polygon (pairs of x/y coordinates) is used. Otherwise the four corners of
      # the /BBox entry are returned as a polygon.
      #
      # Returns +nil+ if the boundary information is missing or malformed.
      def bounds
        measure = self[:Measure]
        if measure && measure[:Subtype] == :GEO && measure.key?(:Bounds) &&
            measure[:Bounds].length >= 6 && measure[:Bounds].length.even?
          measure[:Bounds].each_slice(2).to_a
        elsif (bbox = effective_bbox(measure)) && bbox.length == 4
          left, bottom, right, top = 4.times.map {|index| bbox[index] }
          [[left, bottom], [right, bottom], [right, top], [left, top]]
        end
      end

      # Returns a HexaPDF::Geo::Locator for this viewport.
      #
      # The page is needed to handle page rotation and the /UserUnit entry; if it is not given,
      # the locator assumes an unrotated page with a user unit of one point.
      #
      # See HexaPDF::Geo::Locator.new for the keyword arguments.
      def geo_locator(page = nil, **kwargs)
        HexaPDF::Geo::Locator.new(self, page: page, **kwargs)
      end

      private

      def effective_bbox(measure)
        self[:BBox] || (measure && measure.key?(:BBox) ? measure[:BBox] : nil)
      end

    end

  end
end
