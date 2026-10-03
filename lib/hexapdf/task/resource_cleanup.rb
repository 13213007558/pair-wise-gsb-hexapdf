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

require 'hexapdf/content/parser'

module HexaPDF
  module Task

    # Task for removing unused entries from the resource dictionaries of a document.
    #
    # == General Information
    #
    # Some PDF files contain resource dictionaries that list many more objects (like fonts or
    # images) than are actually used, for example, when all pages carry the resources of a whole
    # book. This task removes such unused entries from the resource dictionaries of all pages as
    # well as from the resource dictionaries of form XObjects, tiling patterns and Type3 fonts.
    #
    # Whether a resource is used is determined by walking the actual content stream operators,
    # starting from the page content streams and the annotation appearance streams. References
    # through form XObjects, tiling patterns, Type3 fonts, soft masks, shading patterns and color
    # space definitions are followed since those structures may use additional resources
    # themselves. Local resource dictionaries as well as resource inheritance through the page
    # tree are honored. Shared objects are only analyzed once per resource context so that
    # equally named resources of different resource dictionaries don't get mixed up.
    #
    # Cyclic references (e.g. a form XObject painting itself) terminate the analysis of the
    # involved content and are recorded in the returned report. Content that cannot be parsed is
    # handled conservatively: all entries of the associated resource dictionary are kept.
    #
    # The returned Report object lists all deleted entries together with the resource dictionary
    # that contained them as well as all kept entries together with the reason (e.g. the drawing
    # operation) that kept them alive.
    #
    # Note: Only the *entries* of the resource dictionaries are removed. The objects themselves
    # are not deleted from the document; use the Optimize task with +compact: true+ for that.
    module ResourceCleanup

      # The resource categories (sub-dictionaries of a resource dictionary) that are analyzed
      # and cleaned.
      RESOURCE_CATEGORIES = %i[ExtGState ColorSpace Pattern Shading XObject Font Properties].freeze

      # Color space names that are always predefined and therefore never refer to an entry of a
      # /ColorSpace resource dictionary.
      PREDEFINED_COLOR_SPACES = %i[DeviceGray DeviceRGB DeviceCMYK G RGB CMYK Pattern].freeze

      # Information about a single resource dictionary entry that was analyzed by the resource
      # cleanup task.
      class Entry

        # The resource category (e.g. :Font or :XObject).
        attr_reader :category

        # The name of the resource within its category.
        attr_reader :name

        # The resource dictionary that contains (or contained) the entry.
        attr_reader :resources

        # For kept entries the reason why the entry is used, e.g. the drawing operation that
        # references it. This is +nil+ for deleted entries.
        attr_reader :reason

        def initialize(category, name, resources, reason = nil) #:nodoc:
          @category = category
          @name = name
          @resources = resources
          @reason = reason
        end

        # Returns a string describing the entry.
        def to_s
          result = "/#{category} /#{name} in resource dictionary #{ResourceCleanup.label(resources)}"
          reason ? "#{result} (kept: #{reason})" : result
        end

      end

      # Information about a cyclic reference that was detected during the analysis.
      class Cycle

        # A message describing the detected cycle.
        attr_reader :message

        def initialize(message) #:nodoc:
          @message = message
        end

        # Returns the message describing the detected cycle.
        def to_s
          message
        end

      end

      # The result of running the resource cleanup task.
      class Report

        # The entries that were deleted from their resource dictionaries (Entry objects).
        attr_reader :deleted

        # The entries that were kept, together with the reason that kept them alive (Entry
        # objects).
        attr_reader :kept

        # The cyclic references that were detected during the analysis (Cycle objects).
        attr_reader :cycles

        def initialize #:nodoc:
          @deleted = []
          @kept = []
          @cycles = []
        end

        # Returns +true+ if no entries were deleted or kept and no cycles were detected.
        def empty?
          deleted.empty? && kept.empty? && cycles.empty?
        end

        # Returns a string summarizing the result of the resource cleanup.
        def to_s
          lines = ["Deleted #{deleted.size} unused resource entries, kept #{kept.size} used " \
                   "entries, detected #{cycles.size} cyclic references"]
          deleted.each {|entry| lines << "deleted: #{entry}" }
          kept.each {|entry| lines << "kept: #{entry}" }
          cycles.each {|cycle| lines << "cycle: #{cycle}" }
          lines.join("\n")
        end

      end

      # Removes all unused entries from the resource dictionaries of the document and returns a
      # Report object detailing the changes.
      #
      # If +dry_run+ is set to +true+, the document is not modified and the report only shows
      # what *would* be deleted.
      def self.call(doc, dry_run: false)
        cleaner = Cleaner.new(doc)
        cleaner.analyze
        cleaner.apply(dry_run: dry_run)
      end

      # Returns a short description of the given object for use in messages.
      def self.label(obj)
        if obj.kind_of?(HexaPDF::Object) && obj.indirect?
          "object #{obj.oid} #{obj.gen} R"
        else
          "direct dictionary"
        end
      end

      # Analyzes the content streams of a document and applies the cleanup. See
      # ResourceCleanup.call.
      class Cleaner #:nodoc:

        def initialize(doc)
          @doc = doc
          @usage = {}      # resource dictionary key => { [category, name] => reason }
          @contexts = {}   # resource dictionary key => resource dictionary
          @analyzed = {}   # [content key, resource dictionary key] => true
          @active = {}     # like @analyzed but for content currently being analyzed
          @cycles = []     # detected cyclic references
        end

        # Analyzes the content streams of all pages and their annotation appearance streams.
        def analyze
          @doc.pages.each do |page|
            next unless (resources = page[:Resources])
            analyze_content(page, resources,
                            "content stream of page #{ResourceCleanup.label(page)}",
                            resources) { page.contents }
            analyze_annotations(page, resources)
          end
        end

        # Applies the result of the analysis by deleting all unused entries and returns the
        # report.
        def apply(dry_run: false)
          report = Report.new
          report.cycles.concat(@cycles)
          @contexts.each_value do |resources|
            usage = @usage[resource_key(resources)] || {}
            RESOURCE_CATEGORIES.each do |category|
              next unless (sub_dict = category_dict(resources, category))
              category_names(sub_dict).each do |name|
                reason = usage[[category, name]]
                if reason
                  report.kept << Entry.new(category, name, resources, reason)
                else
                  report.deleted << Entry.new(category, name, resources)
                  sub_dict.delete(name) unless dry_run
                end
              end
            end
          end
          report
        end

        # Marks the entry +name+ of the category +category+ of the given resource dictionary as
        # used, with +reason+ explaining why.
        #
        # Returns +true+ only if the entry exists and wasn't already marked as used.
        def mark_used(resources, category, name, reason)
          return false unless name.kind_of?(Symbol)
          sub_dict = category_dict(resources, category)
          return false unless sub_dict&.key?(name)
          usage = (@usage[resource_key(resources)] ||= {})
          key = [category, name]
          return false if usage.key?(key)
          usage[key] = reason
          true
        end

        # Marks all existing entries of the given resource dictionary as used. This conservative
        # approach is used when the associated content cannot be parsed.
        def keep_all(resources, reason)
          RESOURCE_CATEGORIES.each do |category|
            next unless (sub_dict = category_dict(resources, category))
            category_names(sub_dict).each {|name| mark_used(resources, category, name, reason) }
          end
        end

        # Handles the use of the font +name+ by a text showing operation.
        def use_font(resources, root_resources, name, reason)
          return unless mark_used(resources, :Font, name, reason)
          follow_font(resources, root_resources, category_fetch(resources, :Font, name))
        end

        # Handles the use of the XObject +name+ by the Do operator.
        def use_xobject(resources, root_resources, name, reason)
          return unless mark_used(resources, :XObject, name, reason)
          xobject = category_fetch(resources, :XObject, name)
          return unless xobject.kind_of?(HexaPDF::Stream)
          case xobject[:Subtype]
          when :Form
            form_resources = normalize_resources(xobject[:Resources]) || root_resources
            analyze_content(xobject, form_resources,
                            "form XObject #{ResourceCleanup.label(xobject)}",
                            root_resources) { xobject.stream }
          when :Image
            follow_color_space(resources, xobject[:ColorSpace], reason)
          end
        end

        # Handles the use of the graphics state parameter dictionary +name+ by the gs operator.
        def use_ext_gstate(resources, root_resources, name, reason)
          return unless mark_used(resources, :ExtGState, name, reason)
          gstate = category_fetch(resources, :ExtGState, name)
          return unless dict_like?(gstate)
          if dict_like?(smask = @doc.deref(gstate[:SMask])) &&
              (group = @doc.deref(smask[:G])).kind_of?(HexaPDF::Stream)
            group_resources = normalize_resources(group[:Resources]) || root_resources
            analyze_content(group, group_resources,
                            "transparency group #{ResourceCleanup.label(group)} of a soft mask",
                            root_resources) { group.stream }
          end
          font_spec = @doc.deref(gstate[:Font])
          if font_spec.kind_of?(Array) || font_spec.kind_of?(HexaPDF::PDFArray)
            follow_font(resources, root_resources, @doc.deref(font_spec[0]))
          end
        end

        # Handles the use of the pattern +name+ by a color setting operation.
        def use_pattern(resources, root_resources, name, reason)
          return unless mark_used(resources, :Pattern, name, reason)
          pattern = category_fetch(resources, :Pattern, name)
          if pattern.kind_of?(HexaPDF::Stream)
            pattern_resources = normalize_resources(pattern[:Resources]) || resources
            analyze_content(pattern, pattern_resources,
                            "tiling pattern #{ResourceCleanup.label(pattern)}",
                            root_resources) { pattern.stream }
          elsif dict_like?(pattern)
            follow_shading(resources, @doc.deref(pattern[:Shading]), reason)
          end
        end

        # Handles a color setting operation (SCN/scn) whose operands may contain a pattern name.
        def use_pattern_color(resources, root_resources, operands, reason)
          name = operands.reverse.find {|operand| operand.kind_of?(Symbol) }
          use_pattern(resources, root_resources, name, reason) if name
        end

        # Handles the use of the shading +name+ by the sh operator.
        def use_shading(resources, name, reason)
          return unless mark_used(resources, :Shading, name, reason)
          follow_shading(resources, category_fetch(resources, :Shading, name), reason)
        end

        # Handles the use of the property list +name+ by a marked content operator.
        def use_properties(resources, name, reason)
          mark_used(resources, :Properties, name, reason)
        end

        # Handles an inline image whose color space may reference a /ColorSpace entry.
        def use_inline_image(resources, dict, reason)
          follow_color_space(resources, dict[:CS] || dict[:ColorSpace], reason)
        end

        # Analyzes the glyph content streams of the given font if it is a Type3 font.
        def follow_font(resources, root_resources, font)
          return unless dict_like?(font) && font[:Subtype] == :Type3
          font_resources = normalize_resources(font[:Resources]) || resources
          char_procs = @doc.deref(font[:CharProcs])
          return unless dict_like?(char_procs)
          each_entry(char_procs) do |glyph_name, char_proc|
            next unless char_proc.kind_of?(HexaPDF::Stream)
            analyze_content(char_proc, font_resources,
                            "glyph /#{glyph_name} of Type3 font #{ResourceCleanup.label(font)}",
                            root_resources) { char_proc.stream }
          end
        end

        # Follows the color space definition of a shading dictionary.
        def follow_shading(resources, shading, reason)
          return unless dict_like?(shading)
          follow_color_space(resources, shading[:ColorSpace], reason)
        end

        # Follows a color space definition which may be a name referencing a /ColorSpace entry,
        # a color space definition array or an ICCBased color space stream.
        def follow_color_space(resources, definition, reason)
          case definition = @doc.deref(definition)
          when Symbol
            use_color_space_name(resources, definition, reason)
          when Array, HexaPDF::PDFArray
            follow_color_space_array(resources, definition, reason)
          when HexaPDF::Stream
            follow_color_space(resources, definition[:Alternate], reason)
          end
        end

        # Analyzes the given content (returned by the block) in the context of the given resource
        # dictionary.
        #
        # Each unique combination of content and resource dictionary is only analyzed once. If a
        # cyclic reference is detected, the analysis of the involved content is terminated and
        # the cycle is recorded.
        def analyze_content(key_object, resources, description, root_resources)
          key = [key_object.data, resource_key(resources)]
          return if @analyzed.key?(key)
          if @active.key?(key)
            @cycles << Cycle.new(\
              "Cyclic reference detected while analyzing #{description}; terminated the " \
              "analysis of this content")
            return
          end
          @contexts[resource_key(resources)] ||= resources
          @active[key] = true
          begin
            Content::Parser.parse(yield, ContentAnalyzer.new(self, resources, root_resources,
                                                             description))
          rescue StandardError => e
            keep_all(resources,
                     "conservatively kept because the content of #{description} could not be " \
                     "parsed (#{e.message})")
          ensure
            @active.delete(key)
          end
          @analyzed[key] = true
        end

        private

        # Handles the use of a named color space resource.
        def use_color_space_name(resources, name, reason)
          return if PREDEFINED_COLOR_SPACES.include?(name)
          return unless mark_used(resources, :ColorSpace, name, reason)
          follow_color_space(resources, category_fetch(resources, :ColorSpace, name), reason)
        end

        # Follows the nested color space references of a color space definition array.
        def follow_color_space_array(resources, definition, reason)
          case definition[0]
          when :Indexed, :I, :Pattern
            follow_color_space(resources, definition[1], reason)
          when :Separation, :DeviceN
            follow_color_space(resources, definition[2], reason)
          when :ICCBased
            follow_color_space(resources, definition[1], reason)
          end
        end

        # Analyzes the appearance streams of the annotations of a page since they may rely on
        # the page's resource dictionary.
        def analyze_annotations(page, page_resources)
          return unless (annots = page[:Annots])
          annots.each do |annot|
            annot = @doc.deref(annot)
            next unless dict_like?(annot) && dict_like?(ap = @doc.deref(annot[:AP]))
            each_entry(ap) do |_key, appearance|
              if appearance.kind_of?(HexaPDF::Stream)
                analyze_appearance(appearance, page_resources)
              elsif dict_like?(appearance)
                each_entry(appearance) do |_state, form|
                  analyze_appearance(form, page_resources) if form.kind_of?(HexaPDF::Stream)
                end
              end
            end
          end
        end

        # Analyzes a single annotation appearance stream.
        def analyze_appearance(form, page_resources)
          resources = normalize_resources(form[:Resources]) || page_resources
          analyze_content(form, resources,
                          "appearance stream #{ResourceCleanup.label(form)}",
                          page_resources) { form.stream }
        end

        # Returns the sub-dictionary (Hash or Dictionary) of the resource dictionary for the
        # given category, or +nil+ if there is none.
        def category_dict(resources, category)
          sub_dict = @doc.deref(resources[category])
          dict_like?(sub_dict) ? sub_dict : nil
        end

        # Returns the dereferenced value of the named entry of a category sub-dictionary.
        def category_fetch(resources, category, name)
          (sub_dict = category_dict(resources, category)) ? @doc.deref(sub_dict[name]) : nil
        end

        # Returns the names of all entries of the given category sub-dictionary.
        def category_names(sub_dict)
          names = sub_dict.kind_of?(HexaPDF::Dictionary) ? sub_dict.value.keys : sub_dict.keys
          names.select {|name| sub_dict.key?(name) }
        end

        # Yields each name-value pair of the given Hash or Dictionary, dereferencing the values.
        def each_entry(dict)
          dict.each {|name, value| yield(name, @doc.deref(value)) }
        end

        # Returns +true+ if the object can be used like a dictionary.
        def dict_like?(obj)
          obj.kind_of?(HexaPDF::Dictionary) || obj.kind_of?(Hash)
        end

        # Returns the given object as a Resources-compatible dictionary or +nil+ if it is not a
        # dictionary at all.
        def normalize_resources(obj)
          case obj = @doc.deref(obj)
          when HexaPDF::Dictionary then obj
          when Hash then @doc.wrap(obj, type: :XXResources)
          end
        end

        # Returns a stable identity key for a resource dictionary.
        #
        # The key is based on the object identity of the underlying hash so that different
        # resource dictionaries are never mixed up, even if their contents are equal.
        def resource_key(resources)
          resources.kind_of?(HexaPDF::Object) ? resources.value.object_id : resources.object_id
        end

      end

      # Processes the operators of a single content stream and reports the used resources to the
      # Cleaner.
      class ContentAnalyzer #:nodoc:

        def initialize(cleaner, resources, root_resources, description)
          @cleaner = cleaner
          @resources = resources
          @root_resources = root_resources
          @description = description
        end

        def process(operator, operands)
          case operator
          when :Tf
            @cleaner.use_font(@resources, @root_resources, operands[0], reason(operator))
          when :Do
            @cleaner.use_xobject(@resources, @root_resources, operands[0], reason(operator))
          when :gs
            @cleaner.use_ext_gstate(@resources, @root_resources, operands[0], reason(operator))
          when :CS, :cs
            @cleaner.follow_color_space(@resources, operands[0], reason(operator))
          when :SCN, :scn
            @cleaner.use_pattern_color(@resources, @root_resources, operands, reason(operator))
          when :sh
            @cleaner.use_shading(@resources, operands[0], reason(operator))
          when :BDC, :DP
            @cleaner.use_properties(@resources, operands[1], reason(operator))
          when :BI
            @cleaner.use_inline_image(@resources, operands[0], reason(operator))
          end
        end

        private

        # Returns the reason string for the given operator.
        def reason(operator)
          "#{operator} operator in #{@description}"
        end

      end

    end

  end
end
