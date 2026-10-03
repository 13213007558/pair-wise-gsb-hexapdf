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
# commercial licenses are available at <https://gettalong.org/hexapdf/>.
#++

require 'set'
require 'hexapdf/content/parser'
require 'hexapdf/content/processor'
require 'hexapdf/font/cmap'

module HexaPDF
  module Task

    # Performs a read-only audit of character codes used by page and Form
    # streams and reports whether they can be reliably mapped to Unicode.
    #
    # The returned report contains:
    #
    # * +:findings+:: Missing or invalid mappings.
    # * +:entries+:: Used raw codes with CID/GID/Unicode and all locations.
    # * +:one_to_many+:: Legal code to sequence mappings, such as ligatures.
    # * +:many_to_one+:: Multiple raw codes with the same Unicode string.
    class AuditTextExtraction

      # A concrete audit finding.
      Finding = Struct.new(:severity, :reason, :page, :content_stream,
                           :form_path, :font_name, :content_stream_oid, :font,
                           :code, :bytes, :keyword, :unicode, :cid, :gid,
                           keyword_init: true)

      # Audits the document and returns the report hash.
      def self.call(doc)
        new(doc).report
      end

      attr_reader :report #:nodoc:

      def initialize(doc) #:nodoc:
        @doc = doc
        @used_codes = Hash.new {|h, k| h[k] = [] }
        @active_forms = Set.new
        @report = nil
        execute
      end

      private

      def execute
        collector = Collector.new(self)
        @doc.pages.each do |page|
          @active_forms.clear
          contents = page[:Contents]
          if contents.nil?
            next
          elsif contents.kind_of?(HexaPDF::Stream)
            process_stream(collector, page, contents, 0, [])
          else
            contents.each_with_index do |stream, index|
              process_stream(collector, page, @doc.deref(stream), index, [])
            end
          end
        end
        @report = build_report
      end

      def process_stream(collector, page, stream, index, form_path)
        context = {
          page: page.index + 1,
          page_object: page,
          content_stream_index: index,
          content_stream: stream,
          form_path: form_path,
        }
        collector.context = context
        if form_path.empty?
          resources = page[:Resources]
          collector.resources = resources && @doc.wrap(resources, type: :XXResources)
        end
        HexaPDF::Content::Parser.parse(stream.stream, collector)
      end

      def process_form(collector, xobject, name)
        form = xobject.referenced_content || xobject
        return unless form[:Subtype] == :Form
        return if @active_forms.include?(xobject)

        @active_forms << xobject
        context = collector.context.dup
        parent_context = collector.context.dup
        form_path = context[:form_path] + [name]
        parent_resources = collector.resources
        parent_font_name = collector.current_font_name
        collector.resources = if form[:Resources]
                                @doc.wrap(form[:Resources], type: :XXResources)
                              else
                                parent_resources
                              end
        collector.graphics_state.save
        collector.graphics_state.ctm.premultiply(*form[:Matrix])
        begin
          process_stream(collector, context[:page_object], form, 0, form_path)
        ensure
          @active_forms.delete(xobject)
          collector.graphics_state.restore
          collector.resources = parent_resources
          collector.current_font_name = parent_font_name
          collector.context = parent_context
        end
      end

      def record(context, font_name, font, keyword, string)
        codes = decode_used_codes(font, string)
        codes.each do |code, status, length|
          location = context_location(context, keyword, string, font_name)
          @used_codes[[font, code, status, length]] << location
        end
      end

      def decode_used_codes(font, string)
        if font.is_a?(HexaPDF::Type::FontType0)
          begin
            font.encoding_cmap.each_code(string).to_a
          rescue HexaPDF::Error
            string.bytes.map {|byte| [byte, :invalid_encoding_cmap, 1] }
          end
        else
          string.bytes.map {|byte| [byte, :ok, 1] }
        end
      end

      def context_location(context, keyword, text, font_name)
        {
          page: context[:page],
          content_stream_index: context[:content_stream_index],
          content_stream_oid: context[:content_stream].oid,
          form_path: context[:form_path],
          font_name: font_name,
          keyword: keyword,
          text: text,
        }
      end

      def build_report
        entries = @used_codes.map do |(font, code, status, length), locations|
          analyzer = FontAnalyzer.analyze(font, code, length, status)
          analyzer[:locations] = locations
          analyzer
        end
        findings = []
        entries.each do |entry|
          entry_findings = entry.delete(:findings)
          entry_findings.each do |finding|
            if finding[:severity] == :error
              entry[:locations].each do |location|
                findings << make_finding(entry, finding, location)
              end
            else
              findings << make_finding(entry, finding, entry[:locations].first)
            end
          end
        end
        findings.sort_by! {|finding| finding_sort_key(finding) }
        {
          findings: findings,
          entries: entries,
          one_to_many: one_to_many(entries),
          many_to_one: many_to_one(entries),
        }
      end

      def finding_sort_key(finding)
        [finding[:page] || 0, finding[:content_stream] || 0,
         finding[:font_name].to_s, finding[:code] || 0, finding[:bytes].to_s,
         finding[:reason].to_s,
         finding[:form_path].map(&:to_s).join('/')]
      end

      def make_finding(entry, finding, location)
        Finding.new(
          severity: finding[:severity],
          reason: finding[:reason],
          page: location[:page],
          content_stream: location[:content_stream_index],
          form_path: location[:form_path],
          font_name: location[:font_name],
          content_stream_oid: location[:content_stream_oid],
          font: entry[:font],
          code: entry[:code],
          bytes: entry[:bytes],
          keyword: location[:keyword],
          unicode: entry[:unicode],
          cid: entry[:cid],
          gid: entry[:gid]
        )
      end

      def many_to_one(entries)
        groups = {}
        entries.each do |entry|
          next unless entry[:extractable]
          key = [entry[:font], entry[:unicode]]
          (groups[key] ||= []) << entry[:code]
        end
        ambiguous = groups.select {|_, codes| codes.uniq.size > 1 }
        ambiguous.map do |(font, unicode), codes|
          {font: font, unicode: unicode, codes: codes.uniq.sort}
        end
      end

      def one_to_many(entries)
        entries.select {|e| e[:extractable] && e[:one_to_many] }.map do |e|
          {font: e[:font], code: e[:code], unicode: e[:unicode]}
        end
      end

      class Collector < HexaPDF::Content::Processor
        attr_accessor :context

        def initialize(audit)
          super()
          @audit = audit
          @current_font_name = nil
          @context = {page: 0, content_stream_index: 0, content_stream: nil,
                      form_path: [], page_object: nil}
          @operators[:Tf] = TfOperator.new
        end

        attr_accessor :current_font_name

        def set_font_and_size(name, size)
          @current_font_name = name
          graphics_state.font = resources.font(name)
          graphics_state.font_size = size
        end

        def show_text(data)
          record_strings(:Tj, data)
        end

        def move_text_next_line_and_show_text(data)
          record_strings(:"'", data)
        end

        def set_spacing_move_text_next_line_and_show_text(_word_space,
                                                           _char_space, data)
          record_strings(:"\"", data)
        end

        def show_text_with_positioning(data)
          record_strings(:TJ, data)
        end

        def paint_xobject(name)
          @audit.send(:process_form, self, resources.xobject(name), name)
        end

        private

        def record_strings(keyword, data)
          return unless graphics_state.font
          Array(data).each do |item|
            next unless item.kind_of?(String)
            @audit.send(:record, @context, @current_font_name,
                         graphics_state.font, keyword, item)
          end
        end

      end

      class TfOperator < HexaPDF::Content::Operator::BaseOperator
        def initialize
          super('Tf')
        end

        def invoke(processor, name, size)
          processor.set_font_and_size(name, size)
        end
      end

      private_constant(:TfOperator)

      # Analyzes one used code for one concrete font.
      class FontAnalyzer
        def self.analyze(font, code, byte_length, status)
          new(font, code, byte_length, status).result
        end

        attr_reader :result

        def initialize(font, code, byte_length, status)
          @font = font
          @code = code
          @byte_length = byte_length
          @status = status
          @findings = []
          @cid = nil
          @gid = nil
          @unicode = nil
          @source = nil
          @invalid_unicode = false
          execute
        end

        private

        def execute
          add_finding(:error, :invalid_character_code) unless @status == :ok
          analyze_font
          @result = {
            font: @font,
            font_name: @font[:BaseFont],
            font_type: font_type,
            status: @status,
            code: @code,
            bytes: code_bytes,
            cid: @cid,
            gid: @gid,
            unicode: @unicode,
            unicode_source: @source,
            one_to_many: (@unicode && @unicode.codepoints.length > 1),
            invalid_unicode: @invalid_unicode,
            extractable: @findings.none? {|f| f[:severity] == :error },
            findings: @findings,
          }
        end

        def analyze_font
          return if @status != :ok
          if @font.is_a?(HexaPDF::Type::FontType0)
            analyze_type0
          else
            analyze_simple
          end
        end

        def analyze_simple
          unicode, source = unicode_mapping
          @unicode, @source = (unicode == :invalid ? nil : unicode), source
          @invalid_unicode = unicode == :invalid
          if unicode.nil?
            add_finding(:error, :missing_unicode_mapping)
          elsif !valid_unicode?(unicode)
            add_finding(:error, :invalid_unicode)
          end
        end

        def analyze_type0
          cmap = @font.encoding_cmap
          unless cmap.cid_mapped?(@code)
            add_finding(:warning, :missing_cid_mapping)
          else
            @cid = cmap.to_cid(@code)
            analyze_cid_to_gid
          end
          unicode, source = unicode_mapping
          @unicode, @source = (unicode == :invalid ? nil : unicode), source
          @invalid_unicode = unicode == :invalid
          return if unicode && !@invalid_unicode
          reason = @invalid_unicode ? :invalid_unicode :
            :missing_unicode_mapping
          add_finding(:error, reason)
        end

        def analyze_cid_to_gid
          descendant = @font.descendant_font
          case descendant[:Subtype]
          when :CIDFontType0
            @gid = @cid
          when :CIDFontType2
            map = descendant[:CIDToGIDMap]
            if map.nil? || map == :Identity
              @gid = @cid
            elsif map.kind_of?(HexaPDF::Stream)
              values = map.stream.unpack('n*')
              if @cid >= values.length
                add_finding(:warning, :missing_gid_mapping)
              else
                @gid = values[@cid]
              end
            end
          end
        end

        def unicode_mapping
          if @font.key?(:ToUnicode)
            to_unicode = parse_to_unicode
            return [to_unicode, :ToUnicode] if to_unicode == :invalid
            unless to_unicode.nil?
              return [to_unicode, :ToUnicode]
            end
          end
          if @font.is_a?(HexaPDF::Type::FontType0)
            [@font.ucs2_cmap&.to_unicode(@font.ucs2_code(@code)), :UCS2]
          else
            [simple_encoding_unicode, :Encoding]
          end
        end

        def parse_to_unicode
          HexaPDF::Font::CMap.parse(@font[:ToUnicode].stream).to_unicode(@code)
        rescue StandardError
          LenientToUnicodeCMap.parse(@font[:ToUnicode].stream)[@code]
        end

        def simple_encoding_unicode
          @font.encoding.unicode(@code)
        rescue StandardError
          nil
        end

        def valid_unicode?(string)
          return false unless string.kind_of?(::String)
          return false if string.empty?
          string.force_encoding(Encoding::UTF_8).valid_encoding?
        end

        def code_bytes
          return nil if @byte_length == 0
          bytes = []
          value = @code
          (1..@byte_length).each do
            bytes.unshift(value & 0xff)
            value >>= 8
          end
          bytes.pack('C*').b
        end

        def font_type
          if @font.is_a?(HexaPDF::Type::FontType0)
            "Type0/#{@font.descendant_font[:Subtype]}"
          else
            @font[:Subtype]
          end
        end

        def add_finding(severity, reason)
          @findings << {severity: severity, reason: reason}
        end

      end


      class LenientToUnicodeCMap
        def self.parse(stream)
          new(stream).mapping
        end

        attr_reader :mapping

        def initialize(stream)
          @mapping = {}
          @tokenizer = HexaPDF::Content::Tokenizer.new(stream.b)
          parse
        end

        private

        def parse
          until (token = @tokenizer.next_token) ==
              HexaPDF::Tokenizer::NO_MORE_TOKENS
            case token
            when HexaPDF::Tokenizer::Token
              case token
              when 'beginbfchar' then parse_bf_char
              when 'beginbfrange' then parse_bf_range
              end
            end
          end
        end

        def parse_bf_char
          until (code_token = @tokenizer.next_token).is_a?(
            HexaPDF::Tokenizer::Token
          )
            destination = @tokenizer.next_object(allow_end_array_token: true)
            destination = destination.join if destination.kind_of?(Array)
            @mapping[to_integer(code_token)] = decode_utf16(destination)
          end
        end

        def parse_bf_range
          until (start_token = @tokenizer.next_token).is_a?(
            HexaPDF::Tokenizer::Token
          )
            start_code = to_integer(start_token)
            end_code = to_integer(@tokenizer.next_token)
            destination = @tokenizer.next_object(allow_end_array_token: true)
            if destination.kind_of?(String)
              units = destination.unpack('n*')
              start_code.upto(end_code) do |code|
                values = units.dup
                values[-1] += code - start_code
                @mapping[code] = decode_units(values)
              end
            elsif destination.kind_of?(Array)
              destination.each_with_index do |value, index|
                @mapping[start_code + index] = decode_utf16(value)
              end
            end
          end
        end

        def decode_utf16(string)
          return :invalid if string.length.odd?
          decode_units(string.unpack('n*'))
        end

        def decode_units(units)
          result = +''
          until units.empty?
            unit = units.shift
            if (0xD800..0xDBFF).cover?(unit)
              low = units.shift
              return :invalid unless low && (0xDC00..0xDFFF).cover?(low)
              unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
            elsif (0xDC00..0xDFFF).cover?(unit)
              return :invalid
            end
            result << unit
          end
          result.force_encoding(Encoding::UTF_8)
        end

        def to_integer(string)
          string.bytes.reduce(0) {|value, byte| (value << 8) | byte }
        end

      end

    end
  end
end
