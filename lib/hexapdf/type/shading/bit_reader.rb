# -*- encoding: utf-8; frozen_string_literal: true -*-

module HexaPDF
  module Type
    class Shading

      # Reads bit-packed unsigned integers from a binary string.
      #
      # The values in a patch mesh shading stream (edge flags, vertex coordinates and color
      # components) are stored consecutively, most significant bit first, and are generally not
      # aligned to byte boundaries. Only the end of the data is padded with zero bits up to a
      # byte boundary.
      class BitReader

        # The current reading position in bits.
        attr_reader :bit_position

        def initialize(data)
          @data = data
          @bit_position = 0
        end

        # Returns the number of unread bits.
        def remaining_bits
          @data.bytesize * 8 - @bit_position
        end

        # Reads an unsigned integer of the given bit +width+.
        #
        # Returns +nil+ if fewer than +width+ bits are available.
        def read(width)
          return nil if remaining_bits < width

          value = 0
          width.times do
            byte = @data.getbyte(@bit_position >> 3)
            value = (value << 1) | ((byte >> (7 - (@bit_position & 7))) & 1)
            @bit_position += 1
          end
          value
        end

      end

    end
  end
end
