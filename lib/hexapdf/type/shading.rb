# -*- encoding: utf-8; frozen_string_literal: true -*-

require 'hexapdf/error'
require 'hexapdf/stream'

module HexaPDF
  module Type

    # Represents a shading dictionary with support for parsing and sampling Type 6 (Coons patch
    # mesh) and Type 7 (tensor-product patch mesh) shadings.
    #
    # Shading dictionaries don't have a /Type key, so instances are not created automatically;
    # wrap the shading object explicitly, e.g.:
    #
    #   shading = doc.wrap(page.resources[:Shading][:Sh0], type: :Shading)
    #   mesh = shading.sample(tolerance: 0.5, max_subdivisions: 16)
    #
    # == Bit widths and the Decode array
    #
    # The vertex data of patch mesh shadings is stored in the shading stream as a sequence of
    # bit-packed, unsigned integers, most significant bit first and *not* aligned to byte
    # boundaries. Three dictionary entries define the bit width of each kind of value:
    #
    # BitsPerFlag::     Bits per edge flag (2, 4 or 8). Only the two least significant bits are
    #                   used; the flag selects how a new patch relates to the previous one.
    # BitsPerCoordinate:: Bits per vertex coordinate (1, 2, 4, 8, 12, 16, 24 or 32).
    # BitsPerComponent:: Bits per color component (1, 2, 4, 8, 12 or 16).
    #
    # The raw integers are mapped to their respective ranges through the Decode array
    # [xmin xmax ymin ymax c1,min c1,max ... cN,min cN,max]:
    #
    #   x  = xmin + raw * (xmax - xmin) / (2**BitsPerCoordinate - 1)
    #   ci = ci,min + raw * (ci,max - ci,min) / (2**BitsPerComponent - 1)
    #
    # The number N of color components per vertex is implied by the length of the Decode array
    # (4 + 2*N entries). When a Function is defined, the N interpolated components are the
    # inputs to that function; otherwise they are the color components of the shading's color
    # space.
    #
    # == Edge flags
    #
    # Each patch starts with an edge flag. Flag 0 introduces a completely new patch. Flags 1, 2
    # and 3 indicate that the new patch shares, respectively, its left, top or right edge with
    # the previous patch; the control points and corner colors of the shared edge are then
    # *reused* from the previous patch and not stored in the stream.
    #
    # See: PDF2.0 s8.7.4.5
    class Shading < Stream

      # Raised when the shading stream data ends in the middle of a patch. The message and the
      # #patch_index attribute identify the patch that is missing data.
      class TruncatedDataError < HexaPDF::Error

        # The zero-based index of the patch that could not be read completely.
        attr_reader :patch_index

        def initialize(patch_index, detail) # :nodoc:
          @patch_index = patch_index
          super("Shading data is truncated: patch #{patch_index} is incomplete, missing #{detail}")
        end

      end

      # Shading type of a Coons patch mesh.
      COONS_PATCH_MESH = 6

      # Shading type of a tensor-product patch mesh.
      TENSOR_PRODUCT_PATCH_MESH = 7

      define_field :ShadingType,       type: Integer, required: true
      define_field :ColorSpace,        type: [Symbol, PDFArray], required: true
      define_field :Background,        type: PDFArray
      define_field :BBox,              type: PDFArray
      define_field :AntiAlias,         type: Boolean, default: false
      define_field :BitsPerCoordinate, type: Integer
      define_field :BitsPerComponent,  type: Integer
      define_field :BitsPerFlag,       type: Integer
      define_field :Decode,            type: PDFArray
      define_field :Function,          type: [Dictionary, PDFArray]

      # Parses the patch mesh stream and returns the contained patches as an array of
      # Shading::Patch objects.
      #
      # Only shading types 6 and 7 are supported. Raises HexaPDF::Error for other shading types
      # or invalid dictionary entries and Shading::TruncatedDataError (naming the affected patch)
      # when the stream data ends in the middle of a patch.
      def patches
        Parser.parse(self[:ShadingType], stream,
                     bits_per_coordinate: self[:BitsPerCoordinate],
                     bits_per_component: self[:BitsPerComponent],
                     bits_per_flag: self[:BitsPerFlag],
                     decode: self[:Decode])
      end

      # Samples all patches of the shading and returns a Shading::Sampler::Mesh with positions
      # and colors on a regular grid per patch.
      #
      # tolerance::        The maximum allowed deviation (in shading space units for positions
      #                    and in color component units for colors) between the exact patch
      #                    surface and the bilinear interpolation of a grid cell.
      # max_subdivisions:: The maximum number of subdivisions per patch edge, i.e. the resource
      #                    limit for the sampling process.
      #
      # All patches are sampled with the same number of subdivisions, so patches sharing an edge
      # (via edge flags) are sampled at identical parameter positions and no cracks appear along
      # shared edges.
      #
      # If the tolerance cannot be met within +max_subdivisions+, the returned mesh still
      # contains the best sampling and Mesh#tolerance_met? returns false; Mesh#unmet_regions
      # then describes the parameter space regions that did not satisfy the tolerance.
      def sample(tolerance: 0.1, max_subdivisions: 16)
        Sampler.sample(patches, color_transform,
                     tolerance: tolerance, max_subdivisions: max_subdivisions)
      end

      # Returns a callable that maps bilinearly interpolated color input components to the final
      # color components.
      #
      # If the shading defines a Function, it is applied *after* the interpolation of the corner
      # colors, as required by the PDF specification; otherwise the components are returned
      # unchanged.
      def color_transform
        function = self[:Function]
        if function
          callable = Function.create(function)
          lambda {|components| callable.call(components) }
        else
          lambda {|components| components }
        end
      end

    end

  end
end

require 'hexapdf/type/shading/bit_reader'
require 'hexapdf/type/shading/patch'
require 'hexapdf/type/shading/parser'
require 'hexapdf/type/shading/function'
require 'hexapdf/type/shading/sampler'
