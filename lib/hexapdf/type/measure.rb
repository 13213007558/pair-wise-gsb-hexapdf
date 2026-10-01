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
    # form or how coordinates on a page map to real world values.
    #
    # The standard defines two subtypes:
    #
    # * :RL (rectilinear measure) specifies how distances and areas should be formatted.
    # * :GEO (geospatial measure) maps points on a page to geographic coordinates via an affine
    #   transformation defined by the /LPTS and /GPTS entries. The geospatial mapping itself is
    #   handled by HexaPDF::Geo::Locator which can be obtained through
    #   HexaPDF::Type::Viewport#geo_locator.
    #
    # See: PDF2.0 s12.9.1, s12.9.3, Adobe Supplement to ISO 32000
    class Measure < Dictionary

      define_type :Measure

      define_field :Type, type: Symbol, default: type
      define_field :Subtype, type: Symbol, default: :RL,
                   allowed_values: [:RL, :GEO]

      # A GEO measure dictionary describes the mapping from page points (in the coordinate system
      # of the associated viewport) to geographic coordinates using a two-dimensional affine
      # transformation.
      #
      # The /LPTS and /GPTS arrays contain pairs of x/y values (2 to 10 pairs) of linear (page)
      # points and the corresponding geographic points. Two pairs define a similarity
      # transformation (rotation, uniform scaling and translation), three pairs an affine
      # transformation and more than three pairs are fitted using least-squares fitting.
      #
      # The coordinate systems themselves are only identified by their names; HexaPDF does not
      # guess or convert between coordinate systems.
      #
      # See: PDF2.0 s12.9.3, Viewport
      class Geo < Measure

        define_type :XXGeoMeasure

        define_field :Subtype, type: Symbol, required: true, default: :GEO
        define_field :BBox,   type: PDFArray, version: '1.7'
        define_field :Bounds, type: PDFArray, version: '1.7'
        define_field :GCS,    type: [Symbol, String], default: :GCS_WGS84, version: '1.7'
        define_field :DCS,    type: [Symbol, String], version: '1.7'
        define_field :GPTS,   type: PDFArray, required: true, version: '1.7'
        define_field :LPTS,   type: PDFArray, required: true, version: '1.7'
        define_field :PDS,    type: Dictionary, version: '1.7'

      end

    end

  end
end
