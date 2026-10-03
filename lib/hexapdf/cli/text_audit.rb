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
# by Section 5 of the GNU Affero General Public License version 3.
#
# In accordance with Section 7(b) of the GNU Affero General Public
# License, a covered work must retain the producer line in every PDF that
# is created or manipulated using HexaPDF.
#
# If the GNU Affero General Public License doesn't fit your need,
# commercial licenses are available at <https://gettalong.at/>.
#++

require 'json'
require 'hexapdf/cli/command'
require 'hexapdf/text_extractability_auditor'

module HexaPDF
  module CLI

    # Audits whether characters actually painted by text operators can be extracted to Unicode.
    class TextAudit < Command

      SEVERITY_LABELS = {
        error: 'ERROR  ', warning: 'WARNING', info: 'INFO   ', ok: 'OK     '
      }.freeze

      def initialize #:nodoc:
        super('text-audit', takes_commands: false)
        short_desc("Audit text extractability of used character codes")
        long_desc(<<~DESC)
          Audits only character codes that are really used by text operators in page content
          streams (including nested Form XObjects) and checks whether they can reliably be
          extracted back to Unicode. The complete mapping chain is traced: simple-font
          Encoding/glyph names, Type0 CID CMaps (code -> CID), CIDToGIDMap (CID -> GID) and
          ToUnicode.

          Font dictionaries declaring large encodings or CMaps for unused glyphs are not
          reported. The command is strictly read-only: it never guesses characters from font
          names and never adds or repairs mappings.
        DESC
        options.on("--password PASSWORD", "-p", String,
                   "The password for decryption. Use - for reading from standard input.") do |pwd|
          @password = (pwd == '-' ? read_password : pwd)
        end
        options.on("-i", "--pages PAGES", "The subset of pages that should be audited") do |pages|
          @pages = pages
        end
        options.on("--json [FILE]", String,
                   "Write the report as JSON to FILE, or standard output if no file is given") do |f|
          @json = f || '-'
        end
        options.on("--strict", "Treat warnings (like many-to-one collisions) as failures") do
          @strict = true
        end
        options.on("--quiet", "Only report errors and warnings") do
          @quiet = true
        end
        @password = nil
        @pages = nil
        @json = nil
        @strict = false
        @quiet = false
      end

      def execute(pdf) #:nodoc:
        with_document(pdf, password: @password) do |doc|
          pages = @pages && parse_pages_specification(@pages, doc.pages.count).map {|i, _| i + 1 }
          result = HexaPDF::TextExtractabilityAuditor.new(doc, pages: pages).audit

          if @json
            output = JSON.pretty_generate(JSON.parse(result.to_json))
            if @json == '-'
              puts output
            else
              File.binwrite(@json, output)
            end
          else
            print_report(result)
          end

          exit(1) if result.issue?(@strict ? :warning : :error)
        end
      end

      private

      def print_report(result)
        findings = result.findings
        findings = findings.reject {|f| f.severity == :info || f.severity == :ok } if @quiet

        findings.each do |f|
          font = f.font
          font_name = font && (font[:BaseFont] || font[:Name] ||
                               font[:FontDescriptor]&.[](:FontName))
          puts "#{SEVERITY_LABELS[f.severity]} #{f.kind}  #{f.location.join(' > ')}"
          puts "           font: #{font_name} (#{font && font[:Subtype]}) resource #{f.resource} " \
               "oid=#{font&.oid},#{font&.gen}"
          puts "           code: #{format_code(f.code, f.bytes)}#{chain_info(f)}"
          puts "           unicode: #{f.unicode.inspect} via #{f.source}" if f.unicode
          puts "           #{f.detail}" if f.detail
        end

        puts
        puts "Scanned #{result.pages_scanned} page(s), #{result.streams_scanned} content " \
             "stream(s) (including nested Form XObjects)."
        counts = result.counts
        puts TextExtractabilityAuditor::SEVERITIES.map {|s| "#{s}=#{counts[s]}" }.join(' ')
      end

      def chain_info(f)
        extras = []
        extras << "CID=#{f.cid}" unless f.cid.nil?
        extras << "GID=#{f.gid}" unless f.gid.nil?
        extras << "glyph=#{f.glyph_name}" if f.glyph_name
        extras.empty? ? '' : '  ' + extras.join(' ')
      end

      def format_code(code, bytes)
        return 'code=-' if code.nil?
        hex_bytes = bytes&.unpack1('H*')
        "0x#{code.to_s(16).upcase.rjust(2, '0')} (bytes: #{hex_bytes || '-'})"
      end

    end

  end
end
