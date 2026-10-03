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
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
# for more details.
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

    # Task for cleaning up unused entries in resource dictionaries on document level.
    #
    # Unlike approaches based on direct reference counts this task follows the actual content
    # stream operators to determine which resources are used:
    #
    # * +Do+ uses an XObject (Form XObjects, Image XObjects, ...),
    # * +Tf+ uses a Font (a Type3 font's CharProcs are analyzed, too),
    # * +cs+/+CS+, +scn+/+SCN+ use a ColorSpace or a Pattern,
    # * +sh+ uses a Shading,
    # * +gs+ uses an ExtGState (its soft mask +SMask+ is followed),
    # * +BDC+ and +DP+ can use a Properties entry.
    #
    # Indirectly used resources are handled recursively:
    #
    # * Form XObjects may have their own /Resources dictionary which overrides the ones of the
    #   enclosing content streams; if they don't, the enclosing resource dictionaries remain in
    #   effect.
    # * Tiling patterns, Type3 font character procedures and soft mask Form XObjects are content
    #   streams themselves and are therefore analyzed as well.
    #
    # Each shared object's content is only parsed once. However, name resolution is always done in
    # the resource context of the actual use because the same name may point to different
    # resources in different resource dictionaries.
    #
    # Page resource inheritance is respected: if a page doesn't have its own /Resources entry, the
    # resource dictionary inherited from the page tree is used.
    #
    # Circular references (e.g. a Form XObject drawing itself) terminate the analysis and are
    # recorded in the report. If a content stream cannot be parsed or interpreted, all resources
    # visible in the current context are conservatively retained and a warning is recorded.
    #
    # The returned Report lists every deleted entry and the resource dictionary it was deleted
    # from. Retained entries can be queried together with the drawing operation chain that keeps
    # them alive.
    module CleanResources

      # Entry of a Report describing a single resource dictionary entry.
      Entry = Struct.new(:category, :name, :object, :location, keyword_init: true)

      # Information about a retained resource entry.
      KeptEntry = Struct.new(:entry, :reason, keyword_init: true)

      # Information about a terminated circular reference.
      Cycle = Struct.new(:object, :chain, keyword_init: true)

      # Information about a content stream that could not be analyzed.
      Warning = Struct.new(:object, :message, keyword_init: true)

      # Report of a CleanResources task run.
    class Report

      # All entries that were deleted from resource dictionaries (Entry objects).
      attr_reader :deleted_entries

        # All entries that were retained (KeptEntry objects).
        attr_reader :kept_entries

        # Situations where a content stream could not be analyzed (Warning objects).
        attr_reader :warnings

        # Circular references that were terminated (Cycle objects).
        attr_reader :cycles

        def initialize #:nodoc:
          @deleted_entries = []
          @kept_entries = []
          @warnings = []
          @cycles = []
        end

        # Returns a compact, human readable summary of the cleanup run.
        def summary
          "Deleted #{@deleted_entries.size} resource entries, retained " \
            "#{@kept_entries.size} entries, encountered #{@cycles.size} cycle(s) and " \
            "#{@warnings.size} warning(s)"
        end

      end

      # The categories that make up a resources dictionary (PDF2.0 s7.8.3).
      RESOURCE_CATEGORIES = [:ExtGState, :ColorSpace, :Pattern, :Shading, :XObject,
                             :Font, :Properties].freeze

      # Analyzes and cleans the resource dictionaries of the document.
      #
      # If +dry_run+ is +true+, the report is built without actually deleting anything.
      def self.call(doc, dry_run: false)
        Analyzer.new(doc).execute(dry_run)
      end

      # Performs the actual analysis. The implementation is split into three phases:
      #
      # 1. Register the effective resource dictionaries of all pages (respecting inheritance)
      #    as well as those used by annotation appearances and the AcroForm default resources,
      #    then structurally discover all nested resource dictionaries (Form XObjects, Type3
      #    fonts, tiling patterns, soft masks).
      # 2. Replay every reachable content stream with the resource context in effect, marking
      #    used resource entries and following indirect users (Form XObjects, patterns, Type3
      #    charprocs, soft masks).
      # 3. Delete the unmarked entries from the resource dictionaries and build the report.
      class Analyzer #:nodoc:

        def initialize(doc)
          @doc = doc
          @report = Report.new

          # Maps the object identity key of a resources dictionary to the dereferenced object.
          @resource_dicts = {}
          # Human readable owner description per resource dictionary key.
          @locations = {}

          # [category_key, name] => true, marking a resource entry as used.
          @used = {}
          # [category_key, name] => operator chain string, marking why it is used.
          @reasons = {}

          # Object key => parsed instruction arrays (shared content is parsed only once).
          @parsed = {}
          # Object key => error message if the content stream could not be parsed.
          @parse_errors = {}

          # [content_key, env_key] => true, used to terminate circular references.
          @bind_seen = {}
          # [content_key, env_key] => true, the currently active bindings (for cycle detection).
          @bind_active = {}

          # Object key => true, for the structural discovery of nested resources.
          @objects_seen = {}
        end

        def execute(dry_run)
          register_roots
          discover_nested_dicts

          doc.pages.each_with_index do |page, index|
            env = environment_for_page(page)
            bind_page(page, env, index)
            bind_annotations(page, env, index)
          end

          delete_unused(dry_run)
          build_report
        end

        private

        attr_reader :doc, :report

        # :section: Registration and discovery

        def register_roots
          doc.pages.each_with_index do |page, index|
            next unless (resources = page[:Resources])
            location = if page.value[:Resources]
                         "resources of page #{index + 1}"
                       else
                         "inherited resources of page #{index + 1}"
                       end
            register_dict(resources, location)
          end

          if (acro_form = doc.catalog[:AcroForm]) && (dr = acro_form[:DR])
            register_dict(dr, "AcroForm default resources")
          end
        end

        # Recursively registers all resource dictionaries structurally reachable from already
        # registered ones, even through unused entries, so that unused nested resources are
        # cleaned up as well.
        def discover_nested_dicts
          queue = []
          @resource_dicts.each_value do |dict|
            queue << dict
          end

          until (object = queue.pop).nil?
            key = object_key(object)
            next if @objects_seen[key]
            @objects_seen[key] = true

            if @resource_dicts.key?(dict_key(object))
              each_resource_object(object) {|obj| queue << obj }
            elsif type3_font?(object)
              register_nested(object[:Resources], "resources of Type3 font #{key}", queue)
              if (charprocs = object[:CharProcs])
                charprocs.each {|_name, charproc| queue << doc.deref(charproc) }
              end
            elsif tiling_pattern?(object)
              register_nested(object[:Resources], "resources of tiling pattern #{key}", queue)
            elsif (smask = soft_mask_form(object))
              register_nested(smask[:Resources], "resources of soft mask #{object_key(smask)}",
                              queue)
              queue << smask
            elsif form_xobject?(object)
              register_nested(object[:Resources], "resources of Form XObject #{key}", queue)
            end
          end
        end

        def register_nested(resources, location, queue)
          return unless resources
          key = register_dict(resources, location)
          queue << @resource_dicts[key]
        end

        def register_dict(dict, location)
          dict = normalize_resources(dict)
          key = dict_key(dict)
          if @locations.key?(key)
            @locations[key] << "; #{location}" unless @locations[key].include?(location)
          else
            @locations[key] = location
            @resource_dicts[key] = dict
          end
          key
        end

        # Dereferences and, if necessary, wraps a resources value into a Type::Resources object
        # so that the same dictionary always maps to the same identity key.
        def normalize_resources(dict)
          dict = doc.deref(dict)
          unless dict.kind_of?(HexaPDF::Type::Resources)
            dict = doc.wrap(dict, type: HexaPDF::Type::Resources)
          end
          dict
        end

        # Yields every resource entry object of all resource categories of the given resources
        # dictionary (for ColorSpace arrays only the actual color space definition is yielded).
        def each_resource_object(dict)
          RESOURCE_CATEGORIES.each do |category|
            sub_dict = dict[category]
            next unless sub_dict.respond_to?(:each)
            sub_dict.each do |_name, object|
              object = object[1] if category == :ColorSpace && object.kind_of?(Array)
              yield(doc.deref(object)) unless object.nil?
            end
          end
        end

        # :section: Content binding

        def environment_for_page(page)
          resources = page[:Resources]
          resources ? [register_dict(resources, "page resources")] : []
        end

        def bind_page(page, env, index)
          contents = page[:Contents]
          if contents.kind_of?(Array)
            contents.each do |stream|
              stream = doc.deref(stream)
              bind_content(stream, stream_of(stream), env, "page #{index + 1}")
            end
          elsif contents
            contents = doc.deref(contents)
            bind_content(contents, stream_of(contents), env, "page #{index + 1}")
          end
        end

        def bind_annotations(page, env, page_index)
          acro_dr = []
          if (acro_form = doc.catalog[:AcroForm]) && (dr = acro_form[:DR])
            acro_dr = [register_dict(dr, "AcroForm default resources")]
          end
          Array(page[:Annots]).each do |annot|
            annot = doc.deref(annot)
            next unless annot.respond_to?(:[]) && (appearances = annot[:AP])
            [:N, :R, :D].each do |aspect|
              appearance = appearances[aspect]
              next unless appearance
              if appearance.respond_to?(:key?) && !form_xobject?(appearance)
                appearance = appearance.values.find {|value| form_xobject?(doc.deref(value)) }
              end
              next unless appearance
              appearance = doc.deref(appearance)
              bind_content(appearance, stream_of(appearance), env + acro_dr,
                            "#{aspect} appearance of annotation on page #{page_index + 1}")
            end
          end
        end

        # Replays the given content stream in the given resource environment, marking used
        # entries and following indirectly used content streams.
        def bind_content(content_object, contents, env, chain)
          return if contents.nil?

          key = object_key(content_object)
          env = dedup_env(env)
          bind_key = [key, env]
          return if @bind_seen[bind_key]

          if @bind_active[bind_key]
            report_cycle(content_object, chain)
            return
          end
          @bind_active[bind_key] = true

          instructions = parse(content_object, contents)
          if instructions.nil?
            # The content stream cannot be interpreted, conservatively retain everything.
            retain_environment(env, "uninterpretable content stream of #{chain}")
          else
            replay(instructions, env, chain)
          end
        ensure
          @bind_active.delete(bind_key)
          @bind_seen[bind_key] = true
        end

        # Replays the parsed instructions while tracking the current stroking and non-stroking
        # color spaces (needed to distinguish Pattern from ColorSpace uses of +scn+/+SCN+).
        def replay(instructions, env, chain)
          stroking = :DeviceGray
          non_stroking = :DeviceGray
          stroke_stack = []
          non_stroke_stack = []

          instructions.each do |op, operands|
            case op
            when :q
              stroke_stack << stroking
              non_stroke_stack << non_stroking
            when :Q
              stroking = stroke_stack.pop || :DeviceGray
              non_stroking = non_stroke_stack.pop || :DeviceGray
            when :CS
              if (name = operands[0]).kind_of?(Symbol)
                stroking = name
                mark_color_space(name, env, "CS in #{chain}")
              end
            when :cs
              if (name = operands[0]).kind_of?(Symbol)
                non_stroking = name
                mark_color_space(name, env, "cs in #{chain}")
              end
            when :Tf
              mark_entry(:Font, operands[0], env, "Tf in #{chain}") {|font| bind_font(font, env, chain) }
            when :Do
              mark_entry(:XObject, operands[0], env, "Do in #{chain}") {|xobj| bind_xobject(xobj, env, chain) }
            when :gs
              mark_entry(:ExtGState, operands[0], env, "gs in #{chain}") {|gs| bind_ext_gstate(gs, env, chain) }
            when :sh
              mark_entry(:Shading, operands[0], env, "sh in #{chain}")
            when :BDC, :DP
              property_name = case op
                              when :BDC
                                # /Tag /Props BDC, /Tag dict BDC or /Props BDC (single name)
                                operands.size >= 2 ? operands[1] : operands[0]
                              when :DP
                                # /Props DP or /Tag /Props DP
                                operands.size == 1 ? operands[0] : operands[1]
                              end
              if property_name
                mark_entry(:Properties, property_name, env, "#{op} in #{chain}")
              end
            when :SCN, :scn
              is_pattern = (op == :SCN ? stroking : non_stroking) == :Pattern
              name = operands.last
              current = op == :SCN ? stroking : non_stroking
              if is_pattern && name.kind_of?(Symbol)
                mark_entry(:Pattern, name, env, "#{op} in #{chain}") {|pat| bind_pattern(pat, env, chain) }
              elsif !is_pattern
                mark_color_space(current, env, "#{op} in #{chain}")
              end
            end
          end
        end

        # Marks the use of a named color space. Pattern color spaces with an underlying color
        # space (e.g. [/Pattern /DeviceRGB] or [/Pattern /Cs1]) also keep that base color space
        # alive.
        def mark_color_space(name, env, reason)
          return unless named_color_space?(name)
          mark_entry(:ColorSpace, name, env, reason) do |definition|
            if definition.kind_of?(Array) && definition[0] == :Pattern && definition[1].kind_of?(Symbol) &&
                named_color_space?(definition[1])
              mark_entry(:ColorSpace, definition[1], env, "base color space of #{name} (#{reason})")
            end
          end
        end

        # Looks up and marks a named resource entry. If the entry exists, it is yielded so that
        # indirect users can be followed. Dangling names are ignored (e.g. /InvalidRef Do).
        def mark_entry(category, name, env, reason)
          return unless name.kind_of?(Symbol)
          resolved_key, object = resolve(category, name, env)
          return unless resolved_key

          key = [resolved_key, name]
          @used[key] = true
          @reasons[key] ||= reason
          yield(object) if block_given?
        end

        # Resolves a named resource in the given environment, honoring local resource overrides:
        # the first dictionary in the environment that contains the name wins.
        def resolve(category, name, env)
          env.each do |key|
            dict = @resource_dicts[key]
            next unless dict && (sub_dict = dict[category]) && sub_dict.key?(name)
            object = sub_dict[name]
            object = object[1] if category == :ColorSpace && object.kind_of?(Array)
            return [key, doc.deref(object)]
          end
          [nil, nil]
        end

        def retain_environment(env, reason)
          env.each do |key|
            dict = @resource_dicts[key]
            next unless dict
            RESOURCE_CATEGORIES.each do |category|
              sub_dict = dict[category]
              next unless sub_dict.respond_to?(:each)
              sub_dict.each do |name, _object|
                used_key = [key, name]
                @used[used_key] = true
                @reasons[used_key] ||= reason
              end
            end
          end
        end

        # :section: Indirect resource users

        def bind_xobject(xobject, env, chain)
          if form_xobject?(xobject)
            form_env = effective_env(xobject[:Resources], env)
            bind_content(xobject, stream_of(xobject), form_env,
                          "Form XObject #{object_key(xobject)} <- #{chain}")
          elsif (smask = soft_mask_form(xobject))
            # Image XObjects may carry a soft mask Form XObject (PDF2.0 s8.9.5.3).
            bind_ext_gstate_smask(smask, env,
                                  "soft mask of image #{object_key(xobject)} <- #{chain}")
          end
        end

        def bind_font(font, env, chain)
          return unless type3_font?(font)
          font_env = effective_env(font[:Resources], env)
          charprocs = font[:CharProcs]
          return unless charprocs.respond_to?(:each)
          charprocs.each do |name, charproc|
            charproc = doc.deref(charproc)
            charproc_env = form_xobject?(charproc) ? effective_env(charproc[:Resources], font_env) : font_env
            bind_content(charproc, stream_of(charproc), charproc_env,
                          "glyph /#{name} of Type3 font #{object_key(font)} <- #{chain}")
          end
        end

        def bind_ext_gstate(ext_gstate, env, chain)
          smask = soft_mask_form(ext_gstate)
          bind_ext_gstate_smask(smask, env,
                                "soft mask #{object_key(smask)} <- #{chain}") if smask
        end

        def bind_ext_gstate_smask(smask, env, chain)
          form_env = effective_env(smask[:Resources], env)
          bind_content(smask, stream_of(smask), form_env, chain)
        end

        def bind_pattern(pattern, env, chain)
          return unless tiling_pattern?(pattern)
          pattern_env = effective_env(pattern[:Resources], env)
          bind_content(pattern, stream_of(pattern), pattern_env,
                        "tiling pattern #{object_key(pattern)} <- #{chain}")
        end

        # Returns the environment in effect for a Form XObject: its own resources (if any)
        # override the enclosing ones, otherwise the enclosing environment stays in effect.
        def effective_env(resources, parent_env)
          if resources
            normalized = normalize_resources(resources)
            key = dict_key(normalized)
            unless @resource_dicts.key?(key)
              register_dict(normalized, "resources encountered during content analysis")
            end
            [key] + parent_env
          else
            parent_env
          end
        end

        # :section: Parsing

        # Parses a content stream exactly once per shared object and returns its instruction
        # list, or +nil+ if it cannot be parsed (also recorded as a warning).
        def parse(content_object, contents)
          key = object_key(content_object)
          return @parsed[key] if @parsed.key?(key) || @parse_errors.key?(key)

          instructions = []
          begin
            HexaPDF::Content::Parser.parse(contents) do |op, operands|
              if (instruction = build_instruction(op, operands))
                instructions << instruction
              end
            end
          rescue StandardError => e
            unless @parse_errors.key?(key)
              @parse_errors[key] = e.message
              @report.warnings << Warning.new(object: content_object, message: e.message)
            end
            @parsed[key] = nil
            return
          end
          @parsed[key] = instructions
        end

        # Returns the reduced instruction for an operator, or +nil+ if the operator doesn't
        # reference any resources.
        def build_instruction(op, operands)
          case op
          when :q, :Q then [op, nil]
          when :CS, :cs, :Tf, :Do, :gs, :sh then [op, operands.dup]
          when :BDC, :DP
            [op, operands.dup] if operands.any? {|operand| operand.kind_of?(Symbol) }
          when :SCN, :scn
            [op, operands.dup] if operands.last.kind_of?(Symbol)
          end
        end

        # :section: Deletion and reporting

        def delete_unused(dry_run)
          @resource_dicts.each do |key, dict|
            location = @locations[key]
            RESOURCE_CATEGORIES.each do |category|
              sub_dict = dict[category]
              next unless sub_dict.respond_to?(:each)
              sub_dict.each.map {|name, _| name }.each do |name|
                entry = build_entry(category, name, sub_dict, location)
                used_key = [key, name]
                if @used[used_key]
                  @report.kept_entries << KeptEntry.new(entry: entry,
                                                        reason: @reasons[used_key])
                else
                  @report.deleted_entries << entry
                  sub_dict.delete(name) unless dry_run
                end
              end
            end
          end
        end

        def build_entry(category, name, sub_dict, location)
          object = sub_dict[name]
          object = object[1] if category == :ColorSpace && object.kind_of?(Array)
          Entry.new(category: category, name: name, object: doc.deref(object),
                    location: location)
        end

        def build_report
          @report
        end

        def report_cycle(object, chain)
          unless @report.cycles.any? {|cycle| cycle.object == object }
            @report.cycles << Cycle.new(object: object, chain: chain)
          end
        end

        # :section: Helpers

        def named_color_space?(name)
          name.kind_of?(Symbol) && ![:DeviceGray, :DeviceRGB, :DeviceCMYK, :Pattern].include?(name)
        end

        def form_xobject?(object)
          object.respond_to?(:key?) && object[:Subtype] == :Form
        end

        def type3_font?(object)
          object.respond_to?(:key?) && object[:Subtype] == :Type3
        end

        def tiling_pattern?(object)
          object.respond_to?(:key?) && object[:PatternType] == 1
        end

        # Returns the Form XObject referenced by an ExtGState's /SMask entry, or +nil+.
        def soft_mask_form(object)
          return unless object.respond_to?(:key?)
          smask = object[:SMask]
          return unless smask.respond_to?(:key?) && smask[:S] == :Luminosity
          form = doc.deref(smask[:G])
          form if form_xobject?(form)
        end

        def stream_of(object)
          object = doc.deref(object)
          return nil unless object.respond_to?(:stream)
          object.stream
        rescue StandardError
          nil
        end

        def dedup_env(env)
          env.uniq
        end

        # Identity key for a dictionary: the indirect object's oid/gen if possible, otherwise the
        # Ruby object identity of the underlying hash.
        def dict_key(dict)
          if dict.respond_to?(:indirect?) && dict.indirect? && dict.oid
            [:indirect, dict.oid, dict.gen]
          elsif dict.respond_to?(:value) && dict.value.is_a?(Hash)
            [:direct, dict.value.object_id]
          elsif dict.is_a?(Hash)
            [:direct, dict.object_id]
          else
            [:other, dict.object_id]
          end
        end

        # Identity key for an arbitrary indirect object or direct content object.
        def object_key(object)
          if object.respond_to?(:indirect?) && object.indirect? && object.oid
            "obj:#{object.oid}:#{object.gen}"
          else
            "direct:0x#{object.object_id.to_s(16)}"
          end
        end

      end

    end

  end
end
