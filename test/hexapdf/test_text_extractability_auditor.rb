# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/document'
require 'hexapdf/text_extractability_auditor'
require_relative 'text_extractability_fixtures'

describe HexaPDF::TextExtractabilityAuditor do
  include TestTextExtractabilityFixtures

  before do
    @doc = TestTextExtractabilityFixtures.build_document
    @result = HexaPDF::TextExtractabilityAuditor.new(@doc).audit
    @by_code = @result.findings.group_by {|f| [f.font[:Subtype], f.code] }
  end

  it "scans page content streams and nested Form XObject streams" do
    assert_equal(2, @result.pages_scanned)
    assert_equal(3, @result.streams_scanned) # 2 pages + 1 nested form
  end

  it "can restrict the audit to a subset of pages" do
    result = HexaPDF::TextExtractabilityAuditor.new(@doc, pages: [1]).audit
    assert_equal(1, result.pages_scanned)
    assert(result.findings.all? {|f| f.location.first == 'page 1' })
  end

  it "rejects invalid page specifications" do
    assert_raises(HexaPDF::Error) do
      HexaPDF::TextExtractabilityAuditor.new(@doc, pages: [9]).audit
    end
  end

  it "reports page, nested form location, font resource, object id and raw bytes" do
    missing = @result.findings.find {|f| f.kind == :missing_mapping && f.code == 0x43 }
    assert_equal(['page 1', 'Form XObject Fm (12,0)'], missing.location)
    assert_equal(:F3, missing.resource)
    assert_equal('C', missing.bytes)
    assert_equal(6, missing.font.oid)
  end

  describe "with the simple Type3 font" do
    it "accepts an unambiguous normal character" do
      finding = @by_code[[:Type3, 0x41]].first
      assert_equal(:ok, finding.kind)
      assert_equal('A', finding.unicode)
      assert_equal('ToUnicode bfchar', finding.source)
    end

    it "passes the legal one-code-to-many-characters ligature mapping" do
      finding = @by_code[[:Type3, 0x42]].first
      assert_equal(:one_to_many, finding.kind)
      assert_equal(:info, finding.severity)
      assert_equal('fi', finding.unicode)
      assert_match(/legal multi-scalar/, finding.detail)
    end

    it "reports the visible glyph without a mapping used in the nested Form XObject" do
      finding = @by_code[[:Type3, 0x43]].first
      assert_equal(:missing_mapping, finding.kind)
      assert_nil(finding.unicode)
      assert_equal(:GSBSecretGlyph, finding.glyph_name)
    end

    it "does not guess the private glyph name through the font name or AGL" do
      finding = @by_code[[:Type3, 0x43]].first
      assert_nil(finding.unicode)
      refute_match(/Helvetica/i, finding.detail.to_s)
    end

    it "reports distinct codes colliding on the same Unicode as many-to-one" do
      findings = [0x44, 0x45].map {|code| @by_code[[:Type3, code]].first }
      assert_equal([:many_to_one, :many_to_one], findings.map(&:kind))
      assert_equal(['Z', 'Z'], findings.map(&:unicode))
    end
  end

  describe "with the Type0 composite font" do
    it "traces code, CID and GID through Identity-H and CIDToGIDMap" do
      finding = @by_code[[:Type0, 0x47]].first
      assert_equal(:ok, finding.kind)
      assert_equal(71, finding.cid)
      assert_equal(71, finding.gid)
      assert_equal('F', finding.unicode)
      assert_equal("\x00G".b, finding.bytes)
    end

    it "reports a missing ToUnicode entry while CID and GID are resolved" do
      finding = @by_code[[:Type0, 0x49]].first
      assert_equal(:missing_mapping, finding.kind)
      assert_equal(73, finding.cid)
      assert_equal(73, finding.gid)
      assert_nil(finding.unicode)
    end

    it "reports distinct codes colliding on the same Unicode as many-to-one" do
      findings = [0x4A, 0x4B].map {|code| @by_code[[:Type0, code]].first }
      assert_equal([:many_to_one, :many_to_one], findings.map(&:kind))
      assert_equal(['J', 'J'], findings.map(&:unicode))
    end

    it "flags an invalid Unicode destination and keeps the sibling entries" do
      finding = @by_code[[:Type0, 0x4C]].first
      assert_equal(:invalid_unicode, finding.kind)
      assert_equal(:error, finding.severity)
      assert_match(/unpaired high surrogate/, finding.detail)
      assert_nil(finding.unicode)
      assert_equal(76, finding.gid)
      # the valid entries before/after the broken one were not lost
      assert_equal('F', @by_code[[:Type0, 0x47]].first.unicode)
      assert(@by_code[[:Type0, 0x4A]].first.unicode)
    end
  end

  it "does not report mappings declared by the font but never used in an operator" do
    # Only the codes actually present in content streams appear in the report.
    type3_codes = @result.findings.select {|f| f.font[:Subtype] == :Type3 }.map(&:code)
    assert_equal([0x41, 0x42, 0x43, 0x44, 0x45], type3_codes.sort)
  end

  it "uses the Encoding/glyph name fallback for standard fonts without a ToUnicode CMap" do
    doc = HexaPDF::Document.new
    canvas = doc.pages.add.canvas
    canvas.font('Helvetica', size: 12)
    canvas.text('A', at: [50, 700])
    result = HexaPDF::TextExtractabilityAuditor.new(doc).audit
    finding = result.findings.first
    assert_equal(:ok, finding.kind)
    assert_equal('A', finding.unicode)
    assert_match(/Adobe Glyph List/, finding.source)
  end

  it "exposes a JSON serializable report" do
    data = JSON.parse(@result.to_json)
    assert_equal(2, data['pages_scanned'])
    assert_kind_of(Array, data['findings'])
    entry = data['findings'].find {|f| f['kind'] == 'invalid_unicode' }
    assert(entry['font']['base_font'].start_with?('Ubuntu-Title'))
    assert_equal('004c', entry['raw_bytes'])
  end

  it "allows aggregation by severity" do
    counts = @result.counts
    assert_equal(3, counts[:error])
    assert_equal(4, counts[:warning])
    assert_equal(1, counts[:info])
    assert(@result.issue?(:error))
    refute(@result.issue?(:error) && false)
  end

  it "follows an explicit CIDToGIDMap stream instead of assuming identity" do
    doc = HexaPDF::Document.new
    page = doc.pages.add
    page.resources[:Font] = {}
    descriptor = doc.wrap({Type: :FontDescriptor, Flags: 0, FontName: :T,
                           FontBBox: [0, 0, 1000, 1000], ItalicAngle: 0, Ascent: 800,
                           Descent: -200, CapHeight: 700, StemV: 80})
    stream_map = String.new(encoding: Encoding::BINARY)
    100.times { stream_map << "\x00\x00".b }
    stream_map[71 * 2, 2] = [0, 42].pack('C2') # CID 71 -> GID 42
    descendant = doc.add({
      Type: :Font, Subtype: :CIDFontType2, BaseFont: :T,
      CIDSystemInfo: {Registry: 'Adobe', Ordering: 'Identity', Supplement: 0},
      FontDescriptor: descriptor, CIDToGIDMap: doc.add({}, stream: stream_map)
    }, type: :CIDFont)
    type0 = doc.add({
      Type: :Font, Subtype: :Type0, BaseFont: :T, Encoding: :'Identity-H',
      DescendantFonts: [descendant]
    }, type: :Font)
    type0[:ToUnicode] = doc.add({}, stream:
      "1 beginbfchar <0047> <0041> endbfchar")
    page.resources[:Font][:F0] = type0
    page.contents = "BT /F0 24 Tf 50 300 Td <0047> Tj ET"

    result = HexaPDF::TextExtractabilityAuditor.new(doc).audit
    finding = result.findings.first
    assert_equal(71, finding.cid)
    assert_equal(42, finding.gid)
    assert_equal('A', finding.unicode)
  end

  it "warns when a Type0 code reaches GID 0 even if ToUnicode provides a character" do
    doc = HexaPDF::Document.new
    page = doc.pages.add
    page.resources[:Font] = {}
    descriptor = doc.wrap({Type: :FontDescriptor, Flags: 0, FontName: :T,
                           FontBBox: [0, 0, 1000, 1000], ItalicAngle: 0, Ascent: 800,
                           Descent: -200, CapHeight: 700, StemV: 80})
    descendant = doc.add({
      Type: :Font, Subtype: :CIDFontType2, BaseFont: :T,
      CIDSystemInfo: {Registry: 'Adobe', Ordering: 'Identity', Supplement: 0},
      FontDescriptor: descriptor, CIDToGIDMap: :Identity
    }, type: :CIDFont)
    type0 = doc.add({
      Type: :Font, Subtype: :Type0, BaseFont: :T, Encoding: :'Identity-H',
      DescendantFonts: [descendant]
    }, type: :Font)
    type0[:ToUnicode] = doc.add({}, stream:
      "1 beginbfchar <0000> <0041> endbfchar")
    page.resources[:Font][:F0] = type0
    page.contents = "BT /F0 24 Tf 50 300 Td <0000> Tj ET"

    result = HexaPDF::TextExtractabilityAuditor.new(doc).audit
    finding = result.findings.first
    assert_equal(:notdef_glyph, finding.kind)
    assert_equal(0, finding.gid)
    assert_equal('A', finding.unicode)
  end

  it "reports ToUnicode destinations that resolve to Unicode noncharacters" do
    doc = HexaPDF::Document.new
    page = doc.pages.add
    page.resources[:Font] = {}
    font = doc.fonts.add('Helvetica').pdf_object
    font[:ToUnicode] = doc.add({}, stream:
      "1 beginbfchar <41> <FDD0> endbfchar")
    page.resources[:Font][:F1] = font
    page.contents = "BT /F1 24 Tf 50 700 Td (A) Tj ET"

    result = HexaPDF::TextExtractabilityAuditor.new(doc).audit
    finding = result.findings.first
    assert_equal(:noncharacter, finding.kind)
    assert_equal(:info, finding.severity)
    assert_equal(0xFDD0, finding.unicode.unpack1('U'))
  end
