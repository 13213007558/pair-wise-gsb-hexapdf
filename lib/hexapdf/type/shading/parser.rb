# -*- encoding: utf-8; frozen_string_literal: true -*-

module HexaPDF
  module Type
    class Shading

      # Parses the binary stream data of Type 6 (Coons) and Type 7 (tensor-product) patch mesh
      # shadings into Shading::Patch objects.
      #
      # See Shading for an explanation of the bit widths and the Decode array.
      module Parser

        # Valid values for the BitsPerCoordinate entry.
        COORDINATE_BITS = [1, 2, 4, 8, 12, 16, 24, 32].freeze

        # Valid values for the BitsPerComponent entry.
        COMPONENT_BITS = [1, 2, 4, 8, 12, 16].freeze

        # Valid values for the BitsPerFlag entry.
        FLAG_BITS = [2, 4, 8].freeze

        # The control point indices that are stored explicitly in the stream, per patch kind
        # and edge flag.
        GIVEN_POINTS = {
          coons: {
            0 => (0..11).to_a,
            1 => (1..8).to_a,
            2 => (4..11).to_a,
            3 => [0, 1, 2, 7, 8, 9, 10, 11],
          },
          tensor: {
            0 => (0..15).to_a,
            1 => [1, 2, 3, 5, 6, 7, 9, 10, 11, 13, 14, 15],
            2 => (4..15).to_a,
            3 => [0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14],
          },
        }.freeze

        # The control points that are reused from the previous patch, per patch kind and edge
        # flag, as a mapping of new control point index to previous patch control point index.
        REUSED_POINTS = {
          coons: {
            1 => {0 => 3, 11 => 4, 10 => 5, 9 => 6},
            2 => {0 => 6, 1 => 7, 2 => 8, 3 => 9},
            3 => {3 => 0, 4 => 1, 5 => 2, 6 => 3},
          },
          tensor: {
            1 => {0 => 3, 4 => 7, 8 => 11, 12 => 15},
            2 => {0 => 12, 1 => 13, 2 => 14, 3 => 15},
            3 => {3 => 0, 7 => 4, 11 => 8, 15 => 12},
          },
        }.freeze

        # The corner color indices that are stored explicitly in the stream, per edge flag.
        GIVEN_COLORS = {0 => [0, 1, 2, 3], 1 => [1, 2], 2 => [2, 3], 3 => [0, 3]}.freeze

        # The corner colors that are reused from the previous patch, per patch kind and edge
        # flag, as a mapping of new color index to previous patch color index. Note that the
        # corner color order differs between the two patch kinds: c0..c3 sit at p0, p3, p6, p9
        # for Coons patches but at p0, p3, p15, p12 for tensor-product patches.
        REUSED_COLORS = {
          coons: {
            1 => {0 => 1, 3 => 2},
            2 => {0 => 2, 1 => 3},
            3 => {1 => 0, 2 => 1},
          },
          tensor: {
            1 => {0 => 1, 3 => 2},
            2 => {0 => 3, 1 => 2},
            3 => {1 => 0, 2 => 3},
          },
        }.freeze

        module_function

        # Parses +data+ (the decoded shading stream) and returns the patches as an array of
        # Shading::Patch objects.
        #
        # See Shading#patches for the raised errors.
        def parse(shading_type, data, bits_per_coordinate:, bits_per_component:, bits_per_flag:,
                  decode:)
          kind = case shading_type
                 when COONS_PATCH_MESH then :coons
                 when TENSOR_PRODUCT_PATCH_MESH then :tensor
                 else
                   raise HexaPDF::Error,
                         "Unsupported shading type #{shading_type.inspect}; only 6 (Coons " +                         "patch mesh) and 7 (tensor-product patch mesh) are supported"
                 end
          validate_bits('BitsPerCoordinate', bits_per_coordinate, COORDINATE_BITS)
          validate_bits('BitsPerComponent', bits_per_component, COMPONENT_BITS)
          validate_bits('BitsPerFlag', bits_per_flag, FLAG_BITS)
          raise HexaPDF::Error, "Missing required Decode array" if decode.nil?

          raise HexaPDF::Error, "Missing required Decode array" if decode.nil?

          decode = decode.to_a
          if decode.length < 6 || decode.length.odd?
            raise HexaPDF::Error,
                  "Invalid Decode array: expected 4 + 2*n numbers, got #{decode.length}"
          end
          color_components = (decode.length - 4) / 2

          reader = BitReader.new(data)
          coordinate_max = (1 << bits_per_coordinate) - 1
          component_max = (1 << bits_per_component) - 1
          patches = []

          # Leftover bits of a final, incomplete byte are padding and are ignored.
          while reader.remaining_bits >= 8
            index = patches.length
            flag = reader.read(bits_per_flag)
            if flag.nil? || flag > 3
              raise HexaPDF::Error, "Invalid edge flag #{flag.inspect} for patch #{index}"
            end
            if flag != 0 && patches.empty?
              raise HexaPDF::Error,
                    "Edge flag #{flag} of the first patch requires a previous patch"
            end

            points = Array.new(kind == :coons ? 12 : 16)
            REUSED_POINTS[kind].fetch(flag, {}).each do |new_i, prev_i|
              points[new_i] = patches[-1].points[prev_i]
            end
            GIVEN_POINTS[kind][flag].each do |point_index|
              x = read_decoded(reader, bits_per_coordinate, decode[0], decode[1], coordinate_max)
              y = read_decoded(reader, bits_per_coordinate, decode[2], decode[3], coordinate_max)
              unless x && y
                raise TruncatedDataError.new(index, "control point p#{point_index}")
              end
              points[point_index] = [x, y]
            end

            colors = Array.new(4)
            REUSED_COLORS[kind].fetch(flag, {}).each do |new_i, prev_i|
              colors[new_i] = patches[-1].colors[prev_i]
            end
            GIVEN_COLORS[flag].each do |color_index|
              colors[color_index] = Array.new(color_components) do |ci|
                value = read_decoded(reader, bits_per_component,
                                     decode[4 + 2 * ci], decode[5 + 2 * ci], component_max)
                raise TruncatedDataError.new(index, "color c#{color_index}") unless value
                value
              end
            end

            patches << Patch.new(kind, points, colors)
          end

          raise HexaPDF::Error, "Shading stream contains no patch data" if patches.empty?
          patches
        end

        def validate_bits(name, value, valid) # :nodoc:
          return if valid.include?(value)
          raise HexaPDF::Error,
                "Invalid #{name} value #{value.inspect}; valid values are #{valid.join(', ')}"
        end

        def read_decoded(reader, bits, min, max, raw_max) # :nodoc:
          raw = reader.read(bits)
          return nil if raw.nil?
          min + raw * (max - min) / raw_max.to_f
        end

      end

    end
  end
end
