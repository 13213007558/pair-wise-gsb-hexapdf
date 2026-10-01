# -*- encoding: utf-8 -*-

require 'test_helper'
require 'stringio'
require 'zlib'
require 'hexapdf/document'
require 'hexapdf/content/redaction'

describe HexaPDF::Content::Redaction do
  before do
    @doc = HexaPDF::Document.new
    @page = @doc.pages.add
    @canvas = @page.canvas
  end

  def write_and_reopen(document = @doc)
    io = StringIO.new(''.b)
    HexaPDF::Writer.new(document, io).write
    HexaPDF::Document.new(io: StringIO.new(io.string))
  end

  def image_object(pixels, width = 4, height = 4, color_space: :DeviceRGB, components: 3)
    @doc.add({Type: :XObject, Subtype: :Image, Width: width, Height: height,
              ColorSpace: color_space, BitsPerComponent: 8, Filter: :FlateDecode},
             stream: Zlib.deflate(pixels.pack('C*')))
  end

  def form_with_image(image)
    @doc.add({Type: :XObject, Subtype: :Form, BBox: [0, 0, 100, 100],
              Resources: {XObject: {Im: image}}},
             stream: "q 50 0 0 50 0 0 cm /Im Do Q\n")
  end

  it "removes only intersecting text and preserves text positioning" do
    @canvas.font('Helvetica', size: 20)
    @canvas.character_spacing(1)
    @canvas.text('KEEP SECRET', at: [50, 500])
    @page.redact([143, 490, 158, 520])

    reopened = write_and_reopen
    assert_equal('KEEP SE RET', reopened.pages[0].extract_text)
    refute_match(/EC/, reopened.pages[0].extract_text)
    assert_match(/1 0 0 1 [0-9.]+ 500 Tm/, reopened.pages[0].contents)
    refute_match(/SECRET/, reopened.pages[0].contents)
  end

  it "copies a shared Form XObject for one placement without affecting another" do
    pixels = Array.new(4) {|x| [x * 80, 0, 0] }.product(Array.new(4) {|y| [0, y * 80, 0] }).map(&:flatten).flatten
    image = image_object(pixels)
    form = form_with_image(image)
    @canvas.xobject(form, at: [0, 0], width: 100, height: 100)
    @canvas.xobject(form, at: [200, 0], width: 100, height: 100)

    @page.redact([20, 20, 40, 40])
    reopened = write_and_reopen

    images = reopened.images.to_a
    assert_equal(2, images.length)
    edited = images.find {|candidate| candidate.stream.include?("\0\0\0".b) }
    original = images.find {|candidate| !candidate.stream.include?("\0\0\0".b) }
    assert(edited)
    assert(original)
    edited.stream.bytes.each_slice(3).with_index do |rgb, index|
      x = index % 4
      y = 3 - (index / 4)
      assert_equal([0, 0, 0], rgb) if x >= 2 && y >= 2
    end
    unreachable = reopened.task(:dereference)
    assert_empty(unreachable)
  end

  it "accounts for transformations and clipping paths" do
    @canvas.transform(2, 0, 0, 2, 100, 100) do
      @canvas.save_graphics_state
      @canvas.rectangle(10, 10, 10, 10).clip_path.end_path
      @canvas.rectangle(12, 12, 6, 6).fill
      @canvas.rectangle(30, 30, 10, 10).fill
      @canvas.restore_graphics_state
    end

    @page.redact([126, 126, 132, 132])
    reopened = write_and_reopen
    refute_match(/12 12 6 6 re\n f/, reopened.pages[0].contents)
    assert_match(/30 30 10 10 re/, reopened.pages[0].contents)
  end

  it "rejects unsupported intersecting shading without modifying the document" do
    @page.contents = "/Sh1 sh\n"
    @page.resources[:Shading] = {Sh1: {ShadingType: 1}}
    assert_raises(HexaPDF::Error) { @page.redact([0, 0, 10, 10]) }
    assert_match("/Sh1 sh", @page.contents)
  end

  it "removes intersecting vector paths as whole drawing operations" do
    @page.contents = "20 20 60 60 re S\n200 20 60 60 re f\n"
    @page.redact([30, 30, 50, 50])
    reopened = write_and_reopen
    refute_match(/20 20 60 60 re/, reopened.pages[0].contents)
    assert_match(/200 20 60 60 re/, reopened.pages[0].contents)
  end
end
