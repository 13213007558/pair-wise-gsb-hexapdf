# -*- encoding: utf-8 -*-

require 'test_helper'
require 'stringio'
require 'hexapdf/document'

describe HexaPDF::Content::Redaction do
  before do
    @doc = HexaPDF::Document.new
    @page = @doc.pages.add
    @canvas = @page.canvas
    @canvas.font('Helvetica', size: 12)
  end

  def reloaded_page
    @doc = HexaPDF::Document.new(io: StringIO.new(@doc.write_to_string))
    @doc.pages[0]
  end

  def image_streams(page = @page)
    page.resources[:XObject].each.to_a.map(&:last).select {|object| object[:Subtype] == :Image }
  end

  it "removes text without changing following text positions" do
    @canvas.text('KEEP SECRET', at: [50, 700])
    @page.redact([93, 690, 200, 720])

    refute_includes(@page.contents, 'SECRET')
    assert_equal('KEEP', @page.extract_text.tr(' ', ''))
  end

  it "erases only the visible pixels of one image usage" do
    image = @doc.images.add(File.join(TEST_DATA_DIR, 'images', 'greyscale-8bit.png'))
    original_pixels = image.stream.bytes
    @canvas.image(image, at: [50, 500], width: 100, height: 100)
    @page.redact([100, 540, 200, 600])

    assert_equal(original_pixels, image.stream.bytes)
    redacted = (image_streams - [image]).max_by {|object| object.stream.bytes.count(0.chr) }
    pixels = redacted.stream.bytes.each_slice(5).to_a
    assert_equal([[254, 203, 0, 0, 0], [253, 203, 0, 0, 0], [254, 203, 0, 0, 0]], pixels.first(3))
    assert_equal(original_pixels.each_slice(5).to_a.last(2), pixels.last(2))
  end

  it "clones nested forms independently for each invocation" do
    image = @doc.images.add(File.join(TEST_DATA_DIR, 'images', 'greyscale-8bit.png'))
    form = @canvas.form(100, 50) do |form_canvas|
      form_canvas.font('Helvetica', size: 12)
      form_canvas.text('FORM SECRET', at: [0, 35])
      form_canvas.image(image, at: [0, 0], width: 20, height: 20)
    end
    @canvas.xobject(form, at: [50, 400])
    @canvas.xobject(form, at: [250, 400])
    @page.redact([70, 425, 150, 445], [60, 400, 90, 420], [260, 400, 290, 420])

    forms = @page.resources[:XObject].each.to_a.map(&:last)
      .select {|object| object[:Subtype] == :Form && object != form }
    assert_equal(2, forms.size)
    form_images = forms.flat_map do |form_form|
      form_form.resources[:XObject].each.to_a.map(&:last)
    end
    assert_equal(2, form_images.uniq.size)
    refute_includes(forms.first.contents, 'SECRET')
    assert_includes(forms.last.contents, 'SECRET')
  end

  it "respects transformations, clipping and text spacing" do
    image = @doc.images.add(File.join(TEST_DATA_DIR, 'images', 'greyscale-8bit.png'))
    @canvas.save_graphics_state
    @canvas.rectangle(50, 300, 50, 100).clip_path.end_path
    @canvas.transform(0, 2, -2, 0, 150, 300) do
      @canvas.image(image, at: [0, 0], width: 50, height: 50)
    end
    @canvas.restore_graphics_state
    @canvas.character_spacing(2).word_spacing(4)
    @canvas.text('A B', at: [50, 250])
    @page.redact([120, 310, 140, 390], [58, 246, 67, 260])

    assert_equal(1, image_streams.size)
    assert_same(image, image_streams.first)
    assert_equal(image.stream, image_streams.first.stream)
    refute_includes(@page.contents, 'A B')
    assert_equal('B', @page.extract_text.tr(' ', ''))
  end

  it "redacts content made visible by an intersecting clipping path" do
    @canvas.line_width(20)
    @canvas.save_graphics_state
    @canvas.rectangle(50, 180, 100, 40).clip_path.end_path
    @canvas.line(50, 200, 250, 200).stroke
    @canvas.restore_graphics_state
    @page.redact([100, 190, 140, 210])

    refute_includes(@page.contents, "S\n")
    assert_includes(@page.contents, "n\n")
  end

  it "removes intersecting vector graphics completely" do
    @canvas.line_width(10)
    @canvas.line(50, 150, 150, 150).stroke
    @canvas.line(250, 150, 350, 150).stroke
    @page.redact([90, 140, 110, 160])

    operations = []
    HexaPDF::Content::Parser.parse(@page.contents) {|operator, _| operations << operator }
    assert_includes(operations, :n)
    assert_equal(1, operations.count(:S))
    assert_equal(1, operations.count(:n))
  end

  it "removes a vector shape that completely contains a redaction area" do
    @canvas.rectangle(80, 140, 40, 40).fill
    @canvas.rectangle(200, 140, 40, 40).fill
    @page.redact([90, 150, 100, 160])

    operations = []
    HexaPDF::Content::Parser.parse(@page.contents) {|operator, _| operations << operator }
    assert_equal(2, operations.count(:f))
    assert_equal(1, operations.count(:n))
  end

  it "rejects unsupported drawing operators" do
    @page.contents = "/Sh sh\n"
    error = assert_raises(HexaPDF::Content::Redaction::RedactionError) do
      @page.redact([0, 0, 10, 10])
    end
    assert_match(/sh/, error.message)
  end

  it "rejects unknown operators" do
    @page.contents = "1 2 ZZ\n"
    error = assert_raises(HexaPDF::Content::Redaction::RedactionError) do
      @page.redact([0, 0, 10, 10])
    end
    assert_match(/ZZ/, error.message)
  end

  it "rejects composite fonts that cannot be decoded before writing" do
    @canvas.font('Inter', size: 20)
    @canvas.text('HELLO WORLD', at: [100, 700])
    error = assert_raises(HexaPDF::Content::Redaction::RedactionError) do
      @page.redact([160, 690, 260, 725])
    end
    assert_match(/composite font/, error.message)
  end

  it "rejects areas intersecting annotations" do
    annotation = @doc.add({Type: :Annot, Subtype: :Text, Rect: [20, 20, 40, 40],
                           Contents: 'annotation secret'})
    @page[:Annots] = [annotation]
    assert_raises(HexaPDF::Error) { @page.redact([30, 30, 50, 50]) }
    assert_includes(@page[:Annots].first[:Contents], 'annotation secret')
  end

  it "removes unreachable original objects from the written output" do
    image = @doc.images.add(File.join(TEST_DATA_DIR, 'images', 'greyscale-8bit.png'))
    @canvas.image(image, at: [50, 500], width: 100, height: 100)
    @page.redact([50, 500, 150, 600])
    page = reloaded_page

    assert(page.resources[:XObject].empty?)
    assert_equal(0, page.document.images.count)
  end
end
