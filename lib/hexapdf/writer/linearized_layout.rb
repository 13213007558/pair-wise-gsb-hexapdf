# -*- encoding: utf-8; frozen_string_literal: true -*-
#
#--
# This file is part of HexaPDF.
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
require 'hexapdf/serializer'
require 'set'
require 'hexapdf/stream'
require 'hexapdf/xref_section'

module HexaPDF
  class Writer

    # Builds the two parts, cross-reference sections and hint stream of a linearized PDF.
    class LinearizedLayout

      Entry = Struct.new(:object, :contents, :shared_references, :group_objects,
                         keyword_init: true)

      def self.build(document)
        new(document).build
      end

      attr_reader :data, :main_xref_offset, :xref_section

      def initialize(document)
        @document = document
        @serializer = Serializer.new

        @revision = nil
        @trailer = @document.revisions.current.trailer
        @header = "%PDF-#{@document.version}\n%\xCF\xEC\xFF\xE8\xD7\xCB\xCD\n".b
      end

      def build
        validate_document
        prepare_object_groups
        assign_object_numbers
        order_shared_objects
        assign_object_numbers
        serialize_objects
        assemble_file

        self
      end

      private
      def order_shared_objects
        lengths = @shared_objects.each_with_object({}) do |object, lengths|
          lengths[object] = serialized_object_length(object)
        end
        @shared_objects.sort_by! {|object| [lengths[object], object.oid] }
        @shared_index = {}
        @shared_objects.each_with_index {|object, index| @shared_index[object] = index + 1 }
      end

      def serialized_object_length(object)
        previous_oid = object.oid
        object.oid = @size + 1
        length = serialize_indirect_object(object).bytesize
        object.oid = previous_oid
        length
      end

      def validate_document
        if @document.encrypted? || @document.revisions.current.trailer[:Encrypt]
          raise HexaPDF::Error, "Linearized writing requires one unencrypted revision"
        end
        if @document.revisions.count > 1
          raise HexaPDF::Error, "Linearized writing requires a single current revision"
        end
        trailer = @document.revisions.current.trailer
        unless trailer[:ID].respond_to?(:length) && trailer[:ID].length == 2
          raise HexaPDF::Error, "Linearized writing requires a permanent file ID"
        end

        @document.task(:optimize, compact: true, object_streams: :delete, xref_streams: :delete)
        @revision = @document.revisions.current
        @trailer = @revision.trailer
        if @document.revisions.count != 1
          raise HexaPDF::Error, "Linearized writing requires one unencrypted revision"
        end
        @catalog = @trailer[:Root]
        unless @catalog&.indirect? && @catalog.type == :Catalog && @catalog[:Pages]&.indirect?
          raise HexaPDF::Error, "Linearized writing requires a valid page tree"
        end

        @pages = @document.pages.to_a
        if @pages.empty?
          raise HexaPDF::Error, "Linearized writing requires at least one page"
        end
        unless @pages.all? {|page| page.indirect? && page.type == :Page }
          raise HexaPDF::Error, "Linearized writing requires valid page objects"
        end

        @source_objects = @revision.reject(&:null?)
        unsupported = @source_objects.any? do |object|
          object.gen != 0 || object.type == :ObjStm || object.type == :XRef
        end
        if unsupported
          raise HexaPDF::Error, "Linearized writing does not support object streams, " \
            "cross-reference streams or non-zero generation numbers"
        end
        if @source_objects.any? {|object| object.type == :Sig || object.type == :DocTimeStamp }
          raise HexaPDF::Error, "Linearized writing does not support signature dictionaries"
        end
      end

      def prepare_object_groups
        closures = @pages.map {|page| page_closure(@catalog[:Pages], page) }
        usage = Hash.new(0)
        closures.each {|closure| closure.each {|object| usage[object] += 1 } }

        @shared_objects = usage.select {|_object, count| count >= 2 }.keys.sort_by(&:oid)
        @shared_index = {}
        @shared_objects.each_with_index {|object, index| @shared_index[object] = index + 1 }

        @page_entries = closures.map.with_index do |closure, index|
          page = @pages[index]
          shared_refs = closure.select {|object| @shared_index.key?(object) }
          private_objects = bounded_page_closure(page, shared_refs.to_set) - shared_refs
          contents = content_streams(page).select {|content| private_objects.include?(content) }
          content_oids = contents.map(&:oid).to_set
          noncontents, content_objects = private_objects.partition do |object|
            !content_oids.include?(object.oid)
          end

          Entry.new(object: page, contents: contents, shared_references: shared_refs,
                    group_objects: noncontents + content_objects)
        end

        grouped = @page_entries.flat_map(&:group_objects) + @shared_objects
        @remaining_objects = @source_objects.sort_by(&:oid) - grouped
      end

      def page_closure(root, page)
        traverse([page, root]) do |object, queue|
          if object.type == :Pages
            object.value.each do |name, value|
              next if name == :Parent
              if name == :Kids
                child = child_towards_page(value, page)
                queue << child if child
              else
                queue_value(value, queue)
              end
            end
          else
            queue_value(object.value, queue)
          end
        end
      end

      def child_towards_page(kids, page)
        Array(kids).each do |kid|
          object = @document.deref(kid)
          next unless object
          return object if object == page
          if object.type == :Pages && page_in_subtree?(object, page)
            return object
          end
        end
        nil
      end

      def page_in_subtree?(node, page)
        node[:Kids].any? do |kid|
          object = @document.deref(kid)
          object == page || (object&.type == :Pages && page_in_subtree?(object, page))
        end
      end

      def bounded_page_closure(page, shared_objects)
        traverse([page]) do |object, queue|
          if object.type == :Pages
            object.value.each do |name, value|
              next if name == :Kids || name == :Parent
              if value.kind_of?(HexaPDF::Object) && value.indirect? && value.type == :Pages
                queue << value
              else
                queue_value(value, queue)
              end
            end
          else
            queue_value(object.value, queue)
          end
        end
      end

      def traverse(seeds)
        queue = seeds.dup
        result = []
        seen = {}

        while (object = queue.shift)
          next unless object.kind_of?(HexaPDF::Object) && object.indirect? && !object.null?
          next if seen.key?(object.oid)
          seen[object.oid] = true
          result << object
          yield(object, queue)
        end

        result
      end

      def queue_value(value, queue)
        case value
        when HexaPDF::Reference
          object = @document.object(value)
          queue << object if object
        when HexaPDF::Object
          if value.indirect?
            queue << value
          else
            queue_value(value.value, queue)
          end
        when Hash
          value.each_value {|entry| queue_value(entry, queue) }
        when Array
          value.each {|entry| queue_value(entry, queue) }
        end
      end

      def content_streams(page)
        contents = page[:Contents]
        contents = contents.value if contents.is_a?(HexaPDF::PDFArray)
        Array(contents).map {|content| @document.deref(content) }.
          select {|content| content.kind_of?(HexaPDF::Stream) }
      end

      def assign_object_numbers
        @linearization_object = @document.wrap({Linearized: 1}, oid: 1)
        @hint_object = @document.wrap({}, type: HexaPDF::Stream, oid: 2)

        @first_page_objects = @page_entries.first.group_objects
        later_groups = @page_entries[1..].flat_map(&:group_objects)
        @first_objects = @first_page_objects + @shared_objects
        @remaining_objects = @source_objects.sort_by(&:oid) - @first_objects - later_groups
        @later_objects = later_groups + @remaining_objects
        @physical_objects = @first_objects + @later_objects
        @physical_objects.each_with_index do |object, index|
          object.oid = index + 3
          object.gen = 0
        end
        @size = @physical_objects.size + 3
      end

      def serialize_objects
        @object_chunks = {}
        @physical_objects.each do |object|
          @object_chunks[object.oid] = serialize_indirect_object(object)
        end

        @hint_chunk = ''
        build_hint_data(initial_positions)
        @hint_object.stream = @hint_data
        @hint_chunk = serialize_indirect_object(@hint_object)
      end

      def assemble_file
        linearization_chunk = ''
        first_xref = ''
        main_xref = ''
        positions = {}
        main_offset = 0

        10.times do
          first_page = @page_entries.first.object
          later_length = @later_objects.sum {|object| @object_chunks[object.oid].bytesize }
          first_xref_offset = calculate_positions(positions, linearization_chunk,
                                                   first_xref.bytesize)
          main_offset = first_xref_offset + first_xref.bytesize + later_length
          linearization_values(first_page, first_xref_offset, main_offset,
                               main_offset + main_xref.bytesize)
          linearization_chunk = serialize_indirect_object(@linearization_object)
          first_xref_offset = calculate_positions(positions, linearization_chunk,
                                                   first_xref.bytesize)
          main_offset = first_xref_offset + first_xref.bytesize + later_length
          first_positions = all_positions(positions, linearization_chunk).
            select {|oid, _position| oid <= @first_objects.size + 2 }
          first_xref = cross_reference_subsections(first_positions,
                                               first_page_trailer(first_page), first_xref_offset,
                                               prev: main_offset)
          main_offset = first_xref_offset + first_xref.bytesize + later_length
          main_xref = cross_reference_section(0, @size, all_positions(positions,
                                                                        linearization_chunk),
                                               main_trailer, main_offset)
        end

        @main_xref_offset = main_offset
        @main_positions = all_positions(positions, linearization_chunk)
        @data = @header + linearization_chunk + @hint_chunk +
          @first_objects.map {|object| @object_chunks[object.oid] }.join + first_xref +
          @later_objects.map {|object| @object_chunks[object.oid] }.join + main_xref
        @xref_section = xref_section_for
      end

      def calculate_positions(positions, linearization_chunk, first_xref_length)
        positions.clear
        offset = @header.bytesize + linearization_chunk.bytesize + @hint_chunk.bytesize
        @first_objects.each do |object|
          positions[object.oid] = offset
          offset += @object_chunks[object.oid].bytesize
        end
        first_xref_offset = offset
        offset += first_xref_length
        @later_objects.each do |object|
          positions[object.oid] = offset
          offset += @object_chunks[object.oid].bytesize
        end
        first_xref_offset
      end

      def initial_positions
        calculate_positions({}, '', 256)
      end
      
      def linearization_values(first_page, first_xref_offset, main_offset, total_length)
        @linearization_object.value.replace(
          Linearized: 1,
          V: 1,
          H: [2, @hint_data.bytesize],
          O: first_page.oid,
          E: first_xref_offset,
          N: @pages.size,
          T: main_offset,
          L: total_length,
          ID: @trailer[:ID]
        )
      end

      def first_page_trailer(first_page)
        {Size: @size, Root: first_page, ID: @trailer[:ID]}
      end

      def main_trailer
        trailer = {Size: @size, Root: @catalog, ID: @trailer[:ID]}
        trailer[:Info] = @trailer[:Info] if @trailer[:Info]
        trailer
      end

      def cross_reference_section(first_oid, count, positions, trailer, startxref, prev: nil)
        value = trailer.dup
        value[:Prev] = prev if prev
        lines = +"xref\n#{first_oid} #{count}\n"
        if first_oid.zero?
          lines << "0000000000 65535 f \n"
          (1...count).each do |oid|
            position = positions.fetch(oid)
            lines << format('%010d 00000 n ', position) << "\n"
          end
        end
        lines << "trailer\n#{@serializer.serialize(value)}\n"
        lines << "startxref\n#{startxref}\n%%EOF\n"
        lines
      end

      def cross_reference_subsections(positions, trailer, startxref, prev: nil)
        value = trailer.dup
        value[:Prev] = prev if prev
        lines = +"xref\n"
        positions.keys.sort.chunk_while {|before, after| before + 1 == after }.each do |oids|
          lines << "#{oids.first} #{oids.size}\n"
          oids.each do |oid|
            if oid.zero?
              lines << "0000000000 65535 f \n"
            else
              lines << format('%010d 00000 n ', positions.fetch(oid)) << "\n"
            end
          end
        end
        lines << "trailer\n#{@serializer.serialize(value)}\n"
        lines << "startxref\n#{startxref}\n%%EOF\n"
        lines
      end

      def xref_section_for
        section = XRefSection.new
        section.mark_as_initial_section!
        @main_positions.each do |oid, position|
          section.add_in_use_entry(oid, 0, position)
        end
        section
      end

      def serialize_indirect_object(object)
        "#{object.oid} #{object.gen} obj\n#{@serializer.serialize(object)}\nendobj\n".b
      end

      def build_hint_data(positions)
        @hint_data = HintBuilder.build(@page_entries, @shared_objects, positions,
                                      @object_chunks)
      end

      def all_positions(positions, linearization_chunk)
        {1 => @header.bytesize, 2 => @header.bytesize + linearization_chunk.bytesize}.
          merge(positions)
      end

    end
  end
end

require_relative 'linearized_layout/hint_builder'
