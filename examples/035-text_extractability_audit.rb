# # Text Extractability Audit
#
# This example builds a small PDF that intentionally contains:
#
# * a normal character that extracts cleanly,
# * a ligature whose single character code legally expands to several characters,
# * a visible glyph with no Unicode mapping (drawn inside a nested Form XObject),
# * two codes that collide on one character, and
# * (on a second page) a Type0 font with a missing ToUnicode entry and an invalid ToUnicode
#   destination.
#
# It then runs the read-only TextExtractabilityAuditor. The auditor examines only character
# codes really used by text operators - large encodings declared for unused glyphs are
# irrelevant. It never guesses a character from the font name and never writes mappings.
#
# Usage:
#   ruby examples/035-text_extractability_audit.rb [OUTPUT.pdf]

require 'hexapdf'
require 'hexapdf/text_extractability_auditor'

output = ARGV[0] || 'text-extractability-audit.pdf'

doc = HexaPDF::Document.new

# -- Page 1: one Type3 simple font with normal/ligature/unmapped/colliding glyphs ----------

page1 = doc.pages.add
page1[:MediaBox] = [0, 0, 600, 400]
page1.resources[:Font] = {}
helv = doc.fonts.add('Helvetica').pdf_object
descriptor = doc.wrap({Type: :FontDescriptor, FontName: :AuditType3,
                       Flags: 0, FontBBox: [0, -200, 500, 800], ItalicAngle: 0,
                       Ascent: 800, Descent: -200, CapHeight: 700, StemV: 80})

simple = doc.add({
  Type: :Font, Subtype: :Type3, Name: :F3, FontBBox: [0, -200, 500, 800],
  FontMatrix: [0.001, 0, 0, 0.001, 0, 0],
  FontDescriptor: descriptor,
  FirstChar: 0x41, LastChar: 0x45, Widths: [500] * 5,
  Encoding: {BaseEncoding: :WinAnsiEncoding,
             Differences: [0x41, :A, 0x42, :fi, 0x43, :AuditPrivateGlyph,
                           0x44, :Z, 0x45, :Z]},
  CharProcs: {}, Resources: {Font: {H: helv}}
})
{A: 'A', fi: 'fi', AuditPrivateGlyph: 'X', Z: 'Z'}.each do |name, shown|
  simple[:CharProcs][name] = doc.add({
    Type: :XObject, Subtype: :Form, BBox: [0, -200, 500, 800],
    Resources: {Font: {H: helv}}
  }, stream: "BT /H 500 Tf 10 0 Td (#{shown}) Tj ET")
end
simple[:ToUnicode] = doc.add({}, stream: <<~CMAP)
  /CIDInit /ProcSet findresource begin
  12 dict begin begincmap /AuditSimple def
  1 begincodespacerange <41> <45> endcodespacerange
  4 beginbfchar
  <41> <0041>
  <42> <00660069>
  <44> <005A>
  <45> <005A>
  endbfchar endcmap
  CMapName currentdict /CMap defineresource pop end end
CMAP

nested = doc.add({
  Type: :XObject, Subtype: :Form, BBox: [0, 0, 300, 60],
  Resources: {Font: {F3: simple}}
}, stream: "BT /F3 36 Tf 0 10 Td (C) Tj ET")

page1.resources[:Font][:F3] = simple
page1.resources[:XObject] = {Fm: nested}
page1.contents = <<~CONTENT
  BT /F3 36 Tf 50 330 Td (AB) Tj ET
  q 50 240 0 1 0 0 cm /Fm Do Q
  BT /F3 36 Tf 50 180 Td (DE) Tj ET
CONTENT

result = HexaPDF::TextExtractabilityAuditor.new(doc).audit
doc.write(output)

puts "Wrote #{output}"
puts
result.findings.each do |f|
  next if f.severity == :ok
  code = f.code && format('0x%02X', f.code)
  puts "#{f.severity.to_s.upcase.ljust(7)} #{f.kind}  #{f.location.join(' > ')} " \
       "resource=#{f.resource} code=#{code} unicode=#{f.unicode.inspect}"
  puts "        #{f.detail}" if f.detail
end
puts
puts "Scanned #{result.pages_scanned} page(s), #{result.streams_scanned} content stream(s)."
puts result.counts.inspect
