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

require 'set'
require 'hexapdf/content/parser'

module HexaPDF
  module Task

    # Task for reading the logical structure (tagged PDF) of a document.
    #
    # The document's structure tree (catalog entry /StructTreeRoot) is traversed and each
    # structure element is converted into a read-only Element instance exposing the (mapped) role,
    # language, alternative/expansion/actual text, the children and the page contents associated
    # with the element.
    #
    # Content is ordered according to the structure tree and *not* according to the position of
    # text on the page: a structure element's content is returned in the order its children (and
    # their marked-content sequences) appear in the structure tree. Marked content inside Form
    # XObjects is handled as well.
    #
    # All three possible kinds of content references are supported:
    #
    # * integer MCIDs (a structure element's /K entry is an integer),
    # * marked-content reference dictionaries (/Type /MCR), and
    # * object reference dictionaries (/Type /OBJR).
    #
    # The structure tree's ParentTree is used to cross-check the reverse relationships of all
    # marked-content and object references.
    #
    # Since real-world tagged PDFs may be damaged in various ways, problems are not fatal: they
    # are collected as Diagnostic instances (carrying the object position, i.e. the object and
    # generation numbers of the involved PDF object) in Result#diagnostics, and all parts that
    # could still be read are retained.
    #
    # The task is strictly read-only: no PDF objects are added, deleted or modified.
    #
    # Examples:
    #
    #   result = doc.task(:read_logical_structure)
    #   result.elements.each do |element|
    #     puts "#{element.role} (#{element.language}): #{element.text}"
    #   end
    #   result.diagnostics.each {|d| puts d }
    #
    # See: PDF2.0 s14.7
    class ReadLogicalStructure

      # A diagnostic message describing a problem found while reading the structure tree.
      class Diagnostic

        # The severity of the diagnostic, either +:error+ or +:warning+.
        attr_reader :severity

        # The human-readable message.
        attr_reader :message

        # The object number of the involved PDF object, or +nil+ if there is none.
        attr_reader :oid

        # The generation number of the involved PDF object, or +nil+ if there is none.
        attr_reader :gen

        # Creates a new diagnostic.
        def initialize(severity, message, oid: nil, gen: nil)
          @severity = severity
          @message = message
          @oid = oid
          @gen = gen
        end

        # Returns the object position of the involved PDF object as "oid,gen" string, or "—" if
        # there is none.
        def position
          oid ? "#{oid},#{gen || 0}" : "—"
        end

        # Returns a string representation of the diagnostic.
        def to_s
          "#{severity}: [#{position}] #{message}"
        end
        alias inspect to_s

        # Returns +true+ if the severity is +:error+.
        def error?
          severity == :error
        end

        # Returns +true+ if the severity is +:warning+.
        def warning?
          severity == :warning
        end

      end

      # A marked-content occurrence extracted from a page's or Form XObject's content stream.
      class MarkedContent

        # The marked content identifier.
        attr_reader :mcid

        # The page on which the marked content is rendered.
        attr_reader :page

        # The Form XObject containing the marked content, or +nil+ if it is directly in the page
        # content stream.
        attr_reader :stream

        # The text shown directly inside this marked-content sequence, in drawing order.
        #
        # Text inside nested marked-content sequences with their own MCID is attributed to the
        # innermost sequence and therefore not included here.
        attr_reader :text

        # Creates a new MarkedContent instance.
        def initialize(mcid, page, stream, text)
          @mcid = mcid
          @page = page
          @stream = stream
          @text = text
        end

        def inspect #:nodoc:
          "#<#{self.class.name} mcid=#{mcid} page=#{page.oid} stream=#{stream&.oid || '-'} " \
            "text=#{text.inspect}>"
        end

      end

      # A read-only view of one structure element of the logical structure tree.
      class Element

        # The wrapped HexaPDF::Type::StructElem dictionary.
        attr_reader :object

        # The role after resolving it through the RoleMap chain (see PDF2.0 s14.7.3).
        attr_reader :role

        # The original role as specified by the structure element's /S entry.
        attr_reader :original_role

        # The language (/Lang entry), or +nil+.
        attr_reader :language

        # The alternative text (/Alt entry), or +nil+.
        attr_reader :alternative_text

        # The abbreviation expansion (/E entry), or +nil+.
        attr_reader :expansion_text

        # The actual text (/ActualText entry), or +nil+.
        attr_reader :actual_text

        # The title (/T entry), or +nil+.
        attr_reader :title

        # The immediate children (Element, MarkedContent or ObjectReferenceContent instances), in
        # the order specified by the structure tree.
        attr_reader :children

        # Creates a new Element view.
        def initialize(object, role, original_role, attrs, children)
          @object = object
          @role = role
          @original_role = original_role
          @language = attrs[:lang]
          @alternative_text = attrs[:alt]
          @expansion_text = attrs[:expansion]
          @actual_text = attrs[:actual]
          @title = attrs[:title]
          @children = children
        end

        # The object number of the underlying structure element dictionary.
        def oid
          @object.oid
        end

        # The generation number of the underlying structure element dictionary.
        def gen
          @object.gen
        end

        # The object position as "oid,gen" string.
        def position
          "#{oid},#{gen}"
        end

        # Recursively yields this element and all descendant structure elements in structure-tree
        # (reading) order.
        def each_descendant(&block)
          return to_enum(__method__) unless block_given?
          yield self
          children.each do |child|
            child.each_descendant(&block) if child.is_a?(Element)
          end
          self
        end

        # Returns the pages associated with the element's contents, in structure-tree order and
        # without duplicates.
        def pages
          result = []
          each_descendant do |elem|
            elem.children.each do |child|
              page = child.page if child.respond_to?(:page)
              result << page if page && !result.include?(page)
            end
          end
          result
        end

        # Returns the concatenated text of all contents associated with the element, in
        # structure-tree order.
        #
        # If the element has an /ActualText entry, that text is returned instead.
        def text
          return actual_text if actual_text
          parts = []
          collect_text(parts)
          parts.join
        end

        def inspect #:nodoc:
          "#<#{self.class.name} oid=#{oid} role=#{role.inspect} children=#{children.size}>"
        end

        protected

        # Collects the text of this element and its children in structure-tree order.
        def collect_text(parts)
          children.each do |child|
            case child
            when Element then child.collect_text(parts)
            when MarkedContent then parts << child.text
            end
          end
        end

      end

      # Represents the content referenced by an object reference dictionary (/Type /OBJR).
      class ObjectReferenceContent

        # The wrapped HexaPDF::Type::ObjectReference dictionary.
        attr_reader :object

        # The referenced PDF object (e.g. an annotation), or +nil+ if it could not be resolved.
        attr_reader :referenced_object

        # The page associated with the referenced object, or +nil+.
        attr_reader :page

        # Creates a new ObjectReferenceContent.
        def initialize(object, referenced_object, page)
          @object = object
          @referenced_object = referenced_object
          @page = page
        end

      end

      # The result of reading the logical structure.
      class Result

        # The root structure elements in structure-tree order.
        attr_reader :elements

        # The Array of Diagnostic instances found while reading.
        attr_reader :diagnostics

        # The mapping from object positions ("oid,gen" strings) to Element instances.
        attr_reader :elements_by_position

        # Creates a new Result.
        def initialize(elements, diagnostics, elements_by_position)
          @elements = elements
          @diagnostics = diagnostics
          @elements_by_position = elements_by_position
        end

        # Returns +true+ if there are no error diagnostics.
        def valid?
          diagnostics.none?(&:error?)
        end

        # All diagnostics with severity +:error+.
        def errors
          diagnostics.select(&:error?)
        end

        # All diagnostics with severity +:warning+.
        def warnings
          diagnostics.select(&:warning?)
        end

      end

      # Reads the logical structure of the given document and returns a Result.
      #
      # If the document has no structure tree root, an empty result is returned.
      def self.call(doc)
        new(doc).result
      end

      # Returns the Result of reading the document's logical structure.
      attr_reader :result

      def initialize(doc) #:nodoc:
        @doc = doc
        @diagnostics = []
        @elements = {}
        @building = Set.new
        @elements_by_position = {}
        @parent_entries = {}
        @page_by_oid = {}
        @marks_for_page = {}
        @claimed_marks = Set.new
        execute
      end

      private

      # Performs the reading of the structure tree.
      def execute
        root = @doc.deref(@doc.catalog[:StructTreeRoot])
        if root.nil?
          @result = Result.new([], [], {})
          return
        end
        unless root.kind_of?(HexaPDF::Dictionary)
          diagnose(:error, "StructTreeRoot is not a dictionary", root)
          @result = Result.new([], @diagnostics, {})
          return
        end

        @role_map = @doc.deref(root[:RoleMap])

        collect_pages
        build_parent_tree(root)

        roots = Array(root[:K]).filter_map {|kid| process_structure_element(kid) }
        @result = Result.new(roots, @diagnostics, @elements_by_position)
      end

      # Dereferences the given object and, if necessary, wraps a plain Ruby Hash in the matching
      # HexaPDF Dictionary subclass according to its /Type entry. Returns +nil+ if the object is
      # not a dictionary.
      def normalize_dict(obj)
        obj = @doc.deref(obj)
        if obj.kind_of?(HexaPDF::Dictionary)
          obj
        elsif obj.kind_of?(Hash)
          @doc.wrap(obj)
        end
      end

      # Returns the raw value of a dictionary entry without triggering field conversion or
      # default-value insertion (which could modify the document).
      def raw_value(dict, key)
        value = dict.value[key]
        value.is_a?(HexaPDF::Reference) ? @doc.object(value) : value
      end

      # Indexes all pages by their object number so that object numbers appearing in the parent
      # tree can be resolved to pages.
      def collect_pages
        @doc.pages.each {|page| @page_by_oid[page.oid] = page }
      rescue StandardError
        # A broken page tree should not prevent structure reading
      end

      # Reads the ParentTree. For each entry the key is the /StructParents value of a page or
      # Form XObject and the value is an array indexed by MCID (or by position for OBJR items)
      # containing either the parent structure element directly, an MCR dictionary or an OBJR
      # dictionary.
      def build_parent_tree(root)
        parent_tree = @doc.deref(root[:ParentTree])
        return if parent_tree.nil?
        unless parent_tree.kind_of?(HexaPDF::Dictionary) &&
            (parent_tree.key?(:Nums) || parent_tree.key?(:Kids))
          diagnose(:warning, "ParentTree is not a number tree", parent_tree)
          return
        end

        parent_tree = @doc.wrap(parent_tree, type: HexaPDF::NumberTreeNode)
        parent_tree.each_entry do |key, value|
          value = @doc.deref(value)
          next unless value.kind_of?(Array)
          value.each_with_index do |item, index|
            item = normalize_dict(item)
            next unless item
            # The index in the parent tree array equals the MCID for marked-content items.
            (@parent_entries[key] ||= []) << [index, item]
          end
        end
      rescue StandardError => e
        diagnose(:warning, "ParentTree could not be read: #{e.message}", root)
      end

      # Converts a structure element dictionary into an Element, resolving its role and
      # processing its /K children.
      #
      # +inherited_page+ is the nearest /Pg entry found on an ancestor structure element and is
      # used if neither the content reference nor the element itself specify a page (PDF2.0
      # s14.7.5.4).
      def process_structure_element(obj, inherited_page = nil)
        obj = normalize_dict(obj)
        unless obj
          diagnose(:error, "Structure element child is not a dictionary", @doc.deref(obj))
          return nil
        end

        if @building.include?(obj.data)
          diagnose(:error, "Structure tree contains a cycle", obj)
          return nil
        end
        if @elements.key?(obj.data)
          diagnose(:error, "Structure element is referenced more than once", obj)
          return @elements[obj.data]
        end
        if (type = raw_value(obj, :Type)) && type != :StructElem
          diagnose(:warning, "Structure element has unexpected /Type #{type.inspect}", obj)
        end

        original_role = obj[:S]
        unless original_role.kind_of?(Symbol)
          diagnose(:error, "Structure element is missing its role (/S entry)", obj)
          return nil
        end
        role = resolve_role(original_role, obj)

        attrs = {
          lang: obj[:Lang], alt: obj[:Alt], expansion: obj[:E],
          actual: obj[:ActualText], title: obj[:T],
        }
        page = inherited_page || @doc.deref(obj[:Pg])

        @building.add(obj.data)
        children = process_kids(Array(obj[:K]), obj, page)
        @building.delete(obj.data)

        element = Element.new(obj, role, original_role, attrs, children)
        @elements[obj.data] = element
        @elements_by_position["#{obj.oid},#{obj.gen}"] = element if obj.oid != 0
        element
      end

      # Resolves a role through the RoleMap, detecting chains and cycles. Returns the final
      # standard role, or the original role if it is not mapped. A self-referencing or cyclic
      # mapping is reported and resolution stops there.
      def resolve_role(role, source_obj)
        return role unless @role_map
        seen = {role => true}
        current = role
        1000.times do
          mapped = @doc.deref(@role_map[current])
          return current unless mapped.kind_of?(Symbol)
          if seen.key?(mapped)
            diagnose(:error,
                     "Cyclic RoleMap mapping detected for role #{role.inspect} " \
                     "(#{current.inspect} maps to #{mapped.inspect})", source_obj)
            return current
          end
          seen[mapped] = true
          current = mapped
        end
        role
      end

      # Processes the /K entries of a structure element.
      def process_kids(kids, parent_elem, inherited_page)
        kids.each_with_object([]) do |raw_kid, result|
          kid = @doc.deref(raw_kid)
          if kid.kind_of?(Integer)
            mark = marked_content_for(parent_elem, mcid: kid, mcr: nil,
                                      inherited_page: inherited_page)
            result << mark if mark
          elsif (dict = normalize_dict(kid))
            type = raw_value(dict, :Type)
            if type == :MCR || (type.nil? && dict.value[:MCID])
              mark = marked_content_for(parent_elem, mcid: dict[:MCID], mcr: dict,
                                        inherited_page: inherited_page)
              result << mark if mark
            elsif type == :OBJR || (type.nil? && dict.value[:Obj])
              result << object_reference(dict, parent_elem, inherited_page)
            elsif type == :StructElem || dict.value[:S]
              element = process_structure_element(dict, inherited_page)
              result << element if element
            else
              diagnose(:error, "Unknown structure element child dictionary", dict)
            end
          else
            diagnose(:error,
                     kid.nil? ? "Invalid structure element child" :
                       "Invalid structure element child of type #{kid.class}",
                     parent_elem)
          end
        end
      end

      # Resolves a marked-content reference (integer MCID or MCR dictionary) to the actual marked
      # content on the referenced page, checking ownership and the parent tree.
      def marked_content_for(struct_elem, mcid:, mcr:, inherited_page:)
        location = content_location(mcr, struct_elem)
        unless mcid.kind_of?(Integer)
          diagnose(:error, "Marked-content reference has no valid MCID", location)
          return nil
        end

        page = resolve_page(struct_elem, mcr, inherited_page)
        return nil unless page

        stream = nil
        if mcr && mcr[:Stm]
          stream = @doc.deref(mcr[:Stm])
          unless stream.is_a?(HexaPDF::Type::Form)
            diagnose(:error, "MCR /Stm is not a Form XObject", mcr)
            stream = nil
          end
        end
        if mcr && mcr[:StmOwn] && stream && @doc.deref(mcr[:StmOwn]) != stream
          diagnose(:warning, "MCR /StmOwn does not match /Stm", mcr)
        end

        marks = marks_for_page(page)
        stream_key = stream&.oid || :page
        mark = marks[stream_key]&.[](mcid)
        unless mark
          location_desc = stream ? "Form XObject object #{stream.oid}" : "page object #{page.oid}"
          diagnose(:error, "MCID #{mcid} not found in the content stream of #{location_desc}",
                   location)
          return nil
        end

        unless @claimed_marks.add?([page.oid, stream_key, mcid])
          location_desc = if stream
                            "Form XObject object #{stream.oid} on page object #{page.oid}"
                          else
                            "page object #{page.oid}"
                          end
          diagnose(:error,
                   "Content (MCID #{mcid} in #{location_desc}) is associated with more than " \
                   "one structure element", location)
        end

        verify_parent_tree(page, stream, mcid, struct_elem, mcr)
        mark
      end

      # Returns the PDF object whose position best identifies a marked-content reference in a
      # diagnostic: the (usually indirect) MCR dictionary itself, otherwise the owning structure
      # element.
      def content_location(mcr, struct_elem)
        (mcr && mcr.indirect?) ? mcr : struct_elem
      end

      # Determines the page of a marked-content reference. The page is taken from the MCR
      # dictionary's /Pg entry, falling back to the structure element's /Pg entry and then to the
      # /Pg entry inherited from an ancestor structure element.
      def resolve_page(struct_elem, mcr, inherited_page)
        page = @doc.deref(raw_value(mcr, :Pg)) if mcr
        page ||= @doc.deref(raw_value(struct_elem, :Pg))
        page ||= inherited_page
        page = @doc.deref(page) if page.is_a?(HexaPDF::Reference)
        if page.nil?
          diagnose(:error,
                   "No page (/Pg) specified for marked-content reference of structure element",
                   mcr || struct_elem)
          return nil
        end
        unless page.is_a?(HexaPDF::Type::Page)
          diagnose(:error, "Referenced /Pg object is not a page", mcr || struct_elem)
          return nil
        end
        unless @page_by_oid.key?(page.oid)
          diagnose(:error,
                   "Referenced page object #{page.oid} is not part of the page tree (missing page)",
                   mcr || struct_elem)
          return nil
        end
        page
      end

      # Cross-checks a marked-content reference against the ParentTree by looking up the page's
      # or Form XObject's /StructParents value and the MCID.
      def verify_parent_tree(page, stream, mcid, struct_elem, mcr)
        return if @parent_entries.empty?
        struct_parents = stream ? stream[:StructParents] : page[:StructParents]
        if struct_parents.nil?
          diagnose(:warning,
                   "#{stream ? 'Form XObject' : 'Page'} object #{(stream || page).oid} has no " \
                   "/StructParents entry although a ParentTree is present", mcr || struct_elem)
          return
        end

        entries = @parent_entries[struct_parents]
        if entries.nil?
          diagnose(:warning,
                   "ParentTree has no entry for /StructParents #{struct_parents}",
                   mcr || struct_elem)
          return
        end

        # For marked-content items the position in the parent tree array equals the MCID.
        indexed = entries.select {|index, _item| index == mcid }.map(&:last)
        if indexed.empty?
          diagnose(:warning,
                   "ParentTree entry for /StructParents #{struct_parents} has no item for " \
                   "MCID #{mcid}", mcr || struct_elem)
          return
        end

        matches_parent = indexed.any? do |item|
          if raw_value(item, :S) && !item.value[:MCID] && !item.value[:Obj]
            item.data == struct_elem.data
          elsif raw_value(item, :Type) == :MCR || item.value[:MCID]
            if mcr
              same_mcr?(item, mcr)
            else
              referenced_from_elem?(item, struct_elem)
            end
          else
            false
          end
        end
        return if matches_parent
        diagnose(:warning,
                 "ParentTree entry for /StructParents #{struct_parents}, MCID #{mcid} does not " \
                 "refer back to this structure element", mcr || struct_elem)
      end

      # Returns +true+ if two MCR dictionaries describe the same marked content (same MCID, page
      # and stream). Indirect objects are compared by object identity first.
      def same_mcr?(first, second)
        return true if first.indirect? && second.indirect? && first.data == second.data
        first[:MCID] == second[:MCID] &&
          @doc.deref(raw_value(first, :Pg)) == @doc.deref(raw_value(second, :Pg)) &&
          @doc.deref(raw_value(first, :Stm)) == @doc.deref(raw_value(second, :Stm))
      end

      # Returns +true+ if the given MCR dictionary (or an integer MCID) is a content item of the
      # structure element.
      def referenced_from_elem?(mcr_item, struct_elem)
        target_mcid = mcr_item[:MCID]
        target_page = @doc.deref(raw_value(mcr_item, :Pg))
        target_stm = @doc.deref(raw_value(mcr_item, :Stm))
        Array(struct_elem[:K]).any? do |kid|
          kid = @doc.deref(kid)
          if kid.kind_of?(Integer)
            kid == target_mcid && target_stm.nil?
          elsif (kid_dict = normalize_dict(kid))
            if (kid_mcid = kid_dict[:MCID])
              kid_mcid == target_mcid &&
                (target_page.nil? || @doc.deref(raw_value(kid_dict, :Pg)).nil? ||
                  @doc.deref(raw_value(kid_dict, :Pg)) == target_page) &&
                (target_stm.nil? || @doc.deref(raw_value(kid_dict, :Stm)) == target_stm)
            else
              false
            end
          else
            false
          end
        end
      end

      # Processes an object reference dictionary (/OBJR).
      def object_reference(objr, struct_elem, inherited_page)
        referenced = @doc.deref(objr[:Obj])
        diagnose(:error, "OBJR references a missing object", objr) if referenced.nil?

        page = @doc.deref(raw_value(objr, :Pg)) || @doc.deref(raw_value(struct_elem, :Pg)) ||
          inherited_page
        unless page.nil? || page.is_a?(HexaPDF::Type::Page)
          diagnose(:warning, "OBJR /Pg is not a page object", objr)
          page = nil
        end
        if page && !@page_by_oid.key?(page.oid)
          diagnose(:warning,
                   "OBJR references page object #{page.oid} that is not part of the page tree",
                   objr)
          page = nil
        end
        verify_object_parent_tree(page, objr, struct_elem)
        ObjectReferenceContent.new(objr, referenced, page)
      end

      # Cross-checks an OBJR against the ParentTree of the associated page.
      def verify_object_parent_tree(page, objr, struct_elem)
        return if @parent_entries.empty?
        struct_parents = page&.[](:StructParents)
        if struct_parents.nil?
          diagnose(:warning,
                   "Page #{page&.oid || '—'} has no /StructParents entry although a ParentTree " \
                   "is present", struct_elem)
          return
        end
        entries = @parent_entries[struct_parents]
        return if entries.nil?
        referenced = @doc.deref(objr[:Obj])
        found = entries.any? do |_index, item|
          if item.indirect? && objr.indirect?
            item.data == objr.data
          else
            raw_value(item, :Type) == :OBJR && @doc.deref(item[:Obj]).equal?(referenced)
          end
        end
        return if found
        diagnose(:warning,
                 "ParentTree entry for /StructParents #{struct_parents} does not contain the " \
                 "OBJR dictionary", objr)
      end

      # Returns and memoizes the mapping ":page or Form XObject object number" -> "MCID" ->
      # MarkedContent for all marked-content sequences of the given page, including sequences
      # inside Form XObjects referenced by the page.
      def marks_for_page(page)
        @marks_for_page[page.data] ||= begin
          collector = MarkedContentCollector.new(@doc, page)
          # Process manually instead of via Page#process_contents because the latter would assign
          # an empty resource dictionary to the page if none is present (a modification).
          collector.resources = page[:Resources]
          begin
            HexaPDF::Content::Parser.parse(page.contents, collector)
          rescue StandardError => e
            diagnose(:warning,
                     "Content stream of page object #{page.oid} could not be fully processed: " \
                     "#{e.message}", page)
          end
          collector.marks
        end
      end

      # Adds a diagnostic with the object position of the given PDF object.
      def diagnose(severity, message, object = nil)
        object = @doc.deref(object) if object
        oid = gen = nil
        if object.is_a?(HexaPDF::Object) && object.oid != 0
          oid = object.oid
          gen = object.gen
        end
        @diagnostics << Diagnostic.new(severity, message, oid: oid, gen: gen)
      end

      # Processor that extracts the text of marked-content sequences, associating each sequence
      # with its MCID. Sequences inside Form XObjects are tracked separately (keyed by the form's
      # object number) so that MCRs with a /Stm entry can be resolved.
      class MarkedContentCollector < Content::Processor

        # Returns the mapping ":page or Form XObject object number" -> "MCID" -> MarkedContent.
        attr_reader :marks

        def initialize(doc, page)
          super(nil)
          @doc = doc
          @page = page
          @marks = Hash.new {|h, k| h[k] = {} }
          @open = [] # entries: [mcid, text buffer or nil]
          @forms = []
        end

        def begin_marked_content(_tag) #:nodoc:
          @open.push([nil, nil])
        end

        def begin_marked_content_with_property_list(_tag, properties) #:nodoc:
          @open.push([extract_mcid(properties), +''.b])
        end

        def end_marked_content #:nodoc:
          return if @open.empty?
          mcid, text = @open.pop
          return unless mcid
          key = @forms.last&.oid || :page
          @marks[key][mcid] = MarkedContent.new(mcid, @page, @forms.last, text.dup.freeze)
        end

        def show_text(data) #:nodoc:
          append_text(safe_decode_text(data))
        end

        def move_text_next_line_and_show_text(data) #:nodoc:
          append_text(safe_decode_text(data))
        end

        def set_spacing_move_text_next_line_and_show_text(_ws, _cs, data) #:nodoc:
          append_text(safe_decode_text(data))
        end

        def show_text_with_positioning(data) #:nodoc:
          append_text(safe_decode_text(data))
        end

        # Tracks the current Form XObject in addition to the default processing so that MCIDs in
        # the form's content stream are associated with the right stream.
        def paint_xobject(name)
          xobject = resources&.xobject(name)
          return unless xobject
          if xobject[:Subtype] == :Form
            @forms.push(xobject)
            super
            @forms.pop
          else
            super
          end
        rescue HexaPDF::Error
          # Missing or invalid resource: ignore
        end

        private

        # Decodes text like Processor#decode_text but ignores text runs that cannot be decoded
        # (e.g. because of a missing glyph) instead of aborting the whole page processing.
        def safe_decode_text(data)
          decode_text(data)
        rescue StandardError
          ''
        end

        # Attributes text to the innermost open marked-content sequence having an MCID.
        def append_text(text)
          entry = nil
          @open.reverse_each {|e| (entry = e; break) if e[0] }
          entry[1] << text if entry
        end

        # Resolves the MCID of a BDC property list, which may be an inline dictionary or a name
        # referencing the resource dictionary's /Properties dictionary.
        def extract_mcid(properties)
          if properties.is_a?(Symbol)
            properties = resources&.[](:Properties)&.[](properties)
            properties = @doc.deref(properties) if properties
          end
          properties[:MCID] if properties.respond_to?(:[]) && properties[:MCID].kind_of?(Integer)
        end

      end

    end

  end
end
