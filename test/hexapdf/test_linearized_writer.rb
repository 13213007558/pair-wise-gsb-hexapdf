# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/writer'
require 'hexapdf/document'
require 'hexapdf/parser'
require 'stringio'

describe HexaPDF::LinearizedWriter do
  before do
    @doc = HexaPDF::Document.new
    @shared_font = @doc.fonts.add('Helvetica')
    @doc.pages.add.canvas.font(@shared_font, size: 12).text('first')
    second = @doc.pages.add
    second.canvas.font(@shared_font, size: 24).text('second')
    @doc.pages.add
  end

  def linearize(doc = @doc, **options)
    io = StringIO.new(''.b)
    doc.write(io, linearize: true, **options)
    io.string
  end

  def dictionary(data)
    length = data.index('endobj') + 6
    parser = HexaPDF::Parser.new(StringIO.new(data[0, length]),
                                HexaPDF::Document.new)
    parser.parse_indirect_object(0)[0]
  end

  def references(value, result = [])
    case value
    when HexaPDF::Reference then result << value
    when HexaPDF::Object
      if value.indirect?
        result << HexaPDF::Reference.new(value.oid, value.gen)
      else
        references(value.value, result)
      end
    when Hash then value.each_value {|inner| references(inner, result) }
    when Array then value.each {|inner| references(inner, result) }
    end
    result
  end

  def verify(data, page_count, document = @doc)
    dict = dictionary(data)
    assert_equal(1, dict[:Linearized])
    assert_equal(1, dict[:V])
    assert_equal(data.bytesize, dict[:L])
    assert_equal(page_count, dict[:N])
    assert_equal(4, dict[:O])
    assert_equal('xref', data[dict[:E], 4])
    assert_equal('xref', data[dict[:T], 4])

    first_end = data.index('%%EOF', dict[:E]) + 5
    first_document = HexaPDF::Document.new
    parser = HexaPDF::Parser.new(StringIO.new(data[0, first_end]),
                                first_document)
    first_xref, first_trailer = parser.load_revision(dict[:E])
    trailer = first_document.wrap(first_trailer, type: :XXTrailer)
    first_revision = HexaPDF::Revision.new(trailer, xref_section: first_xref,
                                           loader: ->(entry) { parser.load_object(entry) })
    first_document.revisions.instance_variable_get(:@revisions).
      replace([first_revision])
    entries = first_xref.map {|_oid, _gen, entry| entry }
    sorted_entries = entries.select(&:in_use?).sort_by(&:pos)
    sorted_entries.each.with_index do |entry, index|
      next unless entry.in_use?
      header = "#{entry.oid} 0 obj"
      assert_equal(header, data[entry.pos, header.length])
      assert_operator(entry.pos + 1, :<=, sorted_entries[index + 1]&.pos || dict[:E])
    end

    hint_oid = entries.find {|entry| entry.pos == dict[:H][0] }.oid
    assert_operator(hint_oid, :>, 4)
    hint_end = dict[:H][0] + dict[:H][1]
    assert_equal(hint_end - dict[:H][0], dict[:H][1])
    hint_object_parser = HexaPDF::Parser.new(StringIO.new(data[0, first_end]),
                                            HexaPDF::Document.new)
    hint_object = hint_object_parser.load_object(first_xref[hint_oid])
    assert_equal(:OEBits, hint_object[:Type])
    hint_values = hint_object.stream.unpack('N*')
    assert_equal([4, dict[:H][0], page_count], hint_values[0, 3])
    assert_equal([32] * 9, hint_values[3, 9])
    assert_equal(32, hint_values[12])
    assert_operator(hint_values.size, :>=, 15 + 12 * page_count)
    assert_operator(hint_values[14], :>, 0)
    assert_equal(4, hint_values[15])
    catalog = first_document.object(first_trailer[:Root])
    first_pages = first_document.object(catalog[:Pages])
    page = first_document.object(first_pages[:Kids].first)
    refs = references(catalog.value) + references(first_pages.value) +
      references(page.value)
    refs << HexaPDF::Reference.new(hint_oid)
    refs.uniq.each do |ref|
      entry = first_xref[ref.oid, ref.gen]
      refute_nil(entry)
      first_document.object(ref)
    end
    page_position = first_xref[page.oid, page.gen].pos
    contents = page[:Contents] && first_document.object(page[:Contents])
    if contents
      content_entry = first_xref[contents.oid, contents.gen]
      assert_equal(contents.oid, hint_values[19])
      assert_equal(content_entry.pos - page_position, hint_values[20])
      assert_operator(hint_values[21], :>, 0)
    else
      assert_equal(0, hint_values[19])
      assert_equal(0, hint_values[20])
      assert_equal(0, hint_values[21])
    end

    main_parser = HexaPDF::Parser.new(StringIO.new(data), HexaPDF::Document.new)
    main_xref, main_trailer = main_parser.load_revision(dict[:T])
    assert_equal(first_trailer[:Prev], dict[:T])
    assert_operator(first_xref.max_oid, :<, main_xref.max_oid)
    main_parser.load_object(main_xref[main_trailer[:Root].oid])

    parsed = HexaPDF::Document.new(io: StringIO.new(data))
    assert_equal(page_count, parsed.pages.count)
    [dict, first_xref, main_xref, document]
  end

  it "writes shared first-page resources into the declared first section" do
    data = linearize
    dict, first_xref, main_xref = verify(data, 3)
    font = @doc.pages[0].resources[:Font].value.values.first
    font_entry = first_xref.map {|_oid, _gen, entry| entry }.find do |entry|
      parser = HexaPDF::Parser.new(StringIO.new(data[0, dict[:E]]),
                                  HexaPDF::Document.new)
      object = parser.load_object(first_xref[entry.oid])
      object[:BaseFont] == font[:BaseFont]
    end
    refute_nil(font_entry)
    assert_equal(font_entry.pos, main_xref[font_entry.oid].pos)
  end

  it "preserves every page through the main revision" do
    data = linearize
    parsed = HexaPDF::Document.new(io: StringIO.new(data))
    assert_equal('first', parsed.pages[0].contents[/(?<=\[\().*?(?=\))/])
    assert_equal('second', parsed.pages[1].contents[/(?<=\[\().*?(?=\))/])
    assert_equal('', parsed.pages[2].contents)
  end

  it "supports an empty first page" do
    doc = HexaPDF::Document.new
    doc.pages.add
    verify(linearize(doc), 1, doc)
  end

  it "supports documents that used object streams" do
    io = StringIO.new(''.b)
    @doc.write(io, optimize: true)
    source = HexaPDF::Document.new(io: StringIO.new(io.string))
    assert(source.each.any? {|object| object.type == :ObjStm })
    data = linearize(source)
    refute_match("/Type/ObjStm", data)
    verify(data, 3, source)
  end

  it "preserves relationships regardless of object construction order" do
    doc = HexaPDF::Document.new
    content = doc.add({Filter: :FlateDecode},
                      stream: Zlib::Deflate.deflate("BT (ordered) Tj ET\n"))
    font = doc.fonts.add('Courier').pdf_object
    page = doc.add({Type: :Page, MediaBox: [0, 0, 100, 200], Contents: content},
                   type: :Page)
    pages = doc.add({Type: :Pages, Count: 1, Kids: [page]}, type: :Pages)
    catalog = doc.add({Type: :Catalog, Pages: pages}, type: :Catalog)
    page[:Parent] = pages
    page[:Resources] = {Font: {F1: font}}
    doc.trailer[:Root] = catalog
    verify(linearize(doc), 1, doc)
  end

  it "includes inherited resources from nested page-tree parents" do
    doc = HexaPDF::Document.new
    font = doc.fonts.add('Courier').pdf_object
    resources = doc.wrap({Font: {F1: font}}, type: :XXResources)
    page = doc.pages.add
    root = doc.catalog[:Pages]
    root[:Resources] = resources
    data = linearize(doc)
    dict, first_xref = verify(data, 1, doc)
    font_oids = first_xref.map do |_oid, _gen, entry|
      next nil unless entry.in_use?
      parser = HexaPDF::Parser.new(StringIO.new(data[0, dict[:E]]),
                                  HexaPDF::Document.new)
      object = parser.load_object(entry)
      entry.oid if object[:BaseFont] == font[:BaseFont]
    end.compact
    assert_equal(1, font_oids.size)
  end

  it "rejects unsupported combinations before writing" do
    io = StringIO.new(''.b)
    assert_raises(HexaPDF::Error) do
      @doc.write(io, linearize: true, incremental: true)
    end
    assert_equal(0, io.size)

    encrypted = HexaPDF::Document.new
    encrypted.encrypt
    assert_raises(HexaPDF::Error) do
      encrypted.write(StringIO.new(''.b), linearize: true)
    end
  end
end
