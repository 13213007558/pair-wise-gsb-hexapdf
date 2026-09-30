# -*- encoding: utf-8; frozen_string_literal: true -*-

require 'hexapdf/error'
require 'hexapdf/reference'
require 'hexapdf/serializer'
require 'hexapdf/xref_section'

module HexaPDF

  # Writes a PDF in the two-revision layout used by linearized PDFs.
  class LinearizedWriter

    LINEARIZATION_OID = 1
    FIRST_CATALOG_OID = 2
    FIRST_PAGES_OID = 3
    FIRST_PAGE_OID = 4
    FIRST_SHARED_OID = 5
    FIXED_INTEGER_WIDTH = 10

    def self.write(document, io)
      new(document, io).write
    end

    def initialize(document, io)
      @document = document
      @io = io
      @io.binmode
      @io.seek(0, IO::SEEK_SET)

      @serializer = Serializer.new
      @target = HexaPDF::Document.new
      @target.version = [document.version, '1.2'].max
      @clones = {}
    end

    def write
      validate_supported_document
      build_object_graph
      layout
      serialize

      [@main_xref_offset, @main_xref_section]
    end

    private

    def validate_supported_document
      if @document.encrypted?
        raise HexaPDF::Error, "Cannot linearize an encrypted PDF"
      elsif @document.revisions.count > 1
        raise HexaPDF::Error, "Cannot linearize a PDF with multiple revisions"
      elsif @document.signed?
        raise HexaPDF::Error, "Cannot linearize a signed PDF"
      end

      @page = @document.catalog[:Pages].page(0)
      raise HexaPDF::Error, "Cannot linearize a PDF without a page" unless @page
    end

    def build_object_graph
      @full_order = collect_reachable(full_roots)
      @full_order.each {|object| clone_indirect(object) }
      @catalog_clone = @clones.fetch(@document.catalog.data)

      dependencies = collect_reachable([@page], first_page: true)
      dependencies.delete(@page)
      collect_first_page_parent_chain(dependencies)
      dependencies.each {|object| clone_indirect(object) }
      @shared_objects = dependencies.uniq(&:data).
        sort_by {|object| [object.oid, object.gen] }
      assign_shared_object_numbers
      @clones[@page.data].oid = FIRST_PAGE_OID
      assign_remaining_object_numbers
      renumber_clone_references
      build_first_page_structure
      build_linearization_objects
    end

    def renumber_clone_references
      @clones.each_value do |clone|
        clone.value = rewrite_references(clone.value)
      end
    end

    def rewrite_references(value)
      case value
      when Reference
        source = @document.object(value)
        target = source && @clones[source.data]
        target ? Reference.new(target.oid, target.gen) : value
      when Object
        return value if value.indirect? || value.null?
        value.value = rewrite_references(value.value)
        value
      when Hash
        value.transform_values {|inner| rewrite_references(inner) }
      when Array
        value.map {|inner| rewrite_references(inner) }
      else
        value
      end
    end

    def assign_shared_object_numbers
      @shared_objects.each_with_index do |source, index|
        @clones[source.data].oid = FIRST_SHARED_OID + index
      end
      @hint_stream_oid = FIRST_SHARED_OID + @shared_objects.size
      @first_full_oid = @hint_stream_oid + 1
    end

    def assign_remaining_object_numbers
      next_oid = @first_full_oid
      @full_order.each do |source|
        clone = @clones.fetch(source.data)
        next if clone.oid != 0
        clone.oid = next_oid
        next_oid += 1
      end
      @main_size = next_oid
    end

    def full_roots
      roots = [@document.trailer[:Root]]
      roots << @document.trailer[:Info] if @document.trailer[:Info]
      roots.compact
    end

    def collect_reachable(roots, first_page: false)
      order = []
      seen = {}
      stack = roots.reverse

      until stack.empty?
        object = stack.pop
        next unless object.kind_of?(Object) && !object.null? &&
          !seen[object.data]
        seen[object.data] = true
        order << object
        next if first_page && object.type == :Pages && object == @page[:Parent] &&
          object != @page
        each_reference(object, first_page: first_page) do |reference|
          stack << reference
        end
      end

      order
    end

    def collect_first_page_parent_chain(dependencies)
      parent = @page[:Parent]
      visited = {}
      while parent && !visited[parent.data]
        visited[parent.data] = true
        dependencies << parent
        parent.value.each do |key, value|
          next if %i[Kids Count Parent Type].include?(key)
          scan(value) do |_inner_key, reference|
            resolved = dereference(reference)
            if resolved && resolved.type != :Pages && !dependencies.include?(resolved)
              dependencies << resolved
            end
          end
        end
        parent = parent[:Parent]
      end
    end

    def each_reference(object, first_page:)
      scan(object.value) do |key, value|
        resolved = dereference(value)
        next unless resolved
        next if resolved.type == :XRef || resolved.type == :ObjStm
        next if first_page && omit_from_first_page?(key, resolved)
        yield(resolved)
      end
    end

    def omit_from_first_page?(key, resolved)
      return true if %i[P Dest A].include?(key)
      return true if key == :Parent && resolved != @page[:Parent]
      return true if resolved.type == :Pages && resolved != @page[:Parent]
      false
    end

    def dereference(value)
      return unless value.kind_of?(Reference) ||
        (value.kind_of?(Object) && value.indirect? && !value.null?)
      resolved = value.kind_of?(Reference) ? @document.object(value) : value
      resolved unless resolved.nil? || resolved.null?
    end

    def scan(value, key = nil, &block)
      case value
      when Reference
        yield(key, value)
      when Object
        if value.indirect? && !value.null?
          yield(key, value)
        else
          value = value.value
          if value.kind_of?(Hash) || value.kind_of?(Array)
            scan(value, key, &block)
          end
        end
      when Hash
        value.each {|inner_key, inner| scan(inner, inner_key, &block) }
      when Array
        value.each {|inner| scan(inner, key, &block) }
      end
    end

    def clone_indirect(source)
      @clones[source.data] ||= begin
        stream = source.kind_of?(Stream) ? source.raw_stream : nil
        initial_value = case source.value
                        when Hash then {}
                        when Array then []
                        end
        clone = @target.wrap(initial_value, type: source.class, stream: stream)
        clone.document = @target
        @clones[source.data] = clone
        clone.value = clone_value(source.value)
        clone
      end
    end

    def clone_value(value)
      case value
      when Reference
        clone_indirect(@document.object(value))
      when Object
        if value.indirect? && !value.null?
          clone_indirect(value)
        else
          clone_value(value.value)
        end
      when Hash
        value.transform_values {|inner| clone_value(inner) }
      when Array
        value.map {|inner| clone_value(inner) }
      when String
        value.dup
      else
        value
      end
    end

    def build_first_page_structure
      @first_pages = @target.wrap({
        Type: :Pages,
        Kids: [Reference.new(FIRST_PAGE_OID)],
        Count: 1,
      }, type: Type::PageTreeNode)
      @first_pages.oid = FIRST_PAGES_OID
      @first_pages.document = @target

      @first_catalog = @target.wrap({
        Type: :Catalog,
        Pages: Reference.new(FIRST_PAGES_OID),
      }, type: Type::Catalog)
      @first_catalog.oid = FIRST_CATALOG_OID
      @first_catalog.document = @target
    end

    def build_linearization_objects
      shared_hint_size = @shared_objects.empty? ? 0 : 6
      @hint_data_size = (15 + 12 * @document.pages.count + shared_hint_size) * 4
      @linearization_dictionary = @target.wrap({}, type: Dictionary)
      @linearization_dictionary.oid = LINEARIZATION_OID
      @linearization_dictionary.document = @target

      @hint_stream = @target.wrap({Type: :OEBits, Length: @hint_data_size},
                                  type: Stream, stream: "\0".b * @hint_data_size)
      @hint_stream.oid = @hint_stream_oid
      @hint_stream.document = @target
    end

    def layout
      @first_objects = [
        @linearization_dictionary,
        @first_catalog,
        @first_pages,
        @clones.fetch(@page.data),
        *@shared_objects.map {|source| @clones.fetch(source.data) },
        @hint_stream,
      ]
      @remainder_objects = @full_order.reject do |source|
        source == @page || @shared_objects.include?(source)
      end.map {|source| @clones.fetch(source.data) }
    end

    def serialize
      @locations = {}
      @lengths = {}
      @length_width = 1
      update_linearization_data
      loop do
        serialize_once
        update_linearization_data
        break if @io.size.to_s.length == @length_width || @length_width >= 10
        @length_width += 1
      end
    end

    def serialize_once
      @io.truncate(0)
      @io.seek(0)
      @locations = {}
      @lengths = {}

      write_header
      @first_objects.each {|object| write_object(object) }
      write_first_xref
      @remainder_objects.each {|object| write_object(object) }
      write_main_xref
      update_linearization_data
    end

    def write_header
      @io << "%PDF-#{@target.version}\n%\xCF\xEC\xFF\xE8\xD7\xCB\xCD\n"
    end

    def write_object(object)
      if object == @linearization_dictionary
        write_linearization_dictionary
        return
      end
      serialized = @serializer.serialize(object)
      @locations[object.oid] = @io.pos
      @lengths[object.oid] = serialized.bytesize + "\nendobj\n".bytesize
      @io << "#{object.oid} 0 obj\n"
      @io << serialized
      @io << "\nendobj\n"
    end

    def write_linearization_dictionary
      dictionary = @linearization_dictionary
      serialized = "<</Linearized 1/V #{fixed_integer(dictionary[:V])}" \
        "/L #{format("%0#{@length_width}d", dictionary[:L])}" \
        "/H[#{fixed_integer(dictionary[:H][0])} " \
        "#{fixed_integer(dictionary[:H][1])}]" \
        "/O #{fixed_integer(dictionary[:O])}/E #{fixed_integer(dictionary[:E])}" \
        "/N #{fixed_integer(dictionary[:N])}/T " \
        "#{fixed_integer(dictionary[:T])}>>".b
      @locations[LINEARIZATION_OID] = @io.pos
      @lengths[LINEARIZATION_OID] = serialized.bytesize + "\nendobj\n".bytesize
      @io << "#{LINEARIZATION_OID} 0 obj\n#{serialized}\nendobj\n"
    end

    def write_first_xref
      @first_xref_offset = @io.pos
      section = XRefSection.new
      section.mark_as_initial_section!
      (LINEARIZATION_OID..@hint_stream_oid).each do |oid|
        section.add_in_use_entry(oid, 0, @locations.fetch(oid))
      end
      write_xref_section(section)
      @io << "trailer\n#{serialize_first_trailer}\n"
      write_startxref(@main_xref_offset || 0)
    end

    def write_main_xref
      @main_xref_offset = @io.pos
      section = XRefSection.new
      section.mark_as_initial_section!
      (LINEARIZATION_OID..@hint_stream_oid).each do |oid|
        section.add_in_use_entry(oid, 0, @locations.fetch(oid))
      end
      @remainder_objects.each do |object|
        section.add_in_use_entry(object.oid, 0, @locations.fetch(object.oid))
      end
      @main_xref_section = section
      write_xref_section(section)
      @io << "trailer\n#{@serializer.serialize(main_trailer_value)}\n"
      write_startxref(@main_xref_offset)
    end

    def write_xref_section(section)
      @io << "xref\n"
      section.each_subsection do |entries|
        @io << "#{entries.first.oid} #{entries.size}\n"
        entries.each do |entry|
          if entry.in_use?
            @io << format("%010d 00000 n \n", entry.pos)
          else
            @io << "0000000000 65535 f \n"
          end
        end
      end
    end

    def write_startxref(offset)
      @io << "startxref\n#{fixed_integer(offset)}\n%%EOF\n"
    end

    def serialize_first_trailer
      value = {
        Root: Reference.new(FIRST_CATALOG_OID),
        Size: @hint_stream_oid + 1,
        Prev: @main_xref_offset || 0,
      }
      if @document.trailer[:ID]
        value[:ID] = Object.deep_copy(@document.trailer[:ID])
      end
      serialize_trailer(value)
    end

    def serialize_trailer(value)
      result = +"<<"
      value.each do |key, item|
        next if item.nil?
        result << "/#{key} "
        result << if %i[Size Prev].include?(key)
                    fixed_integer(item)
                  else
                    @serializer.serialize(item)
                  end
      end
      result << ">>"
    end

    def main_trailer_value
      value = {Root: @catalog_clone, Size: @main_size}
      if (info = @document.trailer[:Info])
        value[:Info] = @clones.fetch(info.data)
      end
      if @document.trailer[:ID]
        value[:ID] = Object.deep_copy(@document.trailer[:ID])
      end
      value
    end

    def update_linearization_data
      @linearization_dictionary.value.replace(
        Linearized: 1,
        V: 1,
        L: @locations.empty? ? 0 : @io.size,
        H: [@locations[@hint_stream_oid] || 0, @lengths[@hint_stream_oid] || 0],
        O: FIRST_PAGE_OID,
        E: @first_xref_offset || 0,
        N: @document.pages.count,
        T: @main_xref_offset || 0
      )
      data = @locations.empty? ? "\0".b * @hint_data_size : hint_data
      @hint_stream.stream = data
      @hint_stream.value[:Length] = data.bytesize
      hint_serialized = @serializer.serialize(@hint_stream)
      @lengths[@hint_stream_oid] ||= 0
      @lengths[@hint_stream_oid] = hint_serialized.bytesize +
        "\nendobj\n".bytesize
    end

    def hint_data
      return ''.b if @locations.empty?
      page_end = @locations.fetch(@hint_stream_oid)
      content = first_content_object
      content_item = content ? content.oid : 0
      content_offset = if content
                         @locations.fetch(content.oid) - @locations.fetch(FIRST_PAGE_OID)
                       else
                         0
                       end
      content_length = content ? @lengths.fetch(content.oid) : 0
      page_group_length = @locations.fetch(@hint_stream_oid) -
        @locations.fetch(FIRST_PAGE_OID)

      header = [
        FIRST_PAGE_OID, page_end, @document.pages.count,
        32, 32, 32, 32, 32, 32, 32, 32, 32,
        32,
        @shared_objects.empty? ? 2 : FIRST_SHARED_OID,
      ].pack("N*")
      first_page_hint = [
        1 + @shared_objects.size, FIRST_PAGE_OID, page_group_length,
        @shared_objects.size, FIRST_SHARED_OID - FIRST_PAGE_OID,
        content_item, content_offset, content_length,
        @shared_objects.size, 1,
      ].pack("N*")
      page_hint = first_page_hint + "\0".b * (48 * (@document.pages.count - 1))
      result = header + page_hint
      unless @shared_objects.empty?
        result << [
          @shared_objects.size, FIRST_SHARED_OID,
          shared_group_length, 0, 0, 0,
        ].pack("N*")
      end
      result
    end

    def shared_group_length
      return 0 if @shared_objects.empty?
      @locations.fetch(@hint_stream_oid) - @locations.fetch(FIRST_SHARED_OID)
    end

    def first_content_object
      contents = @page[:Contents]
      if contents.kind_of?(Array) || contents.kind_of?(PDFArray)
        contents = contents[0]
      end
      return unless contents
      contents = @document.deref(contents)
      @clones[contents.data]
    end

    def fixed_integer(number)
      format("%0#{FIXED_INTEGER_WIDTH}d", number)
    end

  end

end
