# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/writer'
require 'hexapdf/document'
require 'stringio'

describe HexaPDF::Writer do
  before do
    @std_input_io = StringIO.new(<<~EOF.force_encoding(Encoding::BINARY))
      %PDF-1.7
      %\xCF\xEC\xFF\xE8\xD7\xCB\xCD
      1 0 obj
      10
      endobj
      2 0 obj
      20
      endobj
      xref
      0 3
      0000000000 65535 f 
      0000000018 00000 n 
      0000000036 00000 n 
      trailer
      <</Size 3>>
      startxref
      54
      %%EOF
      2 0 obj
      <</Length 10>>stream
      Some data!
      endstream
      endobj
      xref
      2 1
      0000000162 00000 n 
      trailer
      <</Size 3/Prev 54>>
      startxref
      219
      %%EOF
      3 0 obj
      <</Producer(HexaPDF version #{HexaPDF::VERSION})>>
      endobj
      xref
      3 1
      0000000296 00000 n 
      trailer
      <</Size 4/Root<</Type/Catalog>>/Info 3 0 R/Prev 219>>
      startxref
      #{343 + HexaPDF::VERSION.length}
      %%EOF
    EOF

    xref_stream = case HexaPDF::VERSION.length
                  when 5 then "x\xDAcbdlg``b`\xB0\x04\x93\x93\x19\x18\x00\f\x1E\x01\\"
                  when 6 then "x\xDAcbd\xEC```b`\xB0\x04\x93\x93\x18\x18\x00\f*\x01\\"
                  else fail
                  end
    @compressed_input_io = StringIO.new(<<~EOF.force_encoding(Encoding::BINARY))
      %PDF-1.7
      %\xCF\xEC\xFF\xE8\xD7\xCB\xCD
      5 0 obj
      <</Type/ObjStm/N 1/First 4/Filter/FlateDecode/Length 15>>stream
      x\xDA3T0P04P\x00\x00\x04\xA1\x01#
      endstream
      endobj
      2 0 obj
      20
      endobj
      3 0 obj
      <</Size 6/Type/XRef/W[1 1 2]/Index[0 6]/Filter/FlateDecode/DecodeParms<</Columns 4/Predictor 12>>/Length 36>>stream
      x\xDAcb`\xF8\xFF\x9F\x89\x89\x95\x91\x91\xE9\x7F\x19\x03\x03\x13\x83\x10\x90\xF8_\f\x14c\x14bd\x04\x00lk\a 
      endstream
      endobj
      startxref
      141
      %%EOF
      6 0 obj
      <</Producer(HexaPDF version #{HexaPDF::VERSION})>>
      endobj
      2 0 obj
      <</Length 10>>stream
      Some data!
      endstream
      endobj
      4 0 obj
      <</Size 7/Root<</Type/Catalog>>/Info 6 0 R/Prev 141/Type/XRef/W[1 2 2]/Index[2 1 4 1 6 1]/Filter/FlateDecode/DecodeParms<</Columns 5/Predictor 12>>/Length 22>>stream
      #{xref_stream}
      endstream
      endobj
      startxref
      #{443 + HexaPDF::VERSION.length}
      %%EOF
    EOF
  end

  def assert_document_conversion(input_io)
    document = HexaPDF::Document.new(io: input_io)
    document.trailer.info[:Producer] = "unknown"
    output_io = StringIO.new(''.b)
    start_xref_offset, xref_section = HexaPDF::Writer.write(document, output_io)
    assert_kind_of(HexaPDF::XRefSection, xref_section)
    assert_kind_of(Integer, start_xref_offset)
    assert_equal(input_io.string, output_io.string)
  end

  it "writes a complete document" do
    assert_document_conversion(@std_input_io)
    assert_document_conversion(@compressed_input_io)
  end

  describe 'linearized writing' do
    def linearize_document(pages: 2)
      document = HexaPDF::Document.new
      if pages > 0
        font = document.add({Type: :Font, Subtype: :Type1, BaseFont: :Helvetica})
        resources = document.add({Font: {F1: font}})
        pages.times do |index|
          page = document.pages.add
          page[:Resources] = resources
          if pages > 1
            canvas = page.canvas
            canvas.font('Helvetica', size: 12)
            canvas.text(index.zero? ? 'first' : 'later')
          end
        end
      end
      io = StringIO.new(''.b)
      document.write(io, linearize: true, update_fields: false)
      [document, io.string]
    end

    def xref_entries(data, offset)
      bytes = data.byteslice(offset, data.bytesize - offset)
      header = bytes.match(/\Axref\n(\d+) (\d+)\n/)
      refute_nil(header)
      first = header[1].to_i
      entries = {}
      position = header.end(0)
      header[2].to_i.times do |index|
        line = bytes.byteslice(position, 19)
        entries[first + index] = if line.end_with?('f ')
                                   [:free, line[0, 10].to_i, line[11, 5].to_i]
                                 else
                                   [:in_use, line[0, 10].to_i, line[11, 5].to_i]
                                 end
        position += line.bytesize + 1
      end
      [entries, bytes[position..].split("startxref\n", 2).first]
    end

    def parse_trailer(source)
      tokenizer = HexaPDF::Tokenizer.new(StringIO.new(source))
      tokenizer.next_token until tokenizer.peek_token == 'trailer'
      tokenizer.next_token
      tokenizer.next_object
    end

    def linearization_information(data)
      first_offset = data.index("xref\n")
      first_entries, first_trailer_source = xref_entries(data, first_offset)
      first_trailer = parse_trailer(first_trailer_source)
      main_offset = data.rindex(/\nxref\n/) + 1
      main_entries, main_trailer_source = xref_entries(data, main_offset)
      main_trailer = parse_trailer(main_trailer_source)
      parser = HexaPDF::Parser.new(StringIO.new(data), HexaPDF::Document.new)
      linearization = parser.load_object(HexaPDF::XRefSection.in_use_entry(1, 0, 18))
      [linearization, first_entries, first_trailer, first_offset, main_entries,
       main_trailer, main_offset]
    end

    def first_page_document(data, info)
      prefix = data.byteslice(0, info[:E])
      first_entries, = xref_entries(data, info[:E])
      max_oid = first_entries.keys.max
      synthetic = +"xref\n0 #{max_oid + 1}\n0000000000 65535 f \n"
      1.upto(max_oid) do |oid|
        entry = first_entries[oid]
        if entry&.first == :in_use
          synthetic << format("%010d 00000 n \n", entry[1])
        else
          synthetic << "0000000000 65535 f \n"
        end
      end
      synthetic << "trailer\n<</Size #{max_oid + 1}/Root #{info[:O]} 0 R>>\n"
      synthetic << "startxref\n#{info[:E]}\n%%EOF\n"
      [prefix, HexaPDF::Document.new(io: StringIO.new(prefix + synthetic),
                                     config: {'parser.try_xref_reconstruction' => false})]
    end

    class BitReader
      def initialize(data)
        @data = data
        @bits = 0
      end

      def read(bits)
        value = 0
        bits.times do |index|
          byte = @data.getbyte(@bits / 8) || 0
          value = (value << 1) | ((byte >> (7 - (@bits % 8))) & 1)
          @bits += 1
        end
        value
      end
    end

    it 'writes a verifiable first-page section, shared resources, xrefs and hint data' do
      _document, data = linearize_document
      info, first_entries, first_trailer, first_offset, main_entries, main_trailer,
        main_offset = linearization_information(data)
      assert_equal(1, info[:Linearized])
      assert_equal(2, info[:H][0])
      assert_kind_of(Integer, info[:H][1])
      assert_equal(3, info[:O])
      assert_equal(2, info[:N])
      assert_equal(first_offset, info[:E])
      assert_equal(main_offset, info[:T])
      assert_equal(data.bytesize, info[:L])
      assert_equal(main_offset, first_trailer[:Prev])

      [first_entries, main_entries].each do |entries|
        entries.each do |oid, (type, offset, gen)|
          next if type == :free
          assert_equal("#{oid} #{gen} obj", data[offset, 30].split("\n", 2).first)
        end
      end

      hint_offset = main_entries[2][1]
      hint_length = info[:H][1]
      hint_header = data[hint_offset, 100]
      hint_data = hint_header.match(/\/Length (\d+)>>stream\n/m)
      assert_equal(hint_length, hint_data[1].to_i)
      stream_start = hint_offset + hint_data.end(0)
      hint_data = data.byteslice(stream_start, hint_length)
      assert_equal(info[:H][1], hint_data.bytesize)
      assert_operator(hint_data.bytesize, :>=, 40 + 32)
      reader = BitReader.new(hint_data)
      8.times { assert_operator(reader.read(4), :<=, 15) }
      assert(hint_data.bytesize > 40)

      prefix, document = first_page_document(data, info)
      page = document.object(info[:O])
      assert_equal(info[:E], prefix.bytesize)
      assert_equal(3, page.oid)
      assert_equal(:Page, page.type)
      assert_equal(:Helvetica, page.resources[:Font][:F1][:BaseFont])
      assert_equal(:Pages, page[:Parent].type)
      assert(page.contents.length > 0)
      assert_equal(3, first_trailer[:Root].oid)
      assert_operator(main_entries[main_trailer[:Root].oid][1], :>=, info[:E])
      full_document = HexaPDF::Document.new(io: StringIO.new(data))
      assert_equal(2, full_document.pages.count)
    end

    it 'handles empty first pages and documents initially written with object streams' do
      _document, data = linearize_document(pages: 1)
      info, = linearization_information(data)
      prefix, document = first_page_document(data, info)
      page = document.object(info[:O])
      assert_equal(info[:E], prefix.bytesize)
      assert_equal(:Page, page.type)
      assert_nil(page[:Contents])
      assert_equal(1, info[:N])
      refute_match('/Type/ObjStm', data)
    end

    it 'flattens an existing optimized PDF that used object streams before linearization' do
      compressed_io = StringIO.new(''.b)
      source = HexaPDF::Document.new
      source.pages.add
      source.write(compressed_io, optimize: true, validate: false)
      assert_match('/Type/ObjStm', compressed_io.string)

      loaded = HexaPDF::Document.new(io: StringIO.new(compressed_io.string))
      output = StringIO.new(''.b)
      loaded.write(output, linearize: true, update_fields: false)
      refute_match('/Type/ObjStm', output.string)
      assert(HexaPDF::Document.new(io: StringIO.new(output.string)).pages.one?)
    end

    it 'does not depend on caller object ordering' do
      outputs = 2.times.map do
        document = HexaPDF::Document.new
        font = document.add({Type: :Font, Subtype: :Type1, BaseFont: :Helvetica})
        resources = document.add({Font: {F1: font}})
        second = document.pages.add
        second[:Resources] = resources
        second.canvas.font('Helvetica', size: 12)
        second.canvas.text('second')
        first = document.pages.insert(0)
        first[:Resources] = resources
        first.canvas.font('Helvetica', size: 12)
        first.canvas.text('first')
        document.trailer[:ID] = ['fixed', 'fixed']
        io = StringIO.new(''.b)
        document.write(io, linearize: true, update_fields: false)
        io.string
      end
      assert_equal(outputs.first, outputs.last)
    end

    it 'rejects unsupported combinations before writing data' do
      document = HexaPDF::Document.new
      document.pages.add
      io = StringIO.new(''.b)
      assert_raises(HexaPDF::Error) { document.write(io, linearize: true, incremental: true) }
      assert_equal(0, io.string.bytesize)

      encrypted = HexaPDF::Document.new
      encrypted.encrypt
      encrypted.pages.add
      io = StringIO.new(''.b)
      assert_raises(HexaPDF::Error) { encrypted.write(io, linearize: true) }
    end
  end

  describe "write_incremental" do
    it "writes a document in incremental mode" do
      doc = HexaPDF::Document.new(io: @std_input_io)
      doc.pages.add
      output_io = StringIO.new
      HexaPDF::Writer.write(doc, output_io, incremental: true)
      assert_equal(output_io.string[0, @std_input_io.string.length], @std_input_io.string)
      doc = HexaPDF::Document.new(io: output_io)
      assert_equal(4, doc.revisions.count)
      assert_equal(2, doc.revisions.current.each.to_a.size)
    end

    it "uses an xref stream if the document already contains at least one" do
      doc = HexaPDF::Document.new(io: @compressed_input_io)
      doc.pages.add
      output_io = StringIO.new
      HexaPDF::Writer.write(doc, output_io, incremental: true)
      refute_match(/^trailer/, output_io.string)
    end

    it "updates the PDF version using the catalog's /Version entry if necessary" do
      doc = HexaPDF::Document.new(io: @std_input_io)
      doc.version = '2.0'
      output_io = StringIO.new
      HexaPDF::Writer.write(doc, output_io, incremental: true)
      assert_equal('2.0', HexaPDF::Document.new(io: output_io).version)
    end

    it "raises an error if the used encryption was changed" do
      io = StringIO.new
      doc = HexaPDF::Document.new
      doc.encrypt
      doc.write(io)

      doc = HexaPDF::Document.new(io: io)
      doc.encrypt(owner_password: 'test')
      assert_raises(HexaPDF::Error) { doc.write('notused', incremental: true) }
    end
  end

  it "moves modified objects into the last revision" do
    io = StringIO.new
    io2 = StringIO.new

    document = HexaPDF::Document.new
    document.pages.add
    HexaPDF::Writer.new(document, io).write

    document = HexaPDF::Document.new(io: io)
    document.pages.add
    HexaPDF::Writer.new(document, io2).write_incremental

    document = HexaPDF::Document.new(io: io2)
    document.revisions.add
    document.pages.add
    HexaPDF::Writer.new(document, io).write

    document = HexaPDF::Document.new(io: io)
    assert_equal(3, document.revisions.count)
    assert_equal(1, document.revisions.all[0].object(3)[:Kids].length)
    assert_equal(2, document.revisions.all[1].object(3)[:Kids].length)
    assert_equal(3, document.revisions.all[2].object(3)[:Kids].length)
  end

  it "creates an xref stream if no xref stream is in a revision but object streams are" do
    document = HexaPDF::Document.new
    document.add({}, type: HexaPDF::Type::ObjectStream)
    HexaPDF::Writer.new(document, StringIO.new).write
    assert_equal(:XRef, document.object(4).type)
  end

  it "creates an xref stream if a previous revision had one" do
    document = HexaPDF::Document.new
    document.pages.add
    io = StringIO.new
    HexaPDF::Writer.new(document, io).write

    document = HexaPDF::Document.new(io: io)
    document.pages.add
    document.add({}, type: HexaPDF::Type::ObjectStream)
    io2 = StringIO.new
    HexaPDF::Writer.new(document, io2).write_incremental

    document = HexaPDF::Document.new(io: io2)
    document.pages.add
    HexaPDF::Writer.new(document, io).write_incremental

    document = HexaPDF::Document.new(io: io)
    assert_equal(3, document.revisions.count)
    assert(document.revisions.all[0].none? {|obj| obj.type == :XRef })
    assert(document.revisions.all[1].one? {|obj| obj.type == :XRef })
    assert(document.revisions.all[2].one? {|obj| obj.type == :XRef })
  end

  it "doesn't create an xref stream if one was just used for an XRefStm entry" do
    # The following document's structure is built like a typical MS Word created PDF
    input = StringIO.new(<<~EOF.b)
      %PDF-1.2
      %\xCF\xEC\xFF\xE8\xD7\xCB\xCD
      1 0 obj
      <</Type/Catalog/Pages 2 0 R>>
      endobj
      2 0 obj
      <</Type/Pages/Kids[3 0 R]/Count 1>>
      endobj
      3 0 obj
      <</Type/Page/MediaBox[0 0 595 842]/Parent 2 0 R/Resources<<>>>>
      endobj
      5 0 obj
      <</Producer(HexaPDF version 0.35.1)>>
      endobj
      4 0 obj
      <</Root 1 0 R/Info 5 0 R/Size 6/Type/XRef/W[1 1 2]/Index[0 6]/Filter/FlateDecode/DecodeParms<</Columns 4/Predictor 12>>/Length 33>>stream
      x\xDAcb`\xF8\xFF\x9F\x89Q\x88\x91\x91\x89A\x97\x81\x81\x89\xC1\x18D\xB4\x80\x88\xD3\f\f\x00C\xDE\x03\xCF
      endstream
      endobj
      xref
      0 6
      0000000000 65535 f
      0000000018 00000 n
      0000000063 00000 n
      0000000114 00000 n
      0000000246 00000 n
      0000000193 00000 n
      trailer
      <</Root 1 0 R/Info 5 0 R/Size 6>>
      startxref
      443
      %%EOF

      xref
      0 0
      trailer
      <</Root 1 0 R/Info 5 0 R/Prev 443/XRefStm 246>>
      startxref
      629
      %%EOF
    EOF

    document = HexaPDF::Document.new(io: input)
    document.pages.add
    io = StringIO.new
    HexaPDF::Writer.new(document, io).write_incremental

    document = HexaPDF::Document.new(io: io)
    refute(document.trailer.key?(:Type))
  end

  it "raises an error if the class is misused and an xref section contains invalid entries" do
    document = HexaPDF::Document.new
    io = StringIO.new
    writer = HexaPDF::Writer.new(document, io)
    xref_section = HexaPDF::XRefSection.new
    xref_section.add_compressed_entry(1, 2, 3)
    assert_raises(HexaPDF::Error) { writer.send(:write_xref_section, xref_section) }
  end

  it "removes the /XRefStm entry in a trailer" do
    io = StringIO.new
    doc = HexaPDF::Document.new
    doc.trailer[:XRefStm] = 1234
    doc.write(io)
    doc = HexaPDF::Document.new(io: io)
    refute(doc.trailer.key?(:XRefStm))
  end

  it "removes the /Type entry in a non-xref stream trailer" do
    io = StringIO.new
    doc = HexaPDF::Document.new
    doc.trailer[:Type] = :XRef
    doc.write(io)
    doc = HexaPDF::Document.new(io: io)
    refute(doc.trailer.key?(:Type))
  end
end
