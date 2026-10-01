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
require 'hexapdf/name_tree_node'
require 'hexapdf/number_tree_node'
require 'hexapdf/content/parser'
require 'hexapdf/content/processor'
require 'hexapdf/type/struct_tree_root'
require 'hexapdf/type/struct_elem'
require 'hexapdf/type/marked_content_reference'
require 'hexapdf/type/object_reference'

module HexaPDF
  class Document

    # This class provides a read-only interface for reading the logical structure (a.k.a. tagged
    # PDF) of a PDF document, as defined by the /StructTreeRoot entry of the document catalog.
    #
    # The structure is read in logical (document) order as encoded in the structure tree itself -
    # not in the order things appear on the pages or in the content streams and not sorted by
    # position. Content is associated with structure elements through the three possible kinds of
    # kids:
    #
    # * Integer MCIDs (marked content sequences directly on a page),
    # * MCR dictionaries (marked content sequences, possibly inside Form XObjects),
    # * OBJR dictionaries (references to entire PDF objects like annotations).
    #
    # Structure element roles are resolved through the /RoleMap (and, for PDF 2.0, namespace
    # /RoleMapNS) before being returned.
    #
    # Whenever the structure tree or the backing structures (ParentTree, page contents) contain
    # invalid or conflicting information, diagnostic Problem objects are collected via #problems
    # and all parts that can still be read are retained.
    #
    # All operations are strictly read-only: reading the structure never adds, deletes or changes
    # PDF objects (the usual lazy dereferencing of indirect references notwithstanding).
    #
    # See: PDF2.0 s14.7
    class Structure

      # Represents one diagnostic message about a problem found while reading the structure.
      #
      # Attributes:
      #
      # code::     A Symbol identifying the kind of problem.
      # message::  A human readable description.
      # location:: A human readable description of where the problem was found (e.g. "struct elem
      #            12,0").
      # object::   The involved HexaPDF::Object, if any.
      Problem = Struct.new(:code, :message, :location, :object) do
        def to_s # :nodoc:
          location ? "#{message} (#{location})" : message
        end
      end

      # Represents a structure element of the structure tree.
      #
      # The top-level element returned by Structure#root_element may be a synthetic element
      # representing the structure tree root itself if the structure tree root has more than one
      # kid; in that case #source is the HexaPDF::Type::StructTreeRoot and #role is
      # +:StructTreeRoot+.
      class Element
        # The wrapped HexaPDF::Type::StructElem dictionary (or the structure tree root for the
        # synthetic top-level element).
        attr_reader :source

        # The role (Symbol) after resolving it through all applicable role maps.
        attr_reader :role

        # The original role (Symbol) as stored in the /S entry, before role map resolution.
        attr_reader :original_role

        # The language (/Lang entry), or +nil+.
        attr_reader :lang

        # The alternative text (/Alt entry), or +nil+.
        attr_reader :alt

        # The abbreviation expansion text (/E entry), or +nil+.
        attr_reader :expanded

        # The actual text (/ActualText entry), or +nil+.
        attr_reader :actual_text

        # The title (/T entry), or +nil+.
        attr_reader :title

        # The ordered child nodes: Element, MarkedContent or ObjectReference instances.
        attr_reader :children

        # The page (HexaPDF::Type::Page) specified by the element's /Pg entry, or +nil+.
        attr_reader :page

        # The HexaPDF::Type::Page instances associated with this element and its descendants, in
        # tree order and without duplicates.
        attr_reader :pages

        # The MarkedContent/ObjectReference items associated with this element and its
        # descendants, in tree order.
        attr_reader :content_items

        def initialize # :nodoc:
          @source = nil
          @role = @original_role = @lang = @alt = @expanded = nil
          @actual_text = @title = nil
          @children = []
          @page = nil
          @pages = []
          @content_items = []
        end

        # Iterates over all descendant Element instances (not yielding +self+) in tree order.
        def each_descendant(&block)
          return to_enum(__method__) unless block_given?
          children.each do |child|
            next unless child.kind_of?(Element)
            yield(child)
            child.each_descendant(&block)
          end
          self
        end

        # Returns the text of all marked content sequences associated with this element and its
        # descendants, concatenated in tree order.
        #
        # If the element has an /ActualText entry, it is returned instead.
        def text
          return actual_text if actual_text
          content_items.filter_map do |item|
            item.kind_of?(MarkedContent) ? item.text : nil
          end.join
        end
      end

      # Common functionality for content associated with a structure element.
      module ContentItem
        # The page (HexaPDF::Type::Page) on which the content appears, or +nil+ if unknown.
        attr_accessor :page

        # The zero-based index of the page in the page tree, or +nil+ if unknown.
        attr_accessor :page_index
      end

      # Represents a marked-content sequence associated with a structure element (an integer MCID
      # kid or an MCR dictionary).
      class MarkedContent
        include ContentItem

        # The marked content identifier.
        attr_accessor :mcid

        # The Form XObject (HexaPDF::Type::Form) containing the marked content, or +nil+ if it is
        # directly in a page content stream.
        attr_accessor :stream

        # The /StmOwn object (e.g. an annotation), or +nil+.
        attr_accessor :stream_owner

        # The extracted text of the marked content sequence, in content stream order.
        attr_accessor :text

        def initialize # :nodoc:
          @mcid = nil
          @stream = nil
          @stream_owner = nil
          @text = ''.b
        end

        # Returns +true+ if the marked content is inside a Form XObject.
        def in_form?
          !@stream.nil?
        end
      end

      # Represents an object reference (OBJR) associated with a structure element.
      class ObjectReference
        include ContentItem

        # The referenced PDF object (already dereferenced).
        attr_accessor :object

        # The backing HexaPDF::Type::ObjectReference dictionary.
        attr_accessor :source
      end

      # Creates a new Structure object for the given PDF document.
      def initialize(document)
        @document = document
        @problems = []
      end

      # The document's structure tree root (HexaPDF::Type::StructTreeRoot), or +nil+ if the
      # document has no structure tree.
      def struct_tree_root
        catalog = @document.deref(@document.trailer[:Root])
        return nil unless catalog
        root = @document.deref(catalog[:StructTreeRoot])
        return nil if root.nil?
        as_type(root, HexaPDF::Type::StructTreeRoot)
      rescue StandardError => e
        problem(:invalid_struct_tree_root, "Invalid structure tree root: #{e.message}")
        nil
      end

      # :call-seq:
      #   structure.root_element -> element or nil
      #
      # Returns the top-level structure element, or +nil+ if the document has no structure tree or
      # it contains no structure element.
      #
      # Any problems encountered are collected and can be retrieved via #problems; #valid? reports
      # whether there were any.
      def root_element
        @problems = []
        @root = struct_tree_root
        return nil unless @root

        @role_maps = [@root[:RoleMap]].compact
        @content_owner = {}     # content key -> [Element, item, Location]
        @parent_entries = nil
        @page_indices = nil
        @marked_content_index = nil
        @seen_struct_elems = Set.new

        kids = Array(@root.key?(:K) ? @root[:K] : nil)
        top_elements = kids.each_with_index.filter_map do |kid, index|
          build_element(kid, nil, Location.new("struct tree root kid ##{index}", @root))
        end
        return nil if top_elements.empty?

        element = if top_elements.length == 1
                    top_elements.first
                  else
                    synthetic = Element.new
                    synthetic.instance_variable_set(:@source, @root)
                    synthetic.instance_variable_set(:@role, :StructTreeRoot)
                    synthetic.instance_variable_set(:@original_role, :StructTreeRoot)
                    synthetic.instance_variable_set(:@children, top_elements)
                    collect_pages_and_content(synthetic)
                    synthetic
                  end

        verify_parent_tree
        element
      end

      # Returns all problems collected during the last invocation of #root_element.
      def problems
        @problems ||= []
      end

      # Returns +true+ if the last invocation of #root_element did not find any problems.
      def valid?
        problems.empty?
      end

      private

      # Describes the location of an object within the structure tree for diagnostics.
      Location = Struct.new(:description, :object) do
        def to_s
          if object.nil? || !object.respond_to?(:indirect?)
            description
          elsif object.indirect?
            "#{description} (object #{object.oid},#{object.gen})"
          else
            "#{description} (direct object)"
          end
        end
      end

      # Adds a diagnostic problem.
      def problem(code, message, location: nil, object: nil)
        object ||= location&.object
        if location
          loc = location.to_s
        elsif object.respond_to?(:oid) && object.indirect?
          loc = "object #{object.oid},#{object.gen}"
        end
        @problems << Problem.new(code, message, loc, object)
      end

      # Builds an Element (and its descendants) from a StructElem dictionary.
      def build_element(kid, inherited_page, location)
        struct_elem = @document.deref(kid)
        struct_elem = @document.wrap(struct_elem) if struct_elem.kind_of?(::Hash)
        unless struct_elem.kind_of?(HexaPDF::Dictionary) && struct_elem.key?(:S)
          problem(:invalid_kid, "Expected a structure element but found #{describe(struct_elem)}",
                  location: location)
          return nil
        end
        struct_elem = as_type(struct_elem, HexaPDF::Type::StructElem)

        if struct_elem.indirect?
          if @seen_struct_elems.include?([struct_elem.oid, struct_elem.gen])
            problem(:duplicate_reference,
                    "Structure element is referenced more than once in the structure tree",
                    location: Location.new("duplicate reference to structure element",
                                          struct_elem))
            return nil
          end
          @seen_struct_elems << [struct_elem.oid, struct_elem.gen]
        end

        element = Element.new
        element.instance_variable_set(:@source, struct_elem)
        element.instance_variable_set(:@original_role, struct_elem[:S])
        element.instance_variable_set(:@role, resolve_role(struct_elem[:S], struct_elem))
        element.instance_variable_set(:@lang, struct_elem[:Lang])
        element.instance_variable_set(:@alt, struct_elem[:Alt])
        element.instance_variable_set(:@expanded, struct_elem[:E])
        element.instance_variable_set(:@actual_text, struct_elem[:ActualText])
        element.instance_variable_set(:@title, struct_elem[:T])

        page = find_page(struct_elem, inherited_page, location)
        element.instance_variable_set(:@page, page)

        Array(struct_elem.key?(:K) ? struct_elem[:K] : nil).each_with_index do |child, index|
          build_child(element, child, page,
                      Location.new("struct elem kid ##{index} of", struct_elem))
        end

        collect_pages_and_content(element)
        element
      rescue StandardError => e
        problem(:invalid_struct_elem, "Could not read structure element: #{e.message}",
                location: location)
        nil
      end

      # Builds a single child node of a structure element and adds it to the element.
      def build_child(element, child, inherited_page, location)
        resolved = @document.deref(child)
        resolved = @document.wrap(resolved) if resolved.kind_of?(::Hash)
        case resolved
        when Integer
          create_marked_content(element, resolved, inherited_page, nil, nil, location)
        when HexaPDF::Dictionary
          case resolved[:Type]
          when :MCR
            build_mcr(element, resolved, inherited_page, location)
          when :OBJR
            build_objr(element, resolved, inherited_page, location)
          else
            if resolved.key?(:S) || resolved[:Type] == :StructElem
              sub = build_element(child, inherited_page, location)
              element.children << sub if sub
            else
              problem(:unknown_kid,
                      "Unknown structure kid dictionary of type #{resolved[:Type].inspect}",
                      location: location)
            end
          end
        else
          problem(:invalid_kid, "Invalid structure kid of class #{describe(resolved)}",
                  location: location)
        end
      rescue StandardError => e
        problem(:invalid_kid, "Could not read structure kid: #{e.message}", location: location)
        nil
      end

      # Handles an MCR dictionary kid.
      def build_mcr(element, dict, inherited_page, location)
        mcr = as_type(dict, HexaPDF::Type::MarkedContentReference)
        mcid = mcr[:MCID]
        unless mcid.is_a?(Integer)
          problem(:invalid_mcid, "MCR has invalid or missing /MCID entry", location: location)
          return
        end

        page = mcr_page(mcr, inherited_page, location)
        stream = @document.deref(mcr[:Stm])
        stream = as_type(stream, HexaPDF::Type::Form) if stream
        stream_owner = @document.deref(mcr[:StmOwn])
        create_marked_content(element, mcid, page, stream, stream_owner, location)
      end

      # Handles an OBJR dictionary kid.
      def build_objr(element, dict, inherited_page, location)
        objr = as_type(dict, HexaPDF::Type::ObjectReference)
        referenced = @document.deref(objr[:Obj])
        if referenced.nil?
          problem(:missing_object, "OBJR references a missing object", location: location)
          return
        end

        item = ObjectReference.new
        item.source = objr
        item.object = referenced
        if (page = objr[:Pg] || inherited_page)
          item.page = as_type(page, HexaPDF::Type::Page)
          item.page_index = page_index(item.page)
        end
        claim_content(item, element, location, [:objr, object_identity(referenced)])
        element.children << item
      end

      # Creates a MarkedContent item, verifies it against the content streams and claims it for
      # the element.
      def create_marked_content(element, mcid, page, stream, stream_owner, location)
        item = MarkedContent.new
        item.mcid = mcid
        item.stream = stream
        item.stream_owner = stream_owner
        item.page = page
        item.page_index = page ? page_index(page) : nil

        key = content_key(page, stream, mcid)
        if page
          index_entry = marked_content_index[key]
          if index_entry
            item.text = index_entry[:text]
          elsif stream
            problem(:missing_mcid,
                    "MCID #{mcid} not found in Form XObject (object #{stream.oid},#{stream.gen}) " \
                    "on page (object #{page.oid},#{page.gen})", location: location)
          else
            problem(:missing_mcid,
                    "MCID #{mcid} not found in content stream of page (object #{page.oid}," \
                    "#{page.gen})", location: location)
          end
        else
          problem(:missing_page,
                  "No page associated with marked content with MCID #{mcid}", location: location)
        end

        claim_content(item, element, location, key)
        element.children << item
      end

      # Registers the content item as owned by the element and reports duplicate or conflicting
      # associations.
      def claim_content(item, element, location, key)
        previous = @content_owner[key]
        if previous && previous[0] != element
          problem(:content_conflict,
                  "Content #{format_key(key)} is already associated with another structure " \
                  "element", location: location)
        elsif previous
          problem(:duplicate_reference,
                  "Content #{format_key(key)} is referenced more than once", location: location)
        else
          @content_owner[key] = [element, item, location]
        end
      end

      # Key identifying a marked content sequence.
      def content_key(page, stream, mcid)
        [:mcid, object_identity(page), object_identity(stream), mcid]
      end

      # Human readable form of a content key for diagnostics.
      def format_key(key)
        kind, page_id, stream_id, mcid = key
        if kind == :objr
          "OBJR->#{format_id(page_id)}"
        elsif stream_id && stream_id != -1
          "MCID #{mcid} in Form XObject #{format_id(stream_id)} on page #{format_id(page_id)}"
        else
          "MCID #{mcid} on page #{format_id(page_id)}"
        end
      end

      def format_id(identity)
        identity.is_a?(Array) ? "object #{identity[0]},#{identity[1]}" : identity.inspect
      end

      # Identity tuple of an (indirect) object.
      def object_identity(object)
        object.respond_to?(:indirect?) && object.indirect? ? [object.oid, object.gen] : -1
      end

      # Returns +true+ if the object is a page dictionary (a wrapped Page or a /Type /Page dict).
      def page_object?(object)
        object.is_a?(HexaPDF::Type::Page) ||
          (object.kind_of?(HexaPDF::Dictionary) && object.value[:Type] == :Page)
      end

      # Determines the page of an MCR, using the MCR's /Pg entry, the /Stm's /Pg entry or the
      # inherited page.
      def mcr_page(mcr, inherited_page, location)
        if mcr.value.key?(:Pg)
          page = @document.deref(mcr.value[:Pg])
          if page.nil?
            problem(:missing_page, "MCR /Pg entry references a missing page", location: location)
            return inherited_page
          elsif !page_object?(page)
            problem(:invalid_page, "MCR /Pg entry does not refer to a page", location: location,
                    object: page)
            return inherited_page
          end
          return as_type(page, HexaPDF::Type::Page)
        elsif (stm = @document.deref(mcr[:Stm])) && stm.respond_to?(:key?) && stm.key?(:Pg) &&
            stm[:Pg]
          return as_type(stm[:Pg], HexaPDF::Type::Page)
        end
        inherited_page
      rescue StandardError => e
        problem(:invalid_page, "Invalid MCR /Pg entry: #{e.message}", location: location)
        inherited_page
      end

      # Determines the page associated with a structure element, falling back to the inherited
      # (nearest ancestor) page.
      def find_page(struct_elem, inherited_page, location)
        return inherited_page unless struct_elem.value.key?(:Pg)
        page = @document.deref(struct_elem.value[:Pg])
        if page.nil?
          problem(:missing_page, "Structure element /Pg entry references a missing page",
                  location: location)
          return inherited_page
        elsif !page_object?(page)
          problem(:invalid_page, "Structure element /Pg entry does not refer to a page",
                  location: location, object: page)
          return inherited_page
        end
        as_type(page, HexaPDF::Type::Page)
      rescue StandardError => e
        problem(:invalid_page, "Invalid /Pg entry: #{e.message}", location: location)
        inherited_page
      end

      # Resolves a role through the document-global /RoleMap and, for PDF 2.0, the element
      # namespace's /RoleMapNS. Cycles are detected and reported.
      def resolve_role(role, struct_elem)
        return role unless role.kind_of?(Symbol)
        maps = @role_maps.dup
        ns = @document.deref(struct_elem[:NS]) rescue nil
        if ns.respond_to?(:key?) && ns.key?(:RoleMapNS)
          maps << @document.deref(ns[:RoleMapNS])
        end

        visited = Set.new
        current = role
        loop do
          visited << current
          mapped = nil
          maps.each do |map|
            candidate = map && map[current]
            mapped ||= candidate if candidate
          end
          return current unless mapped
          if visited.include?(mapped)
            problem(:circular_role_map,
                    "Circular role mapping detected while resolving role #{role.inspect}",
                    object: struct_elem)
            return current
          end
          current = mapped
        end
      rescue StandardError => e
        problem(:invalid_role_map, "Could not resolve role #{role.inspect}: #{e.message}",
                object: struct_elem)
        role
      end

      # Computes the recursive :pages and :content_items lists of an element.
      def collect_pages_and_content(element)
        pages = []
        items = []
        traverse = lambda do |node|
          node.children.each do |child|
            case child
            when Element
              traverse.call(child)
            when MarkedContent, ObjectReference
              items << child
              pages << child.page if child.page && !pages.include?(child.page)
            end
          end
        end
        traverse.call(element)
        pages.unshift(element.page) if element.page && !pages.include?(element.page)
        element.instance_variable_set(:@pages, pages)
        element.instance_variable_set(:@content_items, items)
      end

      # Returns the zero-based index of the page in the page tree, or +nil+.
      def page_index(page)
        @page_indices ||= {}
        @page_indices[object_identity(page)] ||=
          begin
            idx = nil
            @document.pages.each_with_index {|p, i| break idx = i if p.oid == page.oid }
            idx
          rescue StandardError
            nil
          end
      end

      # Builds the index of all marked content sequences of the document: for every page, its
      # content stream and all used Form XObjects are processed.
      def marked_content_index
        @marked_content_index ||= build_marked_content_index
      end

      def build_marked_content_index
        index = {}
        @document.pages.each do |page|
          resources = page[:Resources]
          unless resources
            problem(:invalid_content, "Page has no resources dictionary", object: page)
            next
          end
          scanner = MarkedContentScanner.new(@document, resources, page, page, index)
          HexaPDF::Content::Parser.parse(page.contents, scanner)
        rescue StandardError => e
          problem(:invalid_content, "Could not process page contents: #{e.message}", object: page)
        end
        index
      rescue StandardError => e
        problem(:invalid_page_tree, "Could not traverse page tree: #{e.message}")
        index
      end

      # Loads all entries of the ParentTree into a hash mapping key to value.
      def parent_entries
        @parent_entries ||= load_parent_entries
      end

      def load_parent_entries
        result = {}
        tree = @root[:ParentTree]
        return result unless tree
        tree.each_entry {|key, value| result[key] = value }
        result
      rescue StandardError => e
        problem(:invalid_parent_tree, "Could not read ParentTree: #{e.message}", object: @root)
        result
      end

      # Cross-checks the structure tree against the ParentTree.
      def verify_parent_tree
        has_parent_tree = @root.key?(:ParentTree)
        if !has_parent_tree && !@content_owner.empty?
          problem(:missing_parent_tree,
                  "Document has content associated with structure elements but no ParentTree")
          return
        end
        return unless has_parent_tree

        # Every MCID/OBJR must have a matching ParentTree entry pointing back at its element.
        @content_owner.each do |key, (owner, item, location)|
          parent = parent_entry_for_item(item)
          if parent.nil?
            problem(:missing_parent_entry,
                    "No ParentTree entry found for content #{format_key(key)}", location: location)
            next
          end
          entries = array_like?(parent) ? parent.to_a : [parent]
          matching = entries.any? do |entry|
            entry = @document.deref(entry)
            if item.kind_of?(ObjectReference)
              # For an OBJR the ParentTree entry is the OBJR dictionary itself.
              entry.respond_to?(:[]) && entry[:Type] == :OBJR && same_object?(entry, item.source)
            else
              same_object?(struct_parent(entry), owner.source)
            end
          end
          unless matching
            problem(:parent_tree_mismatch,
                    "ParentTree entry for #{format_key(key)} does not point back to the owning " \
                    "structure element", location: location)
          end
        end

        # ParentTree entries must reference structure elements that are reachable from the root.
        parent_entries.each_value do |value|
          Array(value).each do |entry|
            entry = @document.deref(entry)
            next if entry.nil?
            entry = @document.wrap(entry) if entry.kind_of?(::Hash)
            next unless entry.kind_of?(HexaPDF::Dictionary)
            if entry.key?(:S)
              if entry.indirect? && !@seen_struct_elems.include?([entry.oid, entry.gen])
                problem(:orphaned_parent_entry,
                        "ParentTree references structure element object #{entry.oid}," \
                        "#{entry.gen} that is not reachable from the structure tree root")
              end
            elsif [:MCR, :OBJR].include?(entry[:Type])
              parent = @document.deref(entry[:P])
              if parent.nil? && entry[:Type] == :MCR
                problem(:invalid_parent_entry, "ParentTree MCR entry has a missing /P reference")
              elsif parent && parent.indirect? &&
                  !@seen_struct_elems.include?([parent.oid, parent.gen])
                problem(:orphaned_parent_entry,
                        "ParentTree references structure element object #{parent.oid}," \
                        "#{parent.gen} that is not reachable from the structure tree root")
              end
            else
              problem(:invalid_parent_entry,
                      "ParentTree contains an invalid entry of type #{entry[:Type].inspect}")
            end
          end
        end
      end

      # Returns the raw ParentTree value associated with a content item, or +nil+.
      def parent_entry_for_item(item)
        if item.kind_of?(ObjectReference)
          keys = parent_key_owners(item.object).filter_map {|owner| struct_parent_key(owner) }.uniq
          entries = keys.filter_map {|key| parent_entries[key] }
          return nil if entries.empty?
          return entries.first if entries.length == 1
          entries
        elsif item.stream_owner
          key = struct_parent_key(item.stream_owner)
          key.nil? ? nil : parent_entries[key]
        else
          container = item.stream || item.page
          key = container && container[:StructParents]
          return nil unless key
          arr = parent_entries[key]
          array_like?(arr) ? arr[item.mcid] : nil
        end
      end

      # Returns the potential objects carrying a /StructParent key for an OBJR-referenced object.
      def parent_key_owners(object)
        candidates = [object]
        if object.respond_to?(:key?) && object.key?(:Parent) && object[:Parent]
          candidates << @document.deref(object[:Parent])
        end
        candidates
      end
      # Returns the /StructParent (or /StructParents for streams) key of an object.
      def struct_parent_key(object)
        return nil unless object.respond_to?(:key?)
        object[:StructParent] || object[:StructParents]
      end

      # For a ParentTree value (StructElem, MCR or OBJR) returns the owning structure element.
      def struct_parent(entry)
        entry = @document.deref(entry)
        entry = @document.wrap(entry) if entry.kind_of?(::Hash)
        return nil unless entry.kind_of?(HexaPDF::Dictionary)
        return entry if entry.key?(:S)
        @document.deref(entry[:P])
      end

      # Returns +true+ if both arguments denote the same PDF object.
      def same_object?(a, b)
        a = @document.deref(a)
        b = @document.deref(b)
        return false unless a && b
        if a.indirect? && b.indirect?
          a.oid == b.oid && a.gen == b.gen
        else
          a.equal?(b) || a == b
        end
      end

      # Short description of an object class for diagnostics.
      def describe(object)
        object = @document.deref(object)
        if object.nil?
          "nil"
        elsif object.respond_to?(:type) && object.type
          object.type.to_s
        else
          object.class.name
        end
      end

      # Wraps the object in the given type class unless it already has that class. This preserves
      # object identity (important for read-only access) and only performs the lazy wrapping
      # HexaPDF itself would perform.
      def as_type(object, klass)
        object.is_a?(klass) ? object : @document.wrap(object, type: klass)
      end

      # Returns +true+ if the object behaves like an array (native Array or HexaPDF PDFArray).
      def array_like?(object)
        object.is_a?(::Array) || object.is_a?(HexaPDF::PDFArray)
      end

      # Content processor that indexes marked content sequences and their text.
      class MarkedContentScanner < HexaPDF::Content::Processor

        # Stack entry for an open marked content sequence.
        StackEntry = Struct.new(:tag, :mcid, :text_parts)

        def initialize(document, resources, page, stream_obj, index)
          super(resources)
          @document = document
          @page = page
          @index = index
          @stack = []
          @stream_stack = [stream_obj]
        end

        def begin_marked_content(tag = nil, properties = nil)
          @stack << StackEntry.new(tag, mcid_from_properties(properties), [])
        end
        alias begin_marked_content_with_property_list begin_marked_content

        def end_marked_content
          entry = @stack.pop
          return unless entry&.mcid
          @index[[:mcid, identity(@page), stream_identity, entry.mcid]] =
            {tag: entry.tag, text: entry.text_parts.join}
        end

        def designate_marked_content_point(tag, properties = nil)
          mcid = mcid_from_properties(properties)
          return unless mcid
          @index[[:mcid, identity(@page), stream_identity, mcid]] ||=
            {tag: tag, text: ''.b}
        end
        alias designate_marked_content_point_with_property_list designate_marked_content_point

        def show_text(text)
          decoded = decode_text(text)
          @stack.each {|entry| entry.text_parts << decoded if entry.mcid }
        rescue StandardError
          # Ignore text that cannot be decoded
        end
        alias show_text_with_positioning show_text

        def paint_xobject(name)
          xobject = begin
                      resources.xobject(name)
                    rescue StandardError
                      nil
                    end
          return unless xobject.kind_of?(HexaPDF::Type::Form)

          res = resources
          graphics_state.save
          if xobject.value.key?(:Matrix)
            graphics_state.ctm.premultiply(*xobject.value[:Matrix])
          end
          @stream_stack.push(xobject)
          xobject.process_contents(self, original_resources: @original_resources)
        ensure
          if xobject&.kind_of?(HexaPDF::Type::Form)
            @stream_stack.pop
            graphics_state.restore
            self.resources = res
          end
        end

        private

        def identity(object)
          object&.indirect? ? [object.oid, object.gen] : -1
        end

        def current_stream
          @stream_stack.last
        end

        def stream_identity
          stream = current_stream
          stream.equal?(@page) ? -1 : identity(stream)
        end

        # Resolves the MCID of a marked content property list. The property list may be given
        # inline as a dictionary or by name referencing the resources /Properties dictionary.
        def mcid_from_properties(properties)
          dict = case properties
                 when Symbol, String
                   begin
                     resources&.property_list(properties)
                   rescue StandardError
                     nil
                   end
                 when HexaPDF::Dictionary, Hash
                   properties
                 end
          dict = @document.deref(dict)
          dict.respond_to?(:key?) && dict.key?(:MCID) ? dict[:MCID] : nil
        end

      end

    end

  end
end
