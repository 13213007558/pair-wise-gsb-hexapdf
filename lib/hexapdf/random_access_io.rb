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
# following permission added to Section 15 as permitted by Section 7(a):
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
# commercial licenses are available at <https://gettalong.at/hexapdf/>.
#++

require 'hexapdf/error'

module HexaPDF

  # An IO-like adapter for reading PDF data from a random-access range source, like an object
  # storage service.
  #
  # HexaPDF only needs random access to small parts of a PDF file (the cross-reference data at
  # the end and the objects that are actually used). This adapter exposes such a source as an IO
  # object that can be passed to HexaPDF::Document.new, so that e.g. page 800 of a large document
  # can be read without downloading the whole file first.
  #
  # == Source Interface
  #
  # The wrapped source object is not bound to any cloud vendor SDK. It only needs to provide two
  # methods:
  #
  # read_range(offset, length)::
  #     Returns a binary string with at most +length+ bytes of data starting at +offset+. The
  #     source may return fewer bytes than requested (a short block); the adapter then issues
  #     follow-up requests for the missing remainder. An empty string or +nil+ signals that no
  #     more data is available.
  #
  # version::
  #     Returns an opaque value identifying the current version of the stored object (e.g. an
  #     etag or generation number). The value is captured when the adapter is created and
  #     compared (using ==) against the source's version on every fetch. If the version changes,
  #     a VersionChangedError is raised and the adapter stops serving data, so that a document
  #     can never be assembled from mixed versions.
  #
  # The total byte size of the object has to be provided via the +size+ option or via a
  # <tt>source.size</tt> method.
  #
  # Note that version checks happen when new data needs to be fetched from the source. Data
  # already held in the cache belongs to the captured version and may be served without
  # contacting the source again.
  #
  # == Caching
  #
  # Fetched data is cached in fixed-size chunks (see the +chunk_size+ option). Adjacent missing
  # chunks are merged into a single read_range call to avoid unnecessary requests. The cache
  # holds at most +cache_size+ bytes (a caller-defined limit); when the limit is exceeded, the
  # least recently used chunks are evicted.
  #
  # Example:
  #
  #   io = HexaPDF::RandomAccessIO.new(source, cache_size: 4 * 1024 * 1024)
  #   doc = HexaPDF::Document.new(io: io)
  #   page = doc.pages[799]
  class RandomAccessIO

    # Raised when the version of the source object changes while reading.
    #
    # This error is *not* a HexaPDF::MalformedPDFError, so it is never swallowed by the parser's
    # error correction or cross-reference reconstruction logic; parsing is aborted instead of
    # potentially assembling a document from mixed versions.
    class VersionChangedError < HexaPDF::Error

      # The byte offset of the range that was requested when the version change was detected.
      attr_reader :offset

      # The length of the range that was requested when the version change was detected.
      attr_reader :length

      # Creates a new VersionChangedError for the last requested range.
      def initialize(offset:, length:)
        @offset = offset
        @length = length
        super("Source object version changed while requesting range " \
              "offset=#{offset} length=#{length}")
      end

    end

    # The default number of bytes fetched and cached per chunk.
    DEFAULT_CHUNK_SIZE = 8192

    # The default maximum number of bytes held in the cache.
    DEFAULT_CACHE_SIZE = 4 * 1024 * 1024

    # The total number of bytes available from the source.
    attr_reader :size

    # The version of the source object captured when the adapter was created.
    attr_reader :version

    # The number of bytes fetched and cached per chunk.
    attr_reader :chunk_size

    # The maximum number of bytes held in the cache.
    attr_reader :cache_size

    # The number of bytes currently held in the cache.
    attr_reader :cache_bytes

    # Creates a new random-access IO adapter for the given +source+ object (see the class
    # documentation for the expected interface).
    #
    # Options:
    #
    # size::
    #     The total number of bytes of the source object. If not given, <tt>source.size</tt> is
    #     used.
    #
    # chunk_size::
    #     The granularity in bytes in which data is fetched from the source and cached. Defaults
    #     to DEFAULT_CHUNK_SIZE.
    #
    # cache_size::
    #     The maximum number of bytes held in the cache. Defaults to DEFAULT_CACHE_SIZE. A value
    #     of zero disables caching.
    def initialize(source, size: nil, chunk_size: DEFAULT_CHUNK_SIZE, cache_size: DEFAULT_CACHE_SIZE)
      @source = source
      @size = size || (source.size if source.respond_to?(:size))
      unless @size.kind_of?(Integer) && @size >= 0
        raise ArgumentError, "Total size of the source object must be given via the :size " \
                             "option or a source#size method"
      end
      unless chunk_size.kind_of?(Integer) && chunk_size > 0
        raise ArgumentError, "The chunk_size must be a positive integer"
      end
      unless cache_size.kind_of?(Integer) && cache_size >= 0
        raise ArgumentError, "The cache_size must be a non-negative integer"
      end
      @chunk_size = chunk_size
      @cache_size = cache_size
      @version = source.version
      @pos = 0
      @cache = {}
      @cache_bytes = 0
      @version_error = nil
    end

    # Returns the current byte position.
    def pos
      @pos
    end
    alias tell pos

    # Sets the current byte position.
    def pos=(new_pos)
      raise Errno::EINVAL, "Invalid position" if new_pos < 0
      @pos = new_pos
    end

    # Seeks to the given position based on +whence+ (IO::SEEK_SET, IO::SEEK_CUR or IO::SEEK_END)
    # and returns zero.
    def seek(offset, whence = IO::SEEK_SET)
      new_pos = case whence
                when IO::SEEK_SET then offset
                when IO::SEEK_CUR then @pos + offset
                when IO::SEEK_END then @size + offset
                else
                  raise ArgumentError, "invalid whence value #{whence.inspect}"
                end
      self.pos = new_pos
      0
    end

    # Returns +true+ if the current position is at or beyond the end of the data.
    def eof?
      @pos >= @size
    end

    # Reads up to +length+ bytes from the current position and advances it.
    #
    # Follows IO#read semantics: If +length+ is not given, all data up to the end is returned
    # (an empty string at end of data). If +length+ is given, +nil+ is returned when the
    # position is already at or beyond the end. If +outbuf+ is given, the data is stored in it
    # and it is returned instead of a new string.
    def read(length = nil, outbuf = nil)
      raise @version_error if @version_error
      raise ArgumentError, "negative length #{length} given" if length && length < 0

      available = @size - @pos
      if length.nil?
        result = available > 0 ? fetch(@pos, available) : String.new(encoding: Encoding::BINARY)
      elsif length == 0
        result = String.new(encoding: Encoding::BINARY)
      elsif available <= 0
        return nil
      else
        result = fetch(@pos, [length, available].min)
      end
      @pos += result.bytesize
      if outbuf
        outbuf.replace(result)
        result = outbuf
      end
      result
    end

    private

    # Returns up to +length+ bytes starting at +offset+, using the cache and fetching missing
    # chunks from the source.
    def fetch(offset, length)
      first_chunk = offset / @chunk_size
      last_chunk = (offset + length - 1) / @chunk_size
      parts = {}
      missing = []

      first_chunk.upto(last_chunk) do |index|
        if (data = cache_lookup(index))
          parts[index] = data
        else
          missing << index
        end
      end

      until missing.empty?
        run_start = missing.shift
        run_end = run_start
        run_end = missing.shift while !missing.empty? && missing.first == run_end + 1
        parts.merge!(fetch_chunks(run_start, run_end))
      end

      result = String.new(encoding: Encoding::BINARY)
      first_chunk.upto(last_chunk) do |index|
        data = parts[index]
        break unless data # the source signalled end of data unexpectedly early
        chunk_start = index * @chunk_size
        from = [offset - chunk_start, 0].max
        to = [offset + length - chunk_start, data.bytesize].min
        result << data.byteslice(from, to - from) if to > from
      end
      result
    end

    # Fetches the adjacent chunks with the given indices using a single (merged) range request,
    # stores them in the cache and returns them as a hash mapping chunk indices to data.
    #
    # Short blocks returned by the source are handled by issuing follow-up requests for the
    # missing remainder.
    def fetch_chunks(first_index, last_index)
      offset = first_index * @chunk_size
      length = [(last_index + 1) * @chunk_size, @size].min - offset
      data = String.new(encoding: Encoding::BINARY)
      while data.bytesize < length
        check_version!(offset + data.bytesize, length - data.bytesize)
        block = @source.read_range(offset + data.bytesize, length - data.bytesize)
        check_version!(offset + data.bytesize, length - data.bytesize)
        block = block.to_s.b
        break if block.empty?
        data << block
      end

      chunks = {}
      index = first_index
      pos = 0
      while pos < data.bytesize
        chunk = data.byteslice(pos, @chunk_size)
        cache_store(index, chunk)
        chunks[index] = chunk
        pos += chunk.bytesize
        index += 1
      end
      chunks
    end

    # Raises a VersionChangedError if the source's version differs from the captured one. The
    # error is memorized so that all further read attempts fail as well.
    def check_version!(offset, length)
      return if @source.version == @version
      @version_error ||= VersionChangedError.new(offset: offset, length: length)
      raise @version_error
    end

    # Returns the cached data for the chunk with the given index, marking it as most recently
    # used, or +nil+ if the chunk is not cached.
    def cache_lookup(index)
      return nil unless (data = @cache.delete(index))
      @cache[index] = data
      data
    end

    # Stores the data for the chunk with the given index in the cache, evicting least recently
    # used chunks if the byte capacity is exceeded.
    def cache_store(index, data)
      if (old = @cache.delete(index))
        @cache_bytes -= old.bytesize
      end
      @cache[index] = data
      @cache_bytes += data.bytesize
      while @cache_bytes > @cache_size && !@cache.empty?
        _, evicted = @cache.shift
        @cache_bytes -= evicted.bytesize
      end
    end

  end

end
