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
# by Section 5 of the GNU Affero General Public License version 3.
#
# In accordance with Section 7(b) of the GNU Affero General Public
# License, a covered work must retain the producer line in every PDF that
# is created or manipulated using HexaPDF.
#
# If the GNU Affero General Public License doesn't fit your need,
# commercial licenses are available at <https://gettalong.at/>.
#++

require 'set'
require 'json'
require 'hexapdf'
require 'hexapdf/content/parser'
require 'hexapdf/content/processor'

module HexaPDF

  # Performs a read-only audit of how reliably characters that are actually painted by text
  # operators can be extracted back to Unicode.
  #
  # In contrast to a static inspection of the font dictionaries (whose encodings and CMaps can
  # declare thousands of mappings that are never used), only character codes that are really used
  # inside content streams of pages and nested Form XObjects are examined. The complete mapping
  # chain is traced:
  #
  # * simple fonts: character code -> Encoding (/Differences) glyph name -> ToUnicode
  # * Type0 fonts: character code -> CID CMap -> CID -> CIDToGIDMap -> GID -> ToUnicode
  #
  # The audit never modifies the document, never guesses a character from the font name and never
  # adds missing mappings.
  class TextExtractabilityAuditor

    # Severity levels, ordered from most to least severe.
    SEVERITIES = [:error, :warning, :info, :ok].freeze

    # Maps the reported issue kinds to their default severity.
    #
    # +missing_mapping+:: The used code has no path to Unicode at all.
    # +invalid_unicode+:: The ToUnicode destination is not valid Unicode (lone surrogate,
    #                    malformed UTF-16BE unit sequence, out of range code point).
    # +cid_unmapped+::    The Type0 CID CMap has no mapping for the used character code.
    # +many_to_one+::     Multiple distinct used codes resolve to the same Unicode string.
    # +notdef_glyph+::   The used code reaches the .notdef glyph (CID 0 / GID 0) of an embedded
    #                    font.
    # +one_to_many+::    One used code maps to a sequence of multiple Unicode scalars. This is
    #                    legal (e.g. an "fi" ligature mapped to "fi") and does not prevent
    #                    extraction.
    # +noncharacter+::   The ToUnicode destination contains a Unicode noncharacter.
    # +ok+::             The used code can be extracted unambiguously.
    KINDS = {
      missing_mapping: :error,
      invalid_unicode: :error,
      cid_unmapped: :error,
      many_to_one: :warning,
      notdef_glyph: :warning,
      one_to_many: :info,
      noncharacter: :info,
      ok: :ok
    }.freeze

    # A single report entry.
    Finding = Struct.new(:severity, :kind, :detail, :location, :font, :resource, :code,
                         :bytes, :unicode, :cid, :gid, :glyph_name, :source, keyword_init: true)
    class Finding
      def to_h(*) # :nodoc:
        result = {
          severity: severity.to_s, kind: kind.to_s, detail: detail,
          location: location, resource: resource&.to_s,
          code: code && format('0x%02X', code), code_int: code,
          raw_bytes: bytes&.unpack1('H*'),
          unicode: unicode, cid: cid, gid: gid, glyph_name: glyph_name&.to_s,
          source: source
        }
        if font
          result[:font] = {
            oid: (font.oid unless font.oid == 0), gen: font.gen,
            subtype: font[:Subtype]&.to_s,
            base_font: (font[:BaseFont] || font[:Name] ||
                        font[:FontDescriptor]&.[](:FontName))&.to_s
          }.compact
        end
        result
      end
    end

    # Contains all Finding objects and scan statistics.
    class Result

      # All Finding objects in document order.
      attr_reader :findings

      # Number of scanned pages.
      attr_accessor :pages_scanned

      # Number of scanned content streams (pages and nested Form XObjects).
      attr_accessor :streams_scanned

      def initialize #:nodoc:
        @findings = []
        @pages_scanned = 0
        @streams_scanned = 0
      end

      def add(finding) #:nodoc:
        @findings << finding
      end

      # Counts of findings by severity.
      def counts
        result = Hash.new(0)
        @findings.each {|f| result[f.severity] += 1 }
        result
      end

      # Returns +true+ if at least one finding with the given severity (or worse) exists.
      def issue?(severity = :error)
        threshold = SEVERITIES.index(severity)
        @findings.any? {|f| SEVERITIES.index(f.severity) <= threshold }
      end

      # Returns the findings serialized as an array of hashes.
      def to_a
        @findings.map(&:to_h)
      end

      # Returns a JSON representation of the audit report.
      def to_json(*args)
        {
          pages_scanned: pages_scanned,
          streams_scanned: streams_scanned,
          counts: counts.transform_keys(&:to_s),
          findings: to_a
        }.to_json(*args)
      end
    end

    # Creates a new auditor for the given HexaPDF::Document.
    #
    # +pages+:: An array of 1-based page indices to audit; nil audits all pages.
    def initialize(document, pages: nil)
      @document = document
      @requested_pages = pages
      @result = Result.new
      # font -> { code => Occurrence }
      @font_codes = Hash.new {|h, k| h[k] = {} }
      @visited_forms = Set.new
    end

    # Runs the audit and returns the Result.
    def audit
      collect_used_codes
      resolve_fonts
      @result
    end

    private

    Occurrence = Struct.new(:font, :resource_name, :code, :bytes, :location)

    public

    # Internal entry points used by CollectingProcessor (nested class needs them public).
    def record_code(font, resource, code, bytes, location) # :nodoc:
      @font_codes[font][code] ||= Occurrence.new(font, resource, code, bytes, location)
    end

    def record_undecodable(font, resource, raw, location) # :nodoc:
      @result.add(Finding.new(severity: :error, kind: :cid_unmapped,
                              detail: 'Text operand cannot be decoded into character codes ' \
                                      'with the font encoding CMap',
                              location: location + ['undecodable text operand'],
                              font: font, resource: resource, code: nil,
                              bytes: raw, unicode: nil, source: 'encoding CMap'))
    end

    def scan_form(xobject, name, outer_processor) # :nodoc:
      form = xobject.respond_to?(:referenced_content) ?
        (xobject.referenced_content || xobject) : xobject
      key = "#{form.oid},#{form.gen}"
      location = outer_processor.location +
        ["Form XObject #{name} (#{form.oid},#{form.gen})"]
      return if @visited_forms.include?(key)

      @visited_forms << key
      outer_processor.graphics_state.save
      outer_processor.graphics_state.ctm.premultiply(*form[:Matrix]) if form.key?(:Matrix)
      resources = wrap_resources(form[:Resources]) ||
        outer_processor.instance_variable_get(:@original_resources)
      scan_stream(form.contents, resources, location, outer_processor)
      outer_processor.graphics_state.restore
    end

    # Content processor recording every used character code.
    class CollectingProcessor < Content::Processor
      attr_reader :auditor
      attr_accessor :last_font_resource

      def initialize(auditor, resources, location) # :nodoc:
        super(resources)
        @auditor = auditor
        @location = location
        @last_font_resource = nil
      end

      def location # :nodoc:
        @location
      end

      def set_font_and_size(font, _size) # :nodoc:
        @last_font_resource = font
      end

      def show_text(text) # :nodoc:
        record(text.b)
      end

      def show_text_with_positioning(array) # :nodoc:
        array.each {|item| record(item.b) if item.kind_of?(String) }
      end

      def paint_xobject(name) # :nodoc:
        xobject = resources&.xobject(name)
        if xobject && xobject[:Subtype] == :Form
          auditor.scan_form(xobject, name, self)
        else
          super
        end
      end

      def record(raw) # :nodoc:
        font = graphics_state.font
        return unless font
        begin
          codes = font.decode(raw)
        rescue HexaPDF::Error
          auditor.record_undecodable(font, @last_font_resource, raw, @location)
          return
        end
        code_length = type0_code_length(font)
        bytes_for = build_code_byte_slices(raw, font, codes, code_length)
        codes.each_with_index do |code, index|
          auditor.record_code(font, @last_font_resource, code, bytes_for[index], @location)
        end
      end

      private

      # Maps every code to the exact byte slice it occupied in the operand. For simple fonts
      # this is always one byte; for Type0 fonts the code lengths are derived from the codes.
      def build_code_byte_slices(raw, font, codes, type0_length)
        result = []
        if font[:Subtype] == :Type0
          offset = 0
          codes.each do |code|
            length = type0_length
            result << (raw.byteslice(offset, length) || raw)
            offset += length
          end
        else
          codes.each_with_index {|_code, index| result << (raw.byteslice(index, 1) || raw) }
        end
        result
      end

      # Determines the byte width of codes of a Type0 font from its CID CMap codespace; all
      # codes inside one CMap use one fixed length.
      def type0_code_length(font)
        val = font[:Encoding]
        cmap = if val.kind_of?(Symbol)
                 HexaPDF::Font::CMap.for_name(val.to_s)
               else
                 HexaPDF::Font::CMap.parse(val.stream)
               end
        ranges = cmap.send(:codespace_ranges)
        ranges.empty? ? 2 : 1 + ranges.first[1].length
      rescue HexaPDF::Error, StandardError
        2
      end
    end

    private

    def collect_used_codes
      pages = @document.pages
      if @requested_pages
        @requested_pages.each do |one_based|
          if one_based < 1 || one_based > pages.count
            raise HexaPDF::Error, "Page number #{one_based} out of range (1..#{pages.count})"
          end
        end
      end

      pages.each_with_index do |page, index|
        next if @requested_pages && !@requested_pages.include?(index + 1)
        @result.pages_scanned += 1
        scan_stream(page.contents, page.resources, ["page #{index + 1}"])
      end
    end

    def scan_stream(content, resources, location, outer_processor = nil)
      @result.streams_scanned += 1
      resources = wrap_resources(resources)
      processor = CollectingProcessor.new(self, resources, location)
      if outer_processor
        processor.instance_variable_set(:@graphics_state, outer_processor.graphics_state)
        processor.instance_variable_set(:@original_resources,
                                        outer_processor.instance_variable_get(:@original_resources))
      end
      HexaPDF::Content::Parser.parse(content, processor)
    end

    def wrap_resources(resources)
      return nil if resources.nil?
      resources.respond_to?(:xobject) ? resources :
        @document.wrap(resources, type: :XXResources)
    end

    #----------------------------------------------------------------------------
    # Stage 2: for every used code of every used font, trace the full mapping
    # chain and classify the result.
    #----------------------------------------------------------------------------

    def resolve_fonts
      @font_codes.each do |font, codes|
        begin
          analyzer = FontCodeAnalyzer.new(font)
        rescue HexaPDF::Error => e
          codes.each_value {|occ| emit_unresolved(occ, e.message) }
          next
        end

        # code => Resolution
        resolutions = codes.transform_values {|occ| analyzer.resolve(occ.code) }
        detect_many_to_one(codes.values, resolutions)

        codes.each_value do |occ|
          emit_finding(occ, resolutions[occ.code], analyzer)
        end
      end
    end

    def emit_unresolved(occ, message)
      @result.add(Finding.new(severity: :error, kind: :missing_mapping,
                              detail: "Font mapping chain could not be analyzed: #{message}",
                              location: occ.location, font: occ.font,
                              resource: occ.resource_name, code: occ.code,
                              bytes: occ.bytes, unicode: nil, source: 'font'))
    end

    # Multiple distinct codes of the same font pointing at the same Unicode string is a
    # many-to-one collision (ambiguous extraction). The colliding resolutions are tagged.
    def detect_many_to_one(occurrences, resolutions)
      groups = Hash.new {|h, k| h[k] = [] }
      occurrences.each do |occ|
        res = resolutions[occ.code]
        next unless res.valid_unicode? && !res.unicode.empty?
        groups[res.unicode] << occ.code
      end
      groups.each_value do |code_list|
        next unless code_list.uniq.length > 1
        code_list.uniq.each {|code| resolutions[code].many_to_one = true }
      end
    end

    def emit_finding(occ, res, analyzer)
      kind = classify(res)
      kind = :one_to_many if kind == :ok && res.multi_scalar?
      severity = KINDS[kind]
      detail = explain(kind, res, analyzer)
      @result.add(Finding.new(severity: severity, kind: kind, detail: detail,
                              location: occ.location.dup, font: occ.font,
                              resource: occ.resource_name, code: occ.code,
                              bytes: occ.bytes, unicode: (res.valid_unicode? ? res.unicode : nil),
                              cid: res.cid, gid: res.gid, glyph_name: res.glyph_name,
                              source: res.source))
    end

    def classify(res)
      return :invalid_unicode if res.invalid_unicode
      return :missing_mapping if res.unicode.nil?
      return :cid_unmapped if res.cid_unmapped
      return :noncharacter if res.noncharacter
      return :many_to_one if res.many_to_one
      return :notdef_glyph if res.notdef
      :ok
    end

    def explain(kind, res, analyzer)
      case kind
      when :missing_mapping
        "No usable Unicode mapping for code #{fmt(res.code)}; checked #{analyzer.chain}"
      when :invalid_unicode
        "ToUnicode destination for #{fmt(res.code)} is not valid Unicode " \
          "(#{res.invalid_unicode}); extraction cannot recover a character"
      when :cid_unmapped
        "The Encoding CID CMap does not map code #{fmt(res.code)} to a CID, even though a " \
          "ToUnicode destination exists; rendering and extraction chains disagree"
      when :many_to_one
        "Code #{fmt(res.code)} shares Unicode #{describe_unicode(res.unicode)} with at least one " \
          "other code of the same font; extraction is ambiguous"
      when :notdef_glyph
        "Code #{fmt(res.code)} maps to the .notdef glyph of the embedded font; a visible " \
          "character here usually means the mapping chain is broken"
      when :noncharacter
        "Code #{fmt(res.code)} maps to Unicode noncharacter #{describe_unicode(res.unicode)}"
      when :one_to_many, :ok
        if res.multi_scalar?
          "Code #{fmt(res.code)} maps to the legal multi-scalar sequence " \
            "#{describe_unicode(res.unicode)} (e.g. a ligature split into its base characters); " \
            "one code expanding to multiple characters is allowed by PDF and extracts reliably"
        else
          "Code #{fmt(res.code)} maps unambiguously to #{describe_unicode(res.unicode)}"
        end
      end
    end

    def fmt(code)
      "0x#{code.to_s(16).upcase.rjust(2, '0')}"
    end

    def describe_unicode(string)
      scalars = string.unpack('U*').map {|u| format('U+%04X', u) }.join(' ')
      string.inspect + " [#{scalars}]"
    end

    # Resolution of a single used character code through the font mapping chain.
    class Resolution
      attr_accessor :code, :unicode, :source, :cid, :gid, :glyph_name,
                    :cid_unmapped, :invalid_unicode, :many_to_one, :notdef, :noncharacter

      def initialize(code) # :nodoc:
        @code = code
        @unicode = nil
        @source = nil
        @cid = nil
        @gid = nil
        @glyph_name = nil
        @cid_unmapped = false
        @invalid_unicode = nil
        @many_to_one = false
        @notdef = false
        @noncharacter = false
      end

      def multi_scalar?
        valid_unicode? && unicode.unpack('U*').length > 1
      end

      def valid_unicode?
        !unicode.nil? && unicode.valid_encoding?
      end
    end
    # Analyzes one font and resolves its used codes; keeps a readable description of the chain.
    class FontCodeAnalyzer
      attr_reader :chain

      def initialize(font) # :nodoc:
        @font = font
        @subtype = font[:Subtype]
        @chain = if @subtype == :Type0
                   'ToUnicode CMap, predefined UCS-2 CMap, Encoding CID CMap (code -> CID), ' \
                     'CIDToGIDMap (CID -> GID)'
                 else
                   'ToUnicode CMap and simple-font Encoding/glyph name'
                 end
        @to_unicode = load_to_unicode
      end

      def resolve(code)
        res = Resolution.new(code)
        if @subtype == :Type0
          resolve_type0(code, res)
        else
          resolve_simple(code, res)
        end
        finalize(res)
        res
      end

      private

      def resolve_type0(code, res)
        cid_info = type0_cid(code)
        res.cid = cid_info[:cid]
        res.cid_unmapped = cid_info[:unmapped]

        unless res.cid_unmapped
          gid_info = cid_to_gid(res.cid)
          res.gid = gid_info && gid_info[:gid]
          res.notdef = !gid_info.nil? && gid_info[:notdef]
        end

        apply_destination(to_unicode_destination(code), res)
        return unless res.unicode.nil? && !res.invalid_unicode

        apply_destination(ucs2_destination(code), res)
      end

      # Returns the CID using the Encoding CID CMap. Distinguishes an explicit CID 0 mapping
      # from a missing mapping.
      def type0_cid(code)
        cmap = encoding_cmap
        cid_mapping = cmap.send(:cid_mapping)
        if cid_mapping.key?(code)
          {cid: cid_mapping[code], unmapped: false}
        else
          hit = cmap.send(:cid_range_mappings).reverse_each.lazy.map do |range, start_cid|
            range.cover?(code) ? start_cid + code - range.first : nil
          end.reject(&:nil?).first
          hit ? {cid: hit, unmapped: false} : {cid: 0, unmapped: true}
        end
      rescue HexaPDF::Error
        {cid: 0, unmapped: true}
      end

      def encoding_cmap
        val = @font[:Encoding]
        if val.kind_of?(Symbol)
          HexaPDF::Font::CMap.for_name(val.to_s)
        else
          HexaPDF::Font::CMap.parse(val.stream)
        end
      end

      # Follows the CIDToGIDMap of the descendant CIDFont. The default (and :Identity) maps
      # the CID directly to the GID with the same number.
      def cid_to_gid(cid)
        descendant = @font.descendant_font
        map = descendant[:CIDToGIDMap]
        if map.nil? || map == :Identity
          {gid: cid, notdef: cid == 0}
        else
          gid = map.stream.byteslice(cid * 2, 2)&.unpack1('n')
          gid.nil? ? nil : {gid: gid, notdef: gid == 0}
        end
      end

      def ucs2_destination(code)
        cmap = @font.send(:ucs2_cmap)
        return nil unless cmap
        string = cmap.to_unicode(code)
        return nil unless string
        {bytes: string.encode(Encoding::UTF_16BE).bytes,
         source: 'predefined UCS-2 CMap'}
      rescue StandardError
        nil
      end

      def resolve_simple(code, res)
        apply_destination(to_unicode_destination(code), res)
        return unless res.unicode.nil? && !res.invalid_unicode

        begin
          encoding = @font.encoding
          res.glyph_name = encoding.name(code)
          string = encoding.unicode(code)
        rescue HexaPDF::Error, StandardError
          string = nil
        end
        if string
          res.unicode = string
          res.source = 'Encoding/glyph name (Adobe Glyph List)'
        end
      end

      def to_unicode_destination(code)
        @to_unicode && @to_unicode[code]
      end

      def apply_destination(dest, res)
        return unless dest
        res.source = dest[:source]
        problem = self.class.unicode_units_problem(dest[:bytes])
        if problem
          res.invalid_unicode = problem
        else
          res.unicode = dest[:bytes].pack('C*').force_encoding(Encoding::UTF_16BE)
                                       .encode(Encoding::UTF_8)
        end
      end

      def finalize(res)
        return unless res.valid_unicode?
        res.noncharacter = true if res.unicode.unpack('U*').any? {|u| noncharacter?(u) }
      end

      def noncharacter?(scalar)
        (0xFDD0..0xFDEF).cover?(scalar) || ((scalar & 0xFFFE) == 0xFFFE) || scalar == 0x10FFFF
      end

      def load_to_unicode
        return nil unless @font.key?(:ToUnicode)
        TolerantToUnicodeParser.parse(@font[:ToUnicode].stream)
      rescue HexaPDF::Error, StandardError
        nil
      end

      # Validates the raw UTF-16BE destination bytes of a ToUnicode mapping.
      # Returns nil for valid Unicode, otherwise a human-readable reason.
      def self.unicode_units_problem(bytes)
        return 'odd number of bytes in UTF-16BE destination' if bytes.length.odd?
        units = bytes.each_slice(2).map {|hi, lo| (hi << 8) | lo }
        i = 0
        while i < units.length
          unit = units[i]
          if (0xD800..0xDBFF).cover?(unit)
            low = units[i + 1]
            unless low
              return format('unpaired high surrogate 0x%04X', unit)
            end
            unless (0xDC00..0xDFFF).cover?(low)
              return format('unpaired high surrogate 0x%04X', unit)
            end
            scalar = 0x10000 + (unit - 0xD800) * 0x400 + (low - 0xDC00)
            return format('code point 0x%X outside the Unicode range', scalar) if scalar > 0x10FFFF
            i += 2
          elsif (0xDC00..0xDFFF).cover?(unit)
            return format('unpaired low surrogate 0x%04X', unit)
          elsif unit > 0x10FFFF
            return format('code point 0x%X outside the Unicode range', unit)
          else
            i += 1
          end
        end
        nil
      end
    end

    # Tolerant parser for ToUnicode CMaps.
    #
    # HexaPDF's standard CMap parser aborts on the first malformed bfchar/bfrange destination
    # (e.g. an unpaired surrogate). An audit must still report every valid mapping and pinpoint
    # the invalid entries, so this parser scans the bfchar/bfrange blocks directly, keeping the
    # raw UTF-16BE bytes for later validation. /usecmap references to predefined CMaps are
    # imported through the standard parser.
    class TolerantToUnicodeParser
      def self.parse(stream)
        new.parse(stream)
      end

      def parse(stream) # :nodoc:
        @mappings = {}
        stream = stream.b.dup.force_encoding(Encoding::BINARY)
        import_usecmaps(stream)
        parse_blocks(stream)
        @mappings
      end

      private

      def import_usecmaps(stream)
        stream.scan(/(\/[A-Za-z0-9\-]+)\s+usecmap/) do
          name = Regexp.last_match(1)[1..]
          next unless HexaPDF::Font::CMap.predefined?(name)
          cmap = HexaPDF::Font::CMap.for_name(name)
          import_cmap_mappings(cmap, "usecmap #{name}")
        end
      end

      def import_cmap_mappings(cmap, source)
        cmap.send(:unicode_mapping).each do |code, string|
          @mappings[code] = {bytes: string.encode(Encoding::UTF_16BE).bytes,
                             source: source}
        end
        cmap.send(:unicode_range_mappings).each do |range, start_units|
          range.each do |code|
            units = start_units.dup
            units[-1] += code - range.first
            @mappings[code] = {bytes: units.pack('n*').bytes, source: source}
          end
        end
      end

      def parse_blocks(stream)
        pattern = /beginbf(char|range)(.*?)endbf\1/m
        stream.scan(pattern) do |kind, body|
          kind == 'char' ? parse_bfchar(body) : parse_bfrange(body)
        end
      end

      def parse_bfchar(body)
        body.scan(/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]*)>/) do |src, dest|
          @mappings[src.to_i(16)] = {bytes: hex_bytes(dest), source: 'ToUnicode bfchar'}
        end
      end

      def parse_bfrange(body)
        body.scan(/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(<[0-9A-Fa-f]*>|\[.*?\])/m) do
          |src, end_src, dest|
          start_code = src.to_i(16)
          end_code = end_src.to_i(16)
          if dest.start_with?('[')
            dest.scan(/<([0-9A-Fa-f]*)>/).flatten.each_with_index do |one_dest, offset|
              @mappings[start_code + offset] = {bytes: hex_bytes(one_dest),
                                                source: 'ToUnicode bfrange array'}
            end
          else
            units = hex_units(dest[1..-2])
            (start_code..end_code).each do |code|
              incremented = units.dup
              incremented[-1] = (incremented[-1] || 0) + code - start_code
              @mappings[code] = {bytes: incremented.pack('n*').bytes,
                                source: 'ToUnicode bfrange'}
            end
          end
        end
      end

      def hex_bytes(hex)
        padded = hex.size.even? ? hex : "0#{hex}"
        padded.scan(/../).map {|byte| byte.to_i(16) }
      end

      def hex_units(hex)
        hex_bytes(hex).each_slice(2).map {|hi, lo| (hi << 8) | lo }
      end
    end

  end
end
