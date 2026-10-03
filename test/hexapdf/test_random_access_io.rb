# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/document'
require 'hexapdf/random_access_io'
require 'stringio'

describe HexaPDF::RandomAccessIO do
  # In-memory source for HexaPDF::RandomAccessIO that records all requested ranges.
  class RecordingRangeSource
    attr_reader :reads
    attr_accessor :version
    attr_accessor :max_read_length
    attr_accessor :after_read

    def initialize(data, version: 'v1')
      @data = data.b
      @version = version
      @reads = []
    end

    def read_range(offset, length)
      @reads << [offset, length]
      length = @max_read_length if @max_read_length && length > @max_read_length
      result = @data.byteslice(offset, length) if offset < @data.bytesize
      @after_read&.call(offset, length)
      result
    end

    def size
      @data.bytesize
    end
  end

  before do
    @data = ('a'..'z').to_a.join.b * 40
    @source = RecordingRangeSource.new(@data)
  end

  def create_io(source = @source, **kwargs)
    HexaPDF::RandomAccessIO.new(source, **kwargs)
  end

  def create_pdf(pages:, optimize: false)
    doc = HexaPDF::Document.new
    pages.times do |i|
      doc.pages.add.contents = "% page #{i + 1}\n"
    end
    io = StringIO.new(''.b)
    optimize ? doc.write(io, optimize: true) : doc.write(io)
    io.string
  end

  describe 'initialization' do
    it 'uses the size provided by the source if none is given' do
      io = create_io
      assert_equal(@data.bytesize, io.size)
      assert_equal(64 * 1024, io.chunk_size)
      assert_equal(4 * 1024 * 1024, io.cache_capacity)
      assert_equal('v1', io.version)
      assert_same(@source, io.source)
    end

    it 'allows overriding the size' do
      assert_equal(500, create_io(size: 500).size)
    end

    it 'raises an error if no size can be determined' do
      source = Object.new
      def source.version = 'v1'
      error = assert_raises(ArgumentError) { create_io(source) }
      assert_match(/size/, error.message)
    end

    it 'validates the chunk size and cache capacity' do
      assert_raises(ArgumentError) { create_io(chunk_size: 0) }
      assert_raises(ArgumentError) { create_io(cache_capacity: -1) }
    end
  end

  describe 'IO interface' do
    before do
      @io = create_io(chunk_size: 100)
    end

    it 'reads data and advances the position' do
      assert_equal('abcdefghij', @io.read(10))
      assert_equal(10, @io.pos)
      assert_equal(10, @io.tell)
      assert_equal(Encoding::BINARY, @io.read(1).encoding)
    end

    it 'reads into a provided outbuf' do
      buf = +'placeholder'
      assert_same(buf, @io.read(5, buf))
      assert_equal('abcde', buf)
    end

    it 'reads everything when no length is given' do
      @io.pos = 1000
      assert_equal(@data.byteslice(1000, 40), @io.read)
      assert_equal('', @io.read)
    end

    it 'follows IO semantics at the end of the data' do
      @io.seek(0, IO::SEEK_END)
      assert(@io.eof?)
      assert(@io.eof)
      assert_nil(@io.read(5))
      assert_equal('', @io.read(0))
    end

    it 'clamps reads to the available data' do
      @io.pos = @data.bytesize - 5
      assert_equal(@data.byteslice(-5, 5), @io.read(100))
    end

    it 'supports the different seek modes' do
      @io.seek(10)
      @io.seek(5, IO::SEEK_CUR)
      assert_equal(15, @io.pos)
      @io.seek(-10, IO::SEEK_END)
      assert_equal(@data.bytesize - 10, @io.pos)
      @io.pos = 3
      assert_equal(3, @io.pos)
      @io.rewind
      assert_equal(0, @io.pos)
    end

    it 'raises an error when seeking before the start or with an invalid whence' do
      assert_raises(Errno::EINVAL) { @io.seek(-1) }
      assert_raises(ArgumentError) { @io.seek(0, :invalid) }
    end

    it 'raises an error when reading a negative length' do
      assert_raises(ArgumentError) { @io.read(-1) }
    end

    it 'records the last requested range' do
      @io.seek(10)
      @io.read(50)
      assert_equal([10, 50], @io.last_requested_range)
    end

    it 'can be closed and binmode is a no-op' do
      assert_same(@io, @io.binmode)
      refute(@io.closed?)
      assert_nil(@io.close)
      assert(@io.closed?)
      assert_raises(IOError) { @io.read(1) }
      assert_raises(IOError) { @io.seek(0) }
    end
  end

  describe 'chunk cache' do
    it 'coalesces adjacent missing chunks into a single source read' do
      io = create_io(chunk_size: 100)
      assert_equal(@data.byteslice(0, 250), io.read(250))
      assert_equal([[0, 300]], @source.reads)
    end

    it 'does not coalesce non-adjacent chunks' do
      io = create_io(chunk_size: 100)
      io.read(50)
      io.seek(200)
      io.read(50)
      assert_equal([[0, 100], [200, 100]], @source.reads)
    end

    it 'serves cached chunks without hitting the source again' do
      io = create_io(chunk_size: 100)
      io.read(100)
      io.seek(0)
      io.read(100)
      assert_equal([[0, 100]], @source.reads)
    end

    it 'handles short reads of the source transparently' do
      @source.max_read_length = 7
      io = create_io(chunk_size: 100)
      io.seek(50)
      assert_equal(@data.byteslice(50, 250), io.read(250))
      assert(@source.reads.length > 10)
    end

    it 'evicts the least recently used chunks when the capacity is exceeded' do
      io = create_io(chunk_size: 100, cache_capacity: 250)
      10.times do |i|
        io.seek(i * 100)
        io.read(100)
      end
      assert(io.cache_bytes <= 250)

      @source.reads.clear
      io.seek(900)
      io.read(100)
      assert_empty(@source.reads)
      io.seek(0)
      io.read(100)
      refute_empty(@source.reads)
    end

    it 'works without a cache' do
      io = create_io(chunk_size: 100, cache_capacity: 0)
      assert_equal(@data.byteslice(0, 50), io.read(50))
      io.seek(0)
      assert_equal(@data.byteslice(0, 50), io.read(50))
      assert_equal([[0, 50], [0, 50]], @source.reads)
    end

    it 'works when the cache capacity is smaller than a single chunk' do
      io = create_io(chunk_size: 100, cache_capacity: 50)
      assert_equal(@data.byteslice(0, 250), io.read(250))
    end

    it 'works when a read needs more chunks than the cache can hold' do
      io = create_io(chunk_size: 100, cache_capacity: 150)
      assert_equal(@data.byteslice(0, 250), io.read(250))
    end
  end

  describe 'error handling' do
    it 'retains the requested range when the source fails' do
      def @source.read_range(*) = raise('boom')
      io = create_io(chunk_size: 100)
      error = assert_raises(HexaPDF::RandomAccessIO::ReadError) { io.read(10) }
      assert_equal(0, error.offset)
      assert_equal(100, error.length)
      assert_match(/last requested range: offset=0, length=100/, error.message)
    end

    it 'lets HexaPDF errors of the source propagate' do
      def @source.read_range(*) = raise(HexaPDF::MalformedPDFError, 'boom')
      io = create_io(chunk_size: 100)
      assert_raises(HexaPDF::MalformedPDFError) { io.read(10) }
    end

    it 'retains the requested range when the source provides less data than declared' do
      io = create_io(size: @data.bytesize + 50, chunk_size: 100)
      io.seek(@data.bytesize - 10)
      error = assert_raises(HexaPDF::RandomAccessIO::ReadError) { io.read(60) }
      assert_equal(1000, error.offset)
      assert_equal(90, error.length)
    end

    it 'raises a VersionChangedError retaining the range when the version changes' do
      io = create_io(chunk_size: 100)
      io.read(10)
      @source.version = 'v2'
      error = assert_raises(HexaPDF::RandomAccessIO::VersionChangedError) do
        io.seek(0)
        io.read(10)
      end
      assert_equal(0, error.offset)
      assert_equal(10, error.length)
      assert_kind_of(HexaPDF::Error, error)
    end

    it 'aborts a read in progress when the version changes between short reads' do
      @source.max_read_length = 10
      calls = 0
      @source.after_read = lambda {|*| @source.version = 'v2' if (calls += 1) == 2 }
      io = create_io(chunk_size: 100)
      error = assert_raises(HexaPDF::RandomAccessIO::VersionChangedError) { io.read(50) }
      assert_equal(0, error.offset)
      assert_equal(100, error.length)
    end
  end

  describe 'PDF parsing' do
    it 'parses classic xref tables across an incremental update chain' do
      base_io = StringIO.new(''.b)
      HexaPDF::Document.new.tap {|d| d.pages.add.contents = "% base\n" }.write(base_io)

      doc = HexaPDF::Document.new(io: StringIO.new(base_io.string))
      doc.pages.add.contents = "% update\n"
      full = StringIO.new(''.b)
      HexaPDF::Writer.write(doc, full, incremental: true)

      result = HexaPDF::Document.new(io: create_io(RecordingRangeSource.new(full.string),
                                                 chunk_size: 128))
      assert_equal(2, result.revisions.count)
      assert_equal(2, result.pages.count)
      assert_equal("% base\n", result.pages[0].contents)
      assert_equal("% update\n", result.pages[1].contents)
    end

    it 'parses xref streams and object streams across an incremental update chain' do
      base_io = StringIO.new(''.b)
      HexaPDF::Document.new.tap {|d| d.pages.add.contents = "% base\n" }.write(base_io,
                                                                                optimize: true)

      doc = HexaPDF::Document.new(io: StringIO.new(base_io.string))
      doc.pages.add.contents = "% update\n"
      full = StringIO.new(''.b)
      HexaPDF::Writer.write(doc, full, incremental: true)
      assert_match(%r{/Prev \d+}, full.string)

      result = HexaPDF::Document.new(io: create_io(RecordingRangeSource.new(full.string),
                                                 chunk_size: 128))
      assert_equal(2, result.revisions.count)
      assert_equal(2, result.pages.count)
      assert_equal("% base\n", result.pages[0].contents)
      assert_equal("% update\n", result.pages[1].contents)
    end

    it 'handles objects spanning multiple chunks together with short source reads' do
      content = "% #{'x' * 500}\n"
      doc = HexaPDF::Document.new
      doc.pages.add.contents = content
      pdf_io = StringIO.new(''.b)
      doc.write(pdf_io)

      source = RecordingRangeSource.new(pdf_io.string)
      source.max_read_length = 13
      result = HexaPDF::Document.new(io: create_io(source, chunk_size: 64))
      assert_equal(content, result.pages[0].contents)
    end

    it 'only reads the tail index and the needed objects of a big PDF' do
      pdf = create_pdf(pages: 1000, optimize: true)
      assert_match(%r{/Type\s*/XRef}, pdf)
      assert_match(%r{/ObjStm}, pdf)

      source = RecordingRangeSource.new(pdf)
      io = create_io(source, chunk_size: 4096)
      doc = HexaPDF::Document.new(io: io)
      assert_equal(1000, doc.pages.count)
      assert_equal("% page 800\n", doc.pages[799].contents)

      reads = source.reads
      assert(reads.any? {|offset, length| offset + length == pdf.bytesize },
             'expected the tail of the file with the xref information to be read')
      total = reads.sum {|_, length| length }
      assert(total < pdf.bytesize / 2,
             "expected less than half of the file to be read, got #{total} of #{pdf.bytesize}")
      mid_start = (pdf.bytesize * 0.4).to_i
      mid_end = (pdf.bytesize * 0.6).to_i
      assert(reads.none? {|offset, length| offset < mid_end && offset + length > mid_start },
             'expected the unused middle part of the file to remain unread')
    end

    it 'stops parsing when the source version changes mid-way' do
      source = RecordingRangeSource.new(create_pdf(pages: 10, optimize: true))
      doc = HexaPDF::Document.new(io: create_io(source, chunk_size: 512))
      source.version = 'v2'
      assert_raises(HexaPDF::RandomAccessIO::VersionChangedError) { doc.pages[5].contents }
    end

    it 'retains the last requested range when the /Prev chain is corrupted' do
      objects = +"%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\n"
      pdf = objects << "xref\n0 2\n0000000000 65535 f \n0000000009 00000 n \n" \
        "trailer\n<< /Size 2 /Root 1 0 R /Prev 20 >>\nstartxref\n#{objects.bytesize}\n%%EOF\n"
      io = create_io(RecordingRangeSource.new(pdf), chunk_size: 16)
      parser = HexaPDF::Parser.new(io, HexaPDF::Document.new)
      _xref, trailer = parser.load_revision(parser.startxref_offset)
      assert_equal(20, trailer[:Prev])

      assert_raises(HexaPDF::MalformedPDFError) { parser.load_revision(trailer[:Prev]) }
      offset, length = io.last_requested_range
      assert(offset <= trailer[:Prev] && trailer[:Prev] < offset + length,
             "expected the last requested range [#{offset}, #{length}] to cover the /Prev " \
             "offset #{trailer[:Prev]}")
    end
  end
end
