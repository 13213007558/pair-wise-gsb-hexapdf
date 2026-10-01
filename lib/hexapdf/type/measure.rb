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

require 'hexapdf/dictionary'

module HexaPDF
  module Type

    # A Measure dictionary specifies how measurement information should be formatted in textual
    # form.
    #
    # See: PDF2.0 s12.9.1
    class Measure < Dictionary

      define_type :Measure

      define_field :Type, type: Symbol, default: type
      define_field :Subtype, type: Symbol, default: :RL,
                   allowed_values: [:RL, :GEO]

      # :call-seq:
      #    measure.geo?      -> true or false
      #
      # Returns +true+ if this measure dictionary carries geospatial information (subtype
      # /GEO).
      def geo?
        self[:Subtype] == :GEO
      end

      # A GeoCS dictionary describes the geographic or projected coordinate system in which the
      # /GPTS control points of a GEO measure dictionary are specified.
      #
      # The coordinate system may be identified via /EPSG, /WKT and/or /URI. HexaPDF does not
      # fetch network resources or guess the coordinate system from numeric values; the available
      # identifiers are simply exposed for the calling application.
      class GeoCS < Dictionary

        define_field :Type, type: Symbol, default: type
        define_field :EPSG, type: Integer
        define_field :WKT,  type: String
        define_field :URI,  type: String

        # Returns +:geographic+ if the coordinate system can be identified as a geographic
        # coordinate system (angular units, e.g. latitude/longitude), +:projected+ if it can be
        # identified as a projected coordinate system (linear units), or +:unknown+ otherwise.
        #
        # Detection only uses the information stored in the dictionary itself (the /WKT string
        # and, if necessary, a small set of well-known geographic EPSG codes). No network access
        # is performed and no coordinate system is guessed if the identifiers are missing.
        def coordinate_system_kind
          if (wkt = self[:WKT])
            case wkt
            when /\AGEOG(?:CS|CRS)/i then :geographic
            when /\APROJ(?:CS|CRS)/i then :projected
            else :unknown
            end
          elsif GEOGRAPHIC_EPSG_CODES.include?(self[:EPSG])
            :geographic
          else
            :unknown
          end
        end

        # Well-known geographic coordinate system EPSG codes that use latitude/longitude axes and
        # for which the /GPTS values are stored in latitude/longitude order.
        GEOGRAPHIC_EPSG_CODES = [4326, 4269, 4267, 4258, 4019, 4322].freeze

      end

      # Only meaningful for subtype /GEO: the coordinate system of the /GPTS entries.
      define_field :GeoCS, type: :GeoCS, version: '1.7'

      # Only meaningful for subtype /GEO: an array of numbers forming pairs of local
      # (portrayal-display-unit) control point coordinates, relative to the viewport's /BBox
      # lower-left corner. Each pair corresponds to one pair in /GPTS.
      define_field :LPTS, type: PDFArray, version: '1.7'

      # Only meaningful for subtype /GEO: an array of numbers forming pairs of control point
      # coordinates in the coordinate system identified by /GeoCS. Each pair corresponds to one
      # pair in /LPTS.
      #
      # For geographic coordinate systems the pairs are stored in the order [latitude,
      # longitude] as specified by PDF2.0; HexaPDF::Geospatial::AffineLocator presents them in
      # [longitude, latitude] order in that case.
      define_field :GPTS, type: PDFArray, version: '1.7'

      # Only meaningful for subtype /GEO: an optional array of numbers in the same coordinate
      # system as /LPTS forming the polygon that marks the geographically valid region inside
      # the viewport's /BBox. If absent, the whole /BBox is considered valid.
      define_field :Bounds, type: PDFArray, version: '1.7'

      # Only meaningful for subtype /GEO: the portrayal display unit, i.e. the number of default
      # user space units per /LPTS and /Bounds unit. Defaults to 1.
      define_field :PDU, type: Numeric, default: 1, version: '1.7'

    end

  end
end
