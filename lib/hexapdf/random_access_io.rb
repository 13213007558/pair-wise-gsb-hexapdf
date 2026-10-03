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

  # An IO-like adapter that provides random access to a byte source which only supports ranged
  # reads, like an object in an object storage service.
  #
  # The source object has to provide the following methods:
  #
  # [read_range(offset, length)]
  #   Returns up to +length+ bytes starting at +offset+ as a String, or +nil+/an empty String if
  #   there is no more data. The returned data may be shorter than requested (a "short read");
  #   the adapter automatically continues reading until the request is fulfilled or the end of
  #   the data is reached.
  # [version]
  #   Returns an object that identifies the current version of the data (e.g. an etag or
  #   generation number). The version is captured when the adapter is created. As soon as the
  #   version changes, all further reads fail with a VersionChangedError so that a document is
  #   never assembled from bytes of mixed versions.
  #
  # Optionally the source may provide a +size+ method returning the total number of bytes;
  # otherwise the size has to be passed via the +size+ keyword argument.
  #
  # The adapter is deliberately agnostic of any concrete service: it does not depend on a cloud
  # vendor SDK and it does not implement retry policies - transient failure handling belongs to
  # the source implementation.
  #
  # Reads are served through a bounded chunk cache. Consecutive missing chunks are coalesced
  # into a single read_range call to avoid many small requests. The maximum number of cached
  # bytes is defined by the caller via +cache_capacity+.
  #
  # Example:
  #
  #   io = HexaPDF::RandomAccessIO.new(source, chunk_size: 256 * 1024)
  #   doc = HexaPDF::Document.new(io: io)
  #   doc.pages[799] # only the needed byte ranges are fetched from the source
  class RandomAccessIO

    # Generic read error raised by HexaPDF::RandomAccessIO.
    #
    # The error retains the byte range (offset and length) of the last requested read so that
    # callers can inspect or log which part of the input was being read when the error occured.
    class ReadError < HexaPDF::Error

      # The byte offset of the last requested range.
      attr_reader :offset

      # The byte length of the last requested range.
      attr_reader :length

      # Creates a new ReadError for the given byte range.
      def initialize(message, offset:, length:)
        @offset = offset
        @length = length
        super(message)
      end

      def message # :nodoc:
        "#{super} (last requested range: offset=#{offset}, length=#{length})"
      end

    end

    # Raised when the version of the source changes while the adapter is in use.
    class VersionChangedError < ReadError; end

    # The underlying source object.
    attr_reader :source

    # The total number of bytes of the source.
    attr_reader :size

    # The byte size of the chunks used for caching and read coalescing.
    attr_reader :chunk_size

    # The maximum number of bytes held by the cache.
    attr_reader :cache_capacity

    # The number of bytes currently held by the cache.
    attr_reader :cache_bytes

    # The version of the source captured when the adapter was created.
    attr_reader :version

    # The last requested byte range as array <code>[offset, length]</code> (after clamping to
    # the available data). Useful for correlating errors raised by higher layers with the input
    # range that was read last.
    attr_reader :last_requested_range

    # Creates a new random access adapter for the given +source+.
    #
    # Options:
    #
    # size::
    #     The total number of bytes of the source. If not given, <code>source.size</code> is
    #     used.
    # chunk_size::
    #     The byte size of the chunks that are fetched and cached as a unit. Default: 64KiB.
    # cache_capacity::
    #     The maximum number of bytes held by the cache. Once the capacity is exceeded, the
    #     least recently used chunks are evicted. Default: 4MiB.
    def initialize(source, size: nil, chunk_size: 64 * 1024, cache_capacity: 4 * 1024 * 1024)
      raise ArgumentError, "chunk_size must be a positive number" if chunk_size <= 0
      raise ArgumentError, "cache_capacity must not be negative" if cache_capacity < 0

      @source = source
      @size = size || (source.size if source.respond_to?(:size))
      unless @size
        raise ArgumentError, "size has to be given if the source doesn't provide it"
      end
      @chunk_size = chunk_size
      @cache_capacity = cache_capacity
      @version = source.version
      @pos = 0
      @cache = {}
      @cache_bytes = 0
      @last_requested_range = [0, 0]
      @closed = false
    end

    # Reads +length+ bytes (or, if +length+ is +nil+, all remaining bytes) starting at the
    # current position and advances the position by the number of bytes read.
    #
    # If +outbuf+ is given, it is replaced with the read data and returned.
    #
    # Follows IO#read semantics: returns +nil+ if +length+ is positive and the current position
    # is at or beyond the end of the data, and an empty String when reading zero bytes or when
    # +length+ is +nil+ and no data is left.
    def read(length = nil, outbuf = nil)
      check_open
      nil_length = length.nil?
      length = @size - @pos if nil_length
      raise ArgumentError, "negative length #{length} given" if length < 0

      requested = length
      length = @size - @pos if length > @size - @pos
      length = 0 if length < 0
      @last_requested_range = [@pos, length]
      verify_version!(@pos, length)

      data = if length > 0
               read_cached(@pos, length)
             elsif nil_length || requested == 0
               +"".b
             end
      @pos += data.bytesize if data

      if outbuf
        outbuf.replace(data || +"".b)
        outbuf
      else
        data
      end
    end

    # Seeks to the given position, following IO#seek semantics. Returns 0.
    def seek(offset, whence = ::IO::SEEK_SET)
      check_open
      new_pos = case whence
                when ::IO::SEEK_SET then offset
                when ::IO::SEEK_CUR then @pos + offset
                when ::IO::SEEK_END then @size + offset
                else
                  raise ArgumentError, "unknown whence #{whence.inspect}"
                end
      raise Errno::EINVAL, "Invalid argument - seek to negative position" if new_pos < 0

      @pos = new_pos
      0
    end

    # Returns the current position.
    def pos
      @pos
    end
    alias tell pos

    # Sets the current position and returns it.
    def pos=(pos)
      seek(pos)
      pos
    end

    # Seeks to the beginning of the data. Returns 0.
    def rewind
      seek(0)
    end

    # Returns +true+ if the current position is at or beyond the end of the data.
    def eof?
      @pos >= @size
    end
    alias eof eof?

    # Closes the adapter. The source itself is not closed.
    def close
      @closed = true
      @cache.clear
      @cache_bytes = 0
      nil
    end

    # Returns +true+ if the adapter is closed.
    def closed?
      @closed
    end

    # Provided for IO compatibility; does nothing since the data is binary anyway. Returns
    # +self+.
    def binmode
      self
    end

    private

    # Raises ::IOError if the adapter is closed.
    def check_open
      raise ::IOError, "closed stream" if @closed
    end

    # Raises a VersionChangedError if the current version of the source differs from the
    # version captured when the adapter was created.
    def verify_version!(offset, length)
      current = @source.version
      return if current == @version

      raise VersionChangedError.new(
        "source version changed from #{@version.inspect} to #{current.inspect}, " \
        "aborting to avoid a document assembled from mixed versions",
        offset: offset, length: length
      )
    end

    # Reads +length+ bytes starting at +offset+ using the chunk cache.
    def read_cached(offset, length)
      return backend_read(offset, length) if @cache_capacity < @chunk_size

      first_index = offset / @chunk_size
      last_index = (offset + length - 1) / @chunk_size
      fetch_chunks(first_index, last_index)

      data = +"".b
      first_index.upto(last_index) do |index|
        chunk = cached_chunk(index) || fetch_chunk_directly(index)
        data << chunk
      end
      data.byteslice(offset - first_index * @chunk_size, length)
    end

    # Fetches all missing chunks in the given index range, coalescing consecutive missing
    # chunks into a single read_range call on the source.
    def fetch_chunks(first_index, last_index)
      index = first_index
      while index <= last_index
        if chunk_cached?(index)
          index += 1
          next
        end
        first_missing = index
        index += 1
        index += 1 while index <= last_index && !chunk_cached?(index)
        fetch_chunk_range(first_missing, index - 1)
      end
    end

    # Fetches the consecutive chunks with the given indices with a single read and stores them
    # in the cache.
    def fetch_chunk_range(first_index, last_index)
      offset = first_index * @chunk_size
      length = chunk_end_offset(last_index) - offset
      data = backend_read(offset, length)
      first_index.upto(last_index) do |index|
        chunk = data.byteslice((index - first_index) * @chunk_size, @chunk_size)
        break unless chunk

        store_chunk(index, chunk)
      end
    end

    # Fetches a single chunk without storing it in the cache. Used as a fallback when a chunk
    # was evicted before it could be consumed (i.e. when the cache capacity is smaller than a
    # single chunk).
    def fetch_chunk_directly(index)
      offset = index * @chunk_size
      backend_read(offset, chunk_end_offset(index) - offset)
    end

    # Returns the end offset (exclusive) of the chunk with the given index, clamped to the size
    # of the source.
    def chunk_end_offset(index)
      [(index + 1) * @chunk_size, @size].min
    end

    # Reads exactly +length+ bytes starting at +offset+ from the source, transparently handling
    # short reads of the source.
    #
    # The version of the source is verified before and after each individual read_range call so
    # that a version change at any point aborts the operation.
    def backend_read(offset, length)
      verify_version!(offset, length)
      data = +"".b
      while data.bytesize < length
        piece = begin
          @source.read_range(offset + data.bytesize, length - data.bytesize)
        rescue HexaPDF::Error
          raise
        rescue StandardError => e
          raise ReadError.new("source failed to read range: #{e.message} (#{e.class})",
                              offset: offset + data.bytesize, length: length - data.bytesize)
        end
        verify_version!(offset, length)
        break if piece.nil? || piece.empty?

        data << piece.b
      end
      if data.bytesize < length
        raise ReadError.new("source returned fewer bytes than requested (#{data.bytesize} " \
                            "instead of #{length})", offset: offset, length: length)
      end
      data
    end

    # Returns +true+ if the chunk with the given index is currently cached.
    def chunk_cached?(index)
      @cache.key?(index)
    end

    # Returns the cached chunk with the given index, or +nil+ if it is not cached.
    def cached_chunk(index)
      if (chunk = @cache.delete(index))
        @cache[index] = chunk
      end
      chunk
    end

    # Stores the chunk with the given index in the cache, evicting the least recently used
    # chunks if the cache capacity is exceeded.
    def store_chunk(index, chunk)
      return if @cache_capacity <= 0

      if (old = @cache.delete(index))
        @cache_bytes -= old.bytesize
      end
      @cache[index] = chunk
      @cache_bytes += chunk.bytesize
      while @cache_bytes > @cache_capacity && !@cache.empty?
        _, evicted = @cache.shift
        @cache_bytes -= evicted.bytesize
      end
    end

  end

end
