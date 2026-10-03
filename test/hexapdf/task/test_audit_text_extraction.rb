# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/document'
require 'hexapdf/task/audit_text_extraction'

describe HexaPDF::Task::AuditTextExtraction do
  def simple_font(doc)
    doc.add({
      Type: :Font,
      Subtype: :Type1,
      BaseFont: :Helvetica,
      Encoding: {BaseEncoding: :WinAnsiEncoding, Differences: [1, :fi, :custom]},
      ToUnicode: doc.wrap({}, stream: <<~CMAP),
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        1 begincodespacerange
        <00> <FF>
        endcodespacerange
        1 beginbfchar
        <01> <00660069>
        endbfchar
        endcmap
        end
        end
      CMAP
    })
  end

  def type0_font(doc)
    cid_font = doc.add({
      Type: :Font,
      Subtype: :CIDFontType2,
      BaseFont: :Sample,
      CIDSystemInfo: {Registry: "Custom", Ordering: "Identity", Supplement: 0},
      FontDescriptor: doc.add({Type: :FontDescriptor, FontName: :Sample}),
      CIDToGIDMap: doc.wrap({}, stream: [0, 10, 0, 30, 40, 50, 60].pack('n*')),
    })
    encoding = doc.wrap({}, stream: <<~CMAP)
      /CIDInit /ProcSet findresource begin
      12 dict begin
      begincodespacerange
      <0000> <7FFF>
      endcodespacerange
      5 begincidchar
      <0001> 1
      <0002> 2
      <0003> 3
      <0005> 5
      <0006> 6
      endcidchar
      endcmap
      end
      end
    CMAP
    doc.add({
      Type: :Font,
      Subtype: :Type0,
      BaseFont: :Sample,
      Encoding: encoding,
      DescendantFonts: [cid_font],
      ToUnicode: doc.wrap({}, stream: <<~CMAP),
        begincodespacerange
        <0000> <FFFF>
        endcodespacerange
        5 beginbfchar
        <0001> <0041>
        <0002> <00660069>
        <0004> [<0042>]
        <0005> <D800>
        <0006> <0041>
        endbfchar
        endcmap
      CMAP
    })
  end

  it "audits only used simple-font codes, including ligatures and nested forms" do
    doc = HexaPDF::Document.new
    font = simple_font(doc)
    form = doc.add({
      Type: :XObject,
      Subtype: :Form,
      BBox: [0, 0, 200, 20],
      Resources: doc.wrap({Font: {F1: font}}, type: :XXResources),
    }, stream: "BT /F1 12 Tf 0 10 Td (A) Tj ET")
    page = doc.pages.add
    page[:Resources] = doc.wrap({Font: {F1: font}, XObject: {Fm1: form}}, type: :XXResources)
    page[:Contents] = doc.wrap({}, stream: <<~CONTENT)
      q 1 0 0 1 100 700 cm /Fm1 Do Q
      BT /F1 12 Tf 10 10 Td <0102> Tj ET
    CONTENT

    report = doc.task(:audit_text_extraction)
    by_code = report[:entries].to_h {|entry| [entry[:code], entry]}

    assert_equal("A", by_code[0x41][:unicode])
    assert_equal(:Encoding, by_code[0x41][:unicode_source])
    assert(by_code[0x41][:extractable])
    assert_equal([:Fm1], by_code[0x41][:locations].first[:form_path])
    assert_equal(form.oid, finding_content_oid(by_code[0x41]))

    assert_equal("fi", by_code[0x01][:unicode])
    assert_equal(:ToUnicode, by_code[0x01][:unicode_source])
    assert(by_code[0x01][:one_to_many])
    assert(by_code[0x01][:extractable])

    assert_nil(by_code[0x02][:unicode])
    refute(by_code[0x02][:extractable])
    finding = report[:findings].find {|item| item.reason == :missing_unicode_mapping}
    assert_equal(:error, finding.severity)
    assert_equal(1, finding.page)
    assert_equal(0, finding.content_stream)
    assert_equal(:F1, finding.font_name)
    assert_equal(0x02, finding.code)
    assert_equal("\x02".b, finding.bytes)
    assert_equal(:Tj, finding.keyword)
    assert_equal(page[:Contents].oid, finding.content_stream_oid)
    assert_equal([{font: font, code: 1, unicode: "fi"}],
                 report[:one_to_many].map {|entry| entry.slice(:font, :code, :unicode) })
  end

  def finding_content_oid(entry)
    entry[:locations].first[:content_stream_oid]
  end

  it "connects Type0 CMap, CIDToGIDMap and ToUnicode mappings" do
    doc = HexaPDF::Document.new
    font = type0_font(doc)
    page = doc.pages.add
    page[:Resources] = doc.wrap({Font: {F1: font}}, type: :XXResources)
    page[:Contents] = doc.wrap({}, stream:
      "BT /F1 12 Tf 10 10 Td <8000010002000300040005000600> Tj ET")

    report = doc.task(:audit_text_extraction)
    by_code = report[:entries].to_h {|entry| [entry[:code], entry]}
    assert_equal([:ok, 1, 10, "A", false, true],
                 [(by_code[1][:status] rescue nil), by_code[1][:cid], by_code[1][:gid],
                  by_code[1][:unicode], by_code[1][:one_to_many], by_code[1][:extractable]])
    assert_equal("fi", by_code[2][:unicode])
    assert_equal(0, by_code[2][:gid])
    assert(by_code[2][:one_to_many])
    assert(by_code[2][:extractable])
    assert_equal(30, by_code[3][:gid])
    assert_nil(by_code[3][:unicode])
    refute(by_code[3][:extractable])
    assert_nil(by_code[4][:cid])
    assert_equal("B", by_code[4][:unicode])
    assert(by_code[4][:extractable])
    refute(by_code[5][:extractable])
    assert_equal("A", by_code[6][:unicode])
    assert(by_code[6][:extractable])

    reasons = report[:findings].map(&:reason).tally
    assert_equal(2, reasons[:invalid_character_code])
    assert_equal(1, reasons[:missing_unicode_mapping])
    assert_equal(1, reasons[:invalid_unicode])
    assert_equal(1, reasons[:missing_cid_mapping])

    duplicate = report[:many_to_one].find {|group| group[:unicode] == "A"}
    assert_equal([1, 6], duplicate[:codes])
    ligature = report[:one_to_many].find {|entry| entry[:code] == 2}
    assert_equal("fi", ligature[:unicode])
  end

  it "reports the concrete content stream of an array and tolerates broken encoding CMaps" do
    doc = HexaPDF::Document.new
    cid_font = doc.add({
      Type: :Font,
      Subtype: :CIDFontType0,
      BaseFont: :Sample,
      CIDSystemInfo: {Registry: "Custom", Ordering: "Identity", Supplement: 0},
      FontDescriptor: doc.add({Type: :FontDescriptor, FontName: :Sample}),
    })
    font = doc.add({
      Type: :Font,
      Subtype: :Type0,
      BaseFont: :Sample,
      Encoding: doc.wrap({}, stream: "broken"),
      DescendantFonts: [cid_font],
    })
    page = doc.pages.add
    page[:Resources] = doc.wrap({Font: {F1: font}}, type: :XXResources)
    stream_one = doc.wrap({}, stream: "BT /F1 12 Tf 10 10 Td <0001> Tj ET")
    stream_two = doc.wrap({}, stream: "BT /F1 12 Tf 10 10 Td <0002> Tj ET")
    page[:Contents] = [stream_one, stream_two]

    report = doc.task(:audit_text_extraction)
    finding = report[:findings].find do |item|
      item.reason == :invalid_character_code && item.code == 2
    end
    assert_equal(1, finding.content_stream)
    assert_equal(stream_two.oid, finding.content_stream_oid)
  end

  it "reports a missing GID in an explicit CIDToGIDMap and handles ToUnicode ranges" do
    doc = HexaPDF::Document.new
    cid_font = doc.add({
      Type: :Font,
      Subtype: :CIDFontType2,
      BaseFont: :Sample,
      CIDSystemInfo: {Registry: "Custom", Ordering: "Identity", Supplement: 0},
      FontDescriptor: doc.add({Type: :FontDescriptor, FontName: :Sample}),
      CIDToGIDMap: doc.wrap({}, stream: [0, 10].pack('n*')),
    })
    encoding = doc.wrap({}, stream: <<~'CMAP')
      begincodespacerange
      <0000> <FFFF>
      endcodespacerange
      1 begincidchar
      <0002> 2
      endcidchar
      endcmap
    CMAP
    font = doc.add({
      Type: :Font,
      Subtype: :Type0,
      BaseFont: :Sample,
      Encoding: encoding,
      DescendantFonts: [cid_font],
      ToUnicode: doc.wrap({}, stream: <<~'CMAP'),
        begincodespacerange
        <0000> <FFFF>
        endcodespacerange
        1 beginbfrange
        <0001> <0003> <0061>
        endbfrange
        endcmap
      CMAP
    })
    page = doc.pages.add
    page[:Resources] = doc.wrap({Font: {F1: font}}, type: :XXResources)
    page[:Contents] = doc.wrap({}, stream: "BT /F1 12 Tf 10 10 Td <0002> Tj ET")

    report = doc.task(:audit_text_extraction)
    assert_equal("b", report[:entries].first[:unicode])
    assert_equal(:missing_gid_mapping, report[:findings].first.reason)
  end

  it "handles TJ positioning arrays" do
    doc = HexaPDF::Document.new
    font = simple_font(doc)
    page = doc.pages.add
    page[:Resources] = doc.wrap({Font: {F1: font}}, type: :XXResources)
    page[:Contents] = doc.wrap({}, stream:
      "BT /F1 12 Tf 10 10 Td [<01> -10 <02>] TJ ET")

    report = doc.task(:audit_text_extraction)
    keywords = report[:entries].flat_map do |entry|
      entry[:locations].map {|location| location[:keyword] }
    end.uniq.sort
    assert_equal([:TJ], keywords)
  end

  it "counts a reusable Form on every page where it is shown" do
    doc = HexaPDF::Document.new
    font = simple_font(doc)
    form = doc.add({
      Type: :XObject,
      Subtype: :Form,
      BBox: [0, 0, 200, 20],
      Resources: doc.wrap({Font: {F1: font}}, type: :XXResources),
    }, stream: "BT /F1 12 Tf 0 10 Td (A) Tj ET")
    2.times do
      page = doc.pages.add
      page[:Resources] = doc.wrap({XObject: {Fm1: form}}, type: :XXResources)
      page[:Contents] = doc.wrap({}, stream: "/Fm1 Do")
    end

    report = doc.task(:audit_text_extraction)
    entry = report[:entries].find {|item| item[:code] == 0x41 }
    assert_equal([1, 2], entry[:locations].map {|location| location[:page] })
  end
end