end

describe HexaPDF::TextExtractabilityAuditor::FontCodeAnalyzer do
  it "validates raw UTF-16BE destinations" do
    klass = HexaPDF::TextExtractabilityAuditor::FontCodeAnalyzer
    assert_nil(klass.unicode_units_problem([0x00, 0x41]))
    assert_nil(klass.unicode_units_problem([0xD8, 0x3D, 0xDE, 0x00])) # valid pair
    assert_match(/odd number of bytes/,
                 klass.unicode_units_problem([0xD8, 0x00, 0x41]))
    assert_match(/unpaired high surrogate/,
                 klass.unicode_units_problem([0xD8, 0x00, 0x00, 0x41]))
    assert_match(/unpaired low surrogate/,
                 klass.unicode_units_problem([0x00, 0x41, 0xDC, 0x00]))
    assert_nil(klass.unicode_units_problem([0xDB, 0xFF, 0xDF, 0xFF])) # U+10FFFF
  end
end

describe HexaPDF::TextExtractabilityAuditor::TolerantToUnicodeParser do
  def parse(content)
    HexaPDF::TextExtractabilityAuditor::TolerantToUnicodeParser.parse(content)
  end

  it "parses bfchar entries into raw UTF-16BE bytes" do
    mapping = parse("1 beginbfchar <41> <0041> <42> <00660069> endbfchar")
    assert_equal([0x00, 0x41], mapping[0x41][:bytes])
    assert_equal([0x00, 0x66, 0x00, 0x69], mapping[0x42][:bytes])
  end

  it "parses bfrange scalar destinations" do
    mapping = parse("1 beginbfrange <41> <43> <0041> endbfrange")
    assert_equal([0x00, 0x41], mapping[0x41][:bytes])
    assert_equal([0x00, 0x43], mapping[0x43][:bytes])
  end

  it "parses bfrange array destinations" do
    mapping = parse("1 beginbfrange <41> <42> [<0041> <00660069>] endbfrange")
    assert_equal([0x00, 0x41], mapping[0x41][:bytes])
    assert_equal([0x00, 0x66, 0x00, 0x69], mapping[0x42][:bytes])
  end

  it "keeps malformed destinations for later validation instead of aborting" do
    mapping = parse("2 beginbfchar <41> <0041> <42> <D8000041> endbfchar")
    assert_equal([0x00, 0x41], mapping[0x41][:bytes])
    assert_equal([0xD8, 0x00, 0x00, 0x41], mapping[0x42][:bytes])
    problem = HexaPDF::TextExtractabilityAuditor::FontCodeAnalyzer.
      unicode_units_problem(mapping[0x42][:bytes])
    assert_match(/unpaired high surrogate/, problem)
  end
end
