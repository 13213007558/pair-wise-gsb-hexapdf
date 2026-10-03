# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/document'
require 'hexapdf/random_access_io'
require 'stringio'

describe HexaPDF::RandomAccessIO do
  # In-memory range source that records all requested ranges. Optionally returns short blocks
  # and allows changing the version mid-read via a hook.
  class RecordingRangeBackend
    attr_reader :reads, :size
    attr_accessor :version, :max_block_size, :on_read

    def initialize(data, version: 'v1', max_block_size: nil)
      @data = data
      @size = data.bytesize
      @version = version
      @max_block_size = max_block_size
      @reads = []
    end

    def read_range(offset, length)
      @reads << [offset, length]
      @on_read&.call(self)
      length = @max_block_size if @max_block_size && @max_block_size < length
      @data.byteslice(offset, length) || ''.b
    end

    def total_bytes_read
      @reads.sum {|(_, length)| length }
    end
  end

  before do
    @data = (0...256).map {|i| i.chr(Encoding::BINARY) }.join
    @backend = RecordingRangeBackend.new(@data)
    @io = HexaPDF::RandomAccessIO.new(@backend, chunk_size: 16, cache_size: 64)
  end

  describe "initialization" do
    it "takes the size and version from the source" do
      assert_equal(256, @io.size)
      assert_equal('v1', @io.version)
      assert_equal(16, @io.chunk_size)
      assert_equal(64, @io.cache_size)
    end

    it "allows providing the size via an option" do
      source = Object.new
      def source.read_range(_offset, _length); ''.b; end
      def source.version; 1; end
      io = HexaPDF::RandomAccessIO.new(source, size: 10)
      assert_equal(10, io.size)
    end

    it "raises an error if no size information is available" do
      source = Object.new
      def source.read_range(_offset, _length); ''.b; end
      def source.version; 1; end
      assert_raises(ArgumentError) { HexaPDF::RandomAccessIO.new(source) }
    end

    it "validates the chunk_size and cache_size options" do
      assert_raises(ArgumentError) { HexaPDF::RandomAccessIO.new(@backend, chunk_size: 0) }
      assert_raises(ArgumentError) { HexaPDF::RandomAccessIO.new(@backend, chunk_size: -5) }
      assert_raises(ArgumentError) { HexaPDF::RandomAccessIO.new(@backend, cache_size: -1) }
    end
  end

  describe "IO interface" do
    it "reads data sequentially and after seeking" do
      assert_equal(0, @io.pos)
      assert_equal(@data[0, 16], @io.read(16))
      assert_equal(16, @io.pos)
      assert_equal(16, @io.tell)
      @io.seek(100)
      assert_equal(@data[100, 10], @io.read(10))
      @io.seek(-5, IO::SEEK_CUR)
      assert_equal(@data[105, 5], @io.read(5))
      @io.seek(-16, IO::SEEK_END)
      assert_equal(@data[-16..], @io.read(32)) # clamped at the end of the data
      assert(@io.eof?)
    end

    it "returns nil at the end of the data when a length is given" do
      @io.seek(256)
      assert_nil(@io.read(1))
      assert_equal('', @io.read)
      assert_equal('', @io.read(0))
    end

    it "reads all remaining data when no length is given" do
      @io.seek(200)
      assert_equal(@data[200..], @io.read)
    end

    it "stores the data into a provided outbuf" do
      buf = +''
      result = @io.read(10, buf)
      assert_same(buf, result)
      assert_equal(@data[0, 10], buf)
    end

    it "raises errors for invalid positions and arguments" do
      assert_raises(Errno::EINVAL) { @io.pos = -1 }
      assert_raises(Errno::EINVAL) { @io.seek(-100) }
      assert_raises(ArgumentError) { @io.seek(0, 99) }
      assert_raises(ArgumentError) { @io.read(-1) }
    end

    it "returns partial data if the source ends before the declared size" do
      backend = RecordingRangeBackend.new(@data[0, 50])
      io = HexaPDF::RandomAccessIO.new(backend, size: 100, chunk_size: 16)
      result = io.read(100)
      assert_equal(50, result.bytesize)
      assert_equal(@data[0, 50], result)
    end
  end

  describe "range requests" do
    it "handles sources returning short blocks" do
      backend = RecordingRangeBackend.new(@data, max_block_size: 3)
      io = HexaPDF::RandomAccessIO.new(backend, chunk_size: 16)
      assert_equal(@data[0, 20], io.read(20))
      assert_equal([0, 32], backend.reads[0])
      assert_equal([3, 29], backend.reads[1])
      assert_equal([6, 26], backend.reads[2])
      assert_operator(backend.reads.length, :>, 6)
    end

    it "merges adjacent missing chunks into a single range request" do
      io = HexaPDF::RandomAccessIO.new(@backend, chunk_size: 16)
      io.seek(4)
      assert_equal(@data[4, 20], io.read(20))
      assert_equal([[0, 32]], @backend.reads)

      io.seek(8)
      assert_equal(@data[8, 4], io.read(4)) # served from the cache
      assert_equal([[0, 32]], @backend.reads)

      io.seek(48)
      assert_equal(@data[48, 8], io.read(8))
      assert_equal([[0, 32], [48, 16]], @backend.reads)
    end

    it "reads data spanning multiple chunks" do
      @io.seek(6)
      assert_equal(@data[6, 21], @io.read(21))
    end

    it "limits the cache to the configured capacity using LRU eviction" do
      io = HexaPDF::RandomAccessIO.new(@backend, chunk_size: 16, cache_size: 32)
      io.seek(0)
      io.read(16)
      io.seek(16)
      io.read(16)
      io.seek(32)
      io.read(16) # exceeds the capacity, chunk 0 gets evicted
      assert_operator(io.cache_bytes, :<=, 32)

      io.seek(16)
      io.read(16) # chunk 1 is still cached
      assert_equal(3, @backend.reads.length)

      io.seek(0)
      io.read(16) # chunk 0 was evicted and needs to be fetched again
      assert_equal(4, @backend.reads.length)
      assert_operator(io.cache_bytes, :<=, 32)
    end

    it "works with caching disabled" do
      io = HexaPDF::RandomAccessIO.new(@backend, chunk_size: 16, cache_size: 0)
      io.read(8)
      assert_equal(0, io.cache_bytes)
      io.seek(0)
      io.read(8)
      assert_equal(2, @backend.reads.length)
    end
  end

  describe "version checking" do
    it "raises a VersionChangedError retaining the last requested range" do
      @backend.on_read = ->(backend) { backend.version = 'v2' if backend.reads.size == 2 }
      io = HexaPDF::RandomAccessIO.new(@backend, chunk_size: 16)
      io.read(8)
      io.seek(64)
      error = assert_raises(HexaPDF::RandomAccessIO::VersionChangedError) { io.read(8) }
      assert_equal([error.offset, error.length], @backend.reads.last)
      assert_equal(64, error.offset)
      assert_equal(16, error.length)
      assert_kind_of(HexaPDF::Error, error)
      refute_kind_of(HexaPDF::MalformedPDFError, error)
    end

    it "keeps failing once a version change was detected" do
      @backend.on_read = ->(backend) { backend.version = 'v2' }
      error = assert_raises(HexaPDF::RandomAccessIO::VersionChangedError) { @io.read(8) }
      assert_same(error, assert_raises(HexaPDF::RandomAccessIO::VersionChangedError) { @io.read(8) })
      @io.seek(0)
      assert_same(error, assert_raises(HexaPDF::RandomAccessIO::VersionChangedError) { @io.read(8) })
    end
  end

  describe "when reading PDF documents" do
    PAGE_COUNT = 800
    PAGES_PER_NODE = 32
    PDF_DATA_CACHE = {}

    # Builds a document with PAGE_COUNT pages in a nested page tree (like real-world large
    # PDFs) together with reasonably sized content streams, and returns it together with the
    # object number of a middle page.
    def build_document
      doc = HexaPDF::Document.new
      root = doc.catalog.pages
      middle_oid = nil
      (PAGE_COUNT / PAGES_PER_NODE).times do |node_index|
        node = doc.add({Type: :Pages, Kids: [], Count: 0})
        PAGES_PER_NODE.times do |page_index|
          page_number = node_index * PAGES_PER_NODE + page_index
          page = node.insert_page(-1)
          page[:Contents] = doc.add({}, stream: "0 0 m 100 100 l S % page #{page_number} #{'x' * 1000}")
          middle_oid = page.oid if page_number == PAGE_COUNT / 2
        end
        root[:Kids] << node
        node[:Parent] = root
        root[:Count] += PAGES_PER_NODE
      end
      [doc, middle_oid]
    end

    # Writes the built document in the given variant and returns [data, middle_oid]:
    #
    # :classic:: Classic cross-reference table.
    # :object_streams:: Cross-reference stream and object streams.
    # :incremental_classic:: Classic cross-reference table with an appended revision.
    # :incremental_object_streams:: Cross-reference stream chain with an appended revision.
    def write_variant(variant)
      doc, middle_oid = build_document
      base = StringIO.new(''.b)
      case variant
      when :classic, :incremental_classic
        doc.write(base)
      when :object_streams, :incremental_object_streams
        doc.write(base, optimize: true)
      else
        raise "unknown variant"
      end

      if variant.to_s.start_with?('incremental')
        doc = HexaPDF::Document.new(io: StringIO.new(base.string))
        doc.pages.add.contents = "0 0 m 100 100 l S % page #{PAGE_COUNT}"
        out = StringIO.new(''.b)
        doc.write(out, incremental: true)
        base = out
      end
      [base.string, middle_oid]
    end

    def pdf_data(variant)
      PDF_DATA_CACHE[variant] ||= write_variant(variant)
    end

    def open_document(data, **io_options)
      backend = RecordingRangeBackend.new(data)
      document = HexaPDF::Document.new(io: HexaPDF::RandomAccessIO.new(backend, **io_options))
      [document, backend]
    end

    [:classic, :object_streams, :incremental_classic, :incremental_object_streams].each do |variant|
      it "reads page #{PAGE_COUNT} of a #{variant} PDF without downloading everything" do
        data, = pdf_data(variant)
        doc, backend = open_document(data)
        incremental = variant.to_s.start_with?('incremental')

        assert_equal(incremental ? PAGE_COUNT + 1 : PAGE_COUNT, doc.pages.count)
        assert_includes(doc.pages[PAGE_COUNT - 1].contents, "% page #{PAGE_COUNT - 1}")
        if incremental
          assert_includes(doc.pages[PAGE_COUNT].contents, "% page #{PAGE_COUNT}")
        end
        assert_operator(backend.total_bytes_read, :<, data.bytesize / 2)
      end
    end

    it "reads the tail index but not the unused content of a classic PDF" do
      data, middle_oid = pdf_data(:classic)
      doc, backend = open_document(data, chunk_size: 1024)
      assert_includes(doc.pages[PAGE_COUNT - 1].contents, "% page #{PAGE_COUNT - 1}")

      # the cross-reference data at the end of the file was read
      assert(backend.reads.any? {|offset, length| offset + length >= data.bytesize })

      # the region around an unused middle page object was not read
      entry = doc.revisions.current.xref_section[middle_oid]
      assert_equal(:in_use, entry.type)
      refute(backend.reads.any? do |offset, length|
        offset < entry.pos + 100 && offset + length > entry.pos - 100
      end)

      assert_operator(backend.total_bytes_read, :<, data.bytesize / 2)
    end

    it "parses objects spanning cache chunks from a source returning short blocks" do
      data, = pdf_data(:classic)
      backend = RecordingRangeBackend.new(data, max_block_size: 64)
      io = HexaPDF::RandomAccessIO.new(backend, chunk_size: 256, cache_size: 2048)
      doc = HexaPDF::Document.new(io: io)
      assert_equal(PAGE_COUNT, doc.pages.count)
      assert_includes(doc.pages[0].contents, '% page 0 ')
      assert_includes(doc.pages[PAGE_COUNT - 1].contents, "% page #{PAGE_COUNT - 1}")
    end

    it "recovers from a corrupted Prev chain via cross-reference reconstruction" do
      data, = pdf_data(:incremental_classic)
      corrupted = data.sub(%r{/Prev \d+}, '/Prev 999999999')
      refute_equal(data, corrupted)

      doc, = open_document(corrupted)
      assert(doc.revisions.parser.reconstructed?)
      assert_equal(PAGE_COUNT + 1, doc.pages.count)
      assert_includes(doc.pages[PAGE_COUNT - 1].contents, "% page #{PAGE_COUNT - 1}")
    end

    it "raises a malformed PDF error for a corrupted Prev chain if reconstruction is off" do
      data, = pdf_data(:incremental_classic)
      corrupted = data.sub(%r{/Prev \d+}, '/Prev 999999999')
      backend = RecordingRangeBackend.new(corrupted)
      io = HexaPDF::RandomAccessIO.new(backend)
      error = assert_raises(HexaPDF::MalformedPDFError) do
        HexaPDF::Document.new(io: io, config: {'parser.try_xref_reconstruction' => false})
      end
      assert_kind_of(Integer, error.pos)
    end

    it "aborts parsing when the source version changes, retaining the last requested range" do
      data, = pdf_data(:classic)
      backend = RecordingRangeBackend.new(data)
      backend.on_read = ->(source) { source.version = 'v2' if source.reads.size == 3 }
      io = HexaPDF::RandomAccessIO.new(backend)
      error = assert_raises(HexaPDF::RandomAccessIO::VersionChangedError) do
        HexaPDF::Document.new(io: io)
      end
      assert_equal(backend.reads.last, [error.offset, error.length])
      assert_raises(HexaPDF::RandomAccessIO::VersionChangedError) { io.read(1) }
    end
  end
end
