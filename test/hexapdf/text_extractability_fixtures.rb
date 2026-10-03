# -*- encoding: utf-8; frozen_string_literal: true -*-
#
# Test fixture builder for the TextExtractabilityAuditor.
#
# The document intentionally contains mappings that break text extraction. Nothing here
# guesses characters from font names or repairs mappings.

require 'hexapdf'
require 'hexapdf/font/cmap'

module TestTextExtractabilityFixtures

  module_function

  # Builds a two-page document with deliberately crafted font mappings:
  #
  # Page 1 (one simple Type3 font, used both on the page and inside a nested Form XObject):
  #   0x41 -> A                    (normal, unambiguous)
  #   0x42 -> "fi" (U+0066 U+0069) (legal one-to-many ligature destination)
  #   0x43 -> Secret glyph         (visible in the nested Form, no ToUnicode, private glyph name)
  #   0x44, 0x45 -> Z              (two codes colliding on one character)
  #
  # Page 2 (embedded TrueType composite font, Identity-H / Identity CIDToGIDMap):
  #   0x0047 -> G                  (normal)
  #   0x0049 -> I                  (normal)
  #   0x0046 -> F                  (used code with no ToUnicode entry)
  #   0x004A -> 0xD800             (ToUnicode destination is an unpaired surrogate)
  def build_document
    doc = HexaPDF::Document.new
    build_simple_page(doc)
    build_type0_page(doc)
    doc
  end

  # The font resource name of the simple Type3 fixture font.
  SIMPLE_FONT_NAME = :F3

  # The font resource name of the Type0 fixture font.
  TYPE0_FONT_NAME = :F0

  def build_simple_page(doc)
    page = doc.pages.add
    page[:MediaBox] = [0, 0, 600, 400]
    page.resources[:Font] = {}

    helv = doc.fonts.add('Helvetica').pdf_object
    descriptor = doc.wrap({Type: :FontDescriptor, FontName: :GSBAuditType3,
                           Flags: 0, FontBBox: [0, -200, 500, 800], ItalicAngle: 0,
                           Ascent: 800, Descent: -200, CapHeight: 700, StemV: 80})
    font = doc.add({Type: :Font, Subtype: :Type3, Name: :F3,
                    FontBBox: [0, -200, 500, 800],
                    FontMatrix: [0.001, 0, 0, 0.001, 0, 0],
                    FontDescriptor: descriptor,
                    FirstChar: 0x41, LastChar: 0x45,
                    Widths: [500, 500, 500, 500, 500],
                    Encoding: {BaseEncoding: :WinAnsiEncoding,
                               Differences: [0x41, :A, 0x42, :fi, 0x43, :GSBSecretGlyph,
                                             0x44, :Z, 0x45, :Z]},
                    CharProcs: {}, Resources: {Font: {H: helv}}},
                   type: :Font)

    glyph_content = {
      A: ['(A)', 60], fi: ['(fi)', 0], GSBSecretGlyph: ['(X)', 30],
      Z: ['(Z)', 90]
    }
    glyph_content.each do |name, (operand, x)|
      font[:CharProcs][name] = doc.add({
        Type: :XObject, Subtype: :Form, BBox: [0, -200, 500, 800],
        Resources: {Font: {H: helv}}
      }, stream: "BT /H 500 Tf #{x} 0 Td #{operand} Tj ET")
    end

    font[:ToUnicode] = doc.add({}, stream: <<~CMAP)
      /CIDInit /ProcSet findresource begin
      12 dict begin
      begincmap
      /HexaPDFAuditSimple def
      1 begincodespacerange <41> <45> endcodespacerange
      4 beginbfchar
      <41> <0041>
      <42> <00660069>
      <44> <005A>
      <45> <005A>
      endbfchar
      endcmap
      CMapName currentdict /CMap defineresource pop
      end end
    CMAP

    form = doc.add({Type: :XObject, Subtype: :Form, BBox: [0, 0, 300, 60],
                    Resources: {Font: {F3: font}}},
                   stream: "BT /F3 36 Tf 0 10 Td (C) Tj ET")
    page.resources[:Font][SIMPLE_FONT_NAME] = font
    page.resources[:XObject] = {Fm: form}
    page.contents = <<~CONTENT
      BT /F3 36 Tf 50 330 Td (AB) Tj ET
      q 50 240 0 1 0 0 cm /Fm Do Q
      BT /F3 36 Tf 50 180 Td (DE) Tj ET
    CONTENT
    page
  end

  def build_type0_page(doc)
    page = doc.pages.add
    page[:MediaBox] = [0, 0, 600, 400]
    page.resources[:Font] = {}

    # Embed Ubuntu-Title and point a hand-built Type0 font at it with Identity-H, so the
    # character codes are CIDs and (via the identity CIDToGIDMap) GIDs.
    wrapper = doc.fonts.add(File.join(TEST_DATA_DIR, 'fonts', 'Ubuntu-Title.ttf'))
    embedded_descendant = wrapper.pdf_object[:DescendantFonts][0]
    descriptor = embedded_descendant[:FontDescriptor]

    descendant = doc.add({
      Type: :Font, Subtype: :CIDFontType2,
      BaseFont: embedded_descendant[:BaseFont],
      CIDSystemInfo: {Registry: 'Adobe', Ordering: 'Identity', Supplement: 0},
      FontDescriptor: descriptor, CIDToGIDMap: :Identity,
      DW: embedded_descendant[:DW] || 1000
    }, type: :CIDFont)
    type0 = doc.add({
      Type: :Font, Subtype: :Type0, BaseFont: embedded_descendant[:BaseFont],
      Encoding: :'Identity-H', DescendantFonts: [descendant]
    }, type: :Font)
    # The descriptor already references the embedded FontFile2. GIDs 71 (f), 73..76 are real
    # glyphs of the embedded font. Codes are 2-byte big endian and equal to CID and GID because
    # of Identity-H plus the identity CIDToGIDMap.
    type0[:ToUnicode] = doc.add({}, stream: <<~CMAP)
      /CIDInit /ProcSet findresource begin
      12 dict begin
      begincmap
      /HexaPDFAuditType0 def
      1 begincodespacerange <0000> <FFFF> endcodespacerange
      4 beginbfchar
      <0047> <0046>
      <004A> <004A>
      <004B> <004A>
      <004C> <D800004A>
      endbfchar
      endcmap
      CMapName currentdict /CMap defineresource pop
      end end
    CMAP
    # Notes on the deliberately broken entries:
    # * <0049> is used in the content but intentionally has no ToUnicode entry (missing mapping).
    # * <004C> is a real glyph whose ToUnicode destination is an unpaired surrogate
    #   (0xD800 followed by 0x004A) and therefore invalid Unicode.
    # * <004A> and <004B> map to the same Unicode character J (many-to-one).

    page.resources[:Font][TYPE0_FONT_NAME] = type0
    page.contents = <<~CONTENT
      BT /F0 24 Tf 50 300 Td <0047> Tj 0 -40 Td <0049> Tj 0 -40 Td <004A> Tj
      0 -40 Td <004B> Tj 0 -40 Td <004C> Tj ET
    CONTENT
    page
  end

end
