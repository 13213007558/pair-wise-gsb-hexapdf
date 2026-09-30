# -*- encoding: utf-8; frozen_string_literal: true -*-

module HexaPDF
  class Writer
    class LinearizedLayout

      # Builds the primary hint stream described in PDF 1.7 appendix F.
      module HintBuilder

        module_function

        def build(page_entries, shared_objects, positions, object_chunks)
          shared_index = {}
          shared_objects.each_with_index {|object, index| shared_index[object] = index + 1 }
          bits = BitWriter.new
          shared_widths = calculate_shared_widths(shared_objects, object_chunks)
          page_widths = calculate_page_widths(page_entries, positions, object_chunks)
          private_lengths = page_entries.flat_map(&:contents).uniq.
            reject {|content| shared_index.key?(content) }.
            map {|content| object_chunks[content.oid].bytesize }
          minimum_content_length = private_lengths.min || 0
          content_lengths = private_lengths.map {|length| length - minimum_content_length }
          page_widths[:content_length] =
            bits_for(content_lengths.map(&:abs).max || 0, signed: true)
          page_widths[:content_position] = 32

          write_shared_header(bits, shared_objects, shared_widths, object_chunks, positions)
          write_shared_objects(bits, shared_objects, shared_widths, positions, object_chunks,
                               shared_index)
          write_page_header(bits, page_entries, page_widths, object_chunks, shared_index,
                            positions)
          write_pages(bits, page_entries, page_widths, positions, object_chunks, shared_index)
          bits.finalize
        end

        def calculate_shared_widths(shared_objects, object_chunks)
          lengths = shared_objects.map {|object| object_chunks[object.oid].bytesize }
          if lengths.empty?
            {number: 0, length: 0}
          else
            minimum = lengths.min
            {
              number: bits_for([shared_objects.size - 1, 0].max),
              length: bits_for(lengths.map {|length| length - minimum }.max || 0)
            }
          end
        end

        def calculate_page_widths(page_entries, positions, object_chunks)
          numbers = page_entries.map {|entry| noncontent_objects(entry).size }
          minimum_number, maximum_number = numbers.minmax
          first_position = positions[page_entries.first.object.oid] || 0
          positions_by_page = page_entries.map do |entry|
            entry.contents.map {|content| (positions[content.oid] || 0) - first_position }
          end
          page_lengths = page_entries.map do |entry|
            noncontent_size(entry, object_chunks)
          end
          {
            number: bits_for(maximum_number - minimum_number),
            object_number: bits_for(page_entries[1..].map {|entry| entry.object.oid - 3 }.max || 0,
                               signed: true),
            page_length: bits_for(delta_range(page_lengths), signed: true),
            content_position: bits_for(positions_by_page.flatten.max || 0),
            content_length: 15,
            shared_identifier: 15,
            shared_content_identifier: 15,
            shared_identifier_count: bits_for(page_entries[1..].map {|entry|
              entry.shared_references.size
            }.max || 0)
          }
        end

        def write_shared_header(bits, objects, widths, chunks, positions)
          if objects.empty?
            bits.write(0, 4).write(0, 4).write(0, 32).write(0, 32)
          else
            lengths = objects.map {|object| chunks[object.oid].bytesize }
            bits.write(widths[:number], 4)
            bits.write(widths[:length], 4)
            bits.write(objects.first.oid, 32)
            bits.write(lengths.first, 32)
          end
        end

        def write_shared_objects(bits, objects, widths, positions, chunks, _shared_index)
          objects.each_with_index do |object, index|
            if index.zero?
              bits.write(object.oid, 32)
              bits.write(chunks[object.oid].bytesize, 32)
              bits.write(positions[object.oid] || 0, 32)
            else
              previous = objects[index - 1]
              if chunks[object.oid].bytesize < chunks[previous.oid].bytesize
                raise HexaPDF::Error, "Invalid shared object hint ordering"
              end
              bits.write(object.oid - previous.oid - 1, widths[:number])
              bits.write(chunks[object.oid].bytesize - chunks[previous.oid].bytesize,
                        widths[:length])
            end
          end
        end

        def write_page_header(bits, entries, widths, chunks, shared_index, positions)
          numbers = entries.map {|entry| noncontent_objects(entry).size }
          lengths = entries.map {|entry| noncontent_size(entry, chunks) }
          first_position = positions[entries.first.object.oid] || 0
          private_contents = entries.flat_map(&:contents).uniq.
            reject {|content| shared_index.key?(content) }
          private_lengths = private_contents.map {|content| chunks[content.oid].bytesize }
          minimum_content_length = private_lengths.min || 0

          bits.write(widths[:number], 4)
          bits.write(widths[:object_number], 4)
          bits.write(widths[:page_length], 4)
          bits.write(widths[:content_position], 4)
          bits.write(widths[:content_length], 4)
          bits.write(widths[:shared_identifier], 4)
          bits.write(numbers.min, 32)
          bits.write(numbers.max, 32)
          bits.write(entries.first.object.oid, 32)
          bits.write(lengths.min, 32)
          bits.write(0, 32)
          bits.write(widths[:shared_identifier_count], 4)
          bits.write(first_position, 32)
          bits.write(widths[:content_position], 4)
          bits.write(minimum_content_length, 32)
        end

        def write_pages(bits, entries, widths, positions, chunks, shared_index)
          first_page_position = positions[entries.first.object.oid] || 0
          minimum_content_length = entries.flat_map(&:contents).uniq.
            reject {|content| shared_index.key?(content) }.
            map {|content| chunks[content.oid].bytesize }.min || 0
          entries.each_with_index do |entry, index|
            next if index.zero?
            bits.write(entry.object.oid - entries.first.object.oid, widths[:object_number])
            bits.write(noncontent_size(entry, chunks) - noncontent_size(entries.first, chunks),
                      widths[:page_length])
            bits.write(noncontent_objects(entry).size - noncontent_objects(entries.first).size,
                      widths[:number])
            bits.write(entry.shared_references.size, widths[:shared_identifier_count])
            entry.shared_references.each do |object|
              bits.write(shared_index[object] - 1, widths[:shared_identifier])
            end
            bits.write(entry.contents.size, 32)
            entry.contents.each do |content|
            shared = shared_index[content]
              if shared
                bits.write(shared, widths[:shared_content_identifier])
              else
                bits.write(0, widths[:shared_content_identifier])
                bits.write((positions[content.oid] || 0) - first_page_position,
                          widths[:content_position])
                bits.write(chunks[content.oid].bytesize - minimum_content_length,
                          widths[:content_length])
              end
            end
          end
        end

        def noncontent_size(entry, chunks)
          content_oids = entry.contents.map(&:oid)
          entry.group_objects.reject {|object| content_oids.include?(object.oid) }.
            sum {|object| chunks[object.oid].bytesize }
        end

        def noncontent_objects(entry)
          content_oids = entry.contents.map(&:oid)
          entry.group_objects.reject {|object| content_oids.include?(object.oid) }
        end

        def delta_range(values)
          return 0 if values.empty?
          minimum = values.min
          values.map {|value| value - minimum }.max
        end

        def bits_for(value, signed: false)
          value ||= 0
          bits = if value.zero?
                   0
                 elsif signed
                   Math.log(value.abs + 1, 2).floor + 1
                 else
                   Math.log(value + 1, 2).floor
                 end
          if bits > 15
            raise HexaPDF::Error, "Linearized PDF hint value is too large for its bit field"
          end
          bits
        end

        # Big-endian bit writer for the tightly packed linearization hint values.
        class BitWriter

          def initialize
            @bytes = []
            @current = 0
            @bits = 0
          end

          def write(value, bits)
            return self if bits.zero?
            value &= (1 << bits) - 1
            unless value.is_a?(Integer) && value >= 0 && value < (1 << bits)
              raise HexaPDF::Error, "Invalid linearized hint value #{value} for #{bits} bits"
            end
            @current = ((@current << bits) | value)
            @bits += bits
            flush while @bits >= 8
            self
          end

          def finalize
            if @bits.positive?
              @bytes << ((@current << (8 - @bits)) & 0xFF)
            end
            result = @bytes.pack('C*')
            initialize
            result
          end

          private

          def flush
            shift = @bits - 8
            @bytes << ((@current >> shift) & 0xFF)
            @current &= (1 << shift) - 1
            @bits = shift
          end

        end

      end

    end
  end
end
