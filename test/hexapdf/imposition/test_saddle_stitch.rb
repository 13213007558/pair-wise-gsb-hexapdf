# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf'

describe HexaPDF::Imposition::SaddleStitch do
  # Builds a 12-page source document with different page sizes and rotations, two
  # cross-page links, one external link, an outline and (non-)printable annotations.
  before do
    @source = HexaPDF::Document.new
    @pages = []
    12.times do |i|
      page = @source.pages.add([0, 0, 200, 300])
      page.canvas.font("Helvetica", size: 10).text("PAGE #{i + 1}", at: [20, 20])
      @pages << page
    end
    # Page 2 (index 1) has distinct trim and bleed boxes.
    @pages[1][:MediaBox] = [0, 0, 218, 318]
    @pages[1][:CropBox] = [9, 9, 209, 309]
    @pages[1][:TrimBox] = [9, 9, 209, 309]
    @pages[1][:BleedBox] = [3, 3, 215, 315]
    # Pages with different rotations and sizes.
    @pages[2][:MediaBox] = [0, 0, 300, 200]
    @pages[2][:Rotate] = 90
    @pages[3][:MediaBox] = [0, 0, 150, 250]
    @pages[5][:Rotate] = 180
    @pages[8][:MediaBox] = [0, 0, 300, 200]
    @pages[8][:Rotate] = 270

    # Two cross-page links (one via a named destination, one via a GoTo action) and one
    # external URI link.
    @source.destinations.add("chapter12", [@pages[11], :XYZ, 50, 250, 2])
    @pages[0][:Annots] = [@source.add({Type: :Annot, Subtype: :Link, Rect: [20, 20, 80, 40],
                                       Dest: "chapter12"})]
    @pages[4][:Annots] = [@source.add({Type: :Annot, Subtype: :Link, Rect: [30, 30, 90, 50],
                                       A: {S: :GoTo, D: [@pages[8], :FitR, 10, 10, 100, 100]}})]
    @pages[6][:Annots] = [@source.add({Type: :Annot, Subtype: :Link, Rect: [10, 10, 50, 30],
                                       A: {S: :URI, URI: "https://example.com/"}})]

    # Outline items pointing at specific positions (one on a rotated page, one nested).
    @source.outline.add_item("Start", destination: [@pages[0], :XYZ, 10, 290, nil])
    rotated = @source.outline.add_item("Rotated", destination: [@pages[8], :XYZ, 40, 60, nil])
    rotated.add_item("Sub", destination: [@pages[5], :FitH, 200])

    # A printable and a non-printable annotation on the rotated page (index 2).
    appearance = @source.add({Type: :XObject, Subtype: :Form, BBox: [0, 0, 60, 30]},
                             stream: "1 0 0 rg 0 0 60 30 re f")
    @pages[2][:Annots] = [
      @source.add({Type: :Annot, Subtype: :Square, Rect: [50, 50, 110, 80], F: 4,
                   AP: {N: appearance}}),
      @source.add({Type: :Annot, Subtype: :Square, Rect: [10, 10, 20, 20], F: 0,
                   AP: {N: appearance}}),
    ]
  end

  def impose(**options)
    HexaPDF::Imposition::SaddleStitch.new(@source, **options).impose
  end

  def operators(page)
    result = []
    HexaPDF::Content::Parser.parse(page.contents) {|op, params| result << [op, params.dup] }
    result
  end

  def cm_operators(page)
    operators(page).select {|op, _| op == :cm }.map(&:last)
  end

  def do_operators(page)
    operators(page).select {|op, _| op == :Do }
  end

  def evaluate(matrix, x, y)
    [matrix[0] * x + matrix[2] * y + matrix[4], matrix[1] * x + matrix[3] * y + matrix[5]]
  end

  # Extracts the source page numbers (1-based) placed on the left and right half of an
  # imposed sheet page, purely by inspecting the imposed document itself.
  def slot_pages(page, sheet_width)
    slots = {}
    matrix = nil
    operators(page).each do |op, params|
      case op
      when :cm
        matrix = params
      when :Do
        form = page[:Resources][:XObject][params[0]]
        next unless (match = form.stream.match(/PAGE (\d+)/))
        bbox = form[:BBox]
        center_x, = evaluate(matrix, (bbox[0] + bbox[2]) / 2.0, (bbox[1] + bbox[3]) / 2.0)
        slots[center_x < sheet_width / 2.0 ? :left : :right] = match[1].to_i
      end
    end
    slots
  end

  # Recovers the reading order from the folded sheet order of the imposed document.
  def reading_order(target, pages_per_signature, binding: :left)
    first_key, second_key = (binding == :left ? [:right, :left] : [:left, :right])
    sheet_width = target.pages[0][:MediaBox][2]
    sheets = target.pages.each_slice(2).map do |front, back|
      {front: slot_pages(front, sheet_width), back: slot_pages(back, sheet_width)}
    end
    order = []
    sheets.each_slice(pages_per_signature / 4) do |signature|
      signature.each {|sheet| order << sheet[:front][first_key] << sheet[:back][second_key] }
      signature.reverse_each do |sheet|
        order << sheet[:back][first_key] << sheet[:front][second_key]
      end
    end
    order.compact
  end

  def assert_same_page(expected, actual)
    assert_equal expected.oid, actual.oid
    assert_equal expected.gen, actual.gen
  end

  # Serializes the document for comparison, ignoring the trailer dictionary which contains
  # the randomly generated /ID entry.
  def serialized(doc)
    output = doc.write_to_string(validate: false)
    head, _trailer, tail = output.partition("trailer\n")
    "#{head}#{tail[/startxref\n(\d+)/, 1]}"
  end

  it "validates the options" do
    assert_raises(ArgumentError) do
      HexaPDF::Imposition::SaddleStitch.new(@source, pages_per_signature: 5)
    end
    assert_raises(ArgumentError) do
      HexaPDF::Imposition::SaddleStitch.new(@source, binding: :top)
    end
    assert_raises(ArgumentError) do
      HexaPDF::Imposition::SaddleStitch.new(@source, duplex: :middle)
    end
    assert_raises(ArgumentError) do
      HexaPDF::Imposition::SaddleStitch.new(@source, creep: -1)
    end
    assert_raises(ArgumentError) do
      HexaPDF::Imposition::SaddleStitch.new(@source, paper_size: :unknown)
    end
    assert_raises(ArgumentError) do
      HexaPDF::Imposition::SaddleStitch.new(@source, paper_size: [1, 2, 3])
    end
  end

  it "rejects documents without pages" do
    assert_raises(HexaPDF::Error) { HexaPDF::Imposition::SaddleStitch.new(HexaPDF::Document.new) }
  end

  it "rejects documents with interactive forms" do
    @source.catalog[:AcroForm] = {Fields: [@source.add({FT: :Tx, T: "test"})]}
    error = assert_raises(HexaPDF::Error) { impose }
    assert_match(/interactive forms/, error.message)
  end

  it "imposes the pages in the correct front/back sheet order" do
    imposer = HexaPDF::Imposition::SaddleStitch.new(@source, pages_per_signature: 4,
                                                    paper_size: [420, 320], duplex: :short_edge)
    expected = [
      [0, 0, :front, 3, 0], [0, 0, :back, 1, 2],
      [1, 0, :front, 7, 4], [1, 0, :back, 5, 6],
      [2, 0, :front, 11, 8], [2, 0, :back, 9, 10],
    ]
    actual = imposer.layout.map do |sheet|
      [sheet[:signature], sheet[:sheet], sheet[:side],
       sheet[:slots][:left][:source], sheet[:slots][:right][:source]]
    end
    assert_equal expected, actual

    target = imposer.impose
    assert_equal 6, target.pages.count
    assert_equal (1..12).to_a, reading_order(target, 4)
  end

  it "supports right binding with mirrored page order" do
    imposer = HexaPDF::Imposition::SaddleStitch.new(@source, pages_per_signature: 4,
                                                    paper_size: [420, 320], binding: :right,
                                                    duplex: :short_edge)
    expected = [
      [0, 0, :front, 0, 3], [0, 0, :back, 2, 1],
      [1, 0, :front, 4, 7], [1, 0, :back, 6, 5],
      [2, 0, :front, 8, 11], [2, 0, :back, 10, 9],
    ]
    actual = imposer.layout.map do |sheet|
      [sheet[:signature], sheet[:sheet], sheet[:side],
       sheet[:slots][:left][:source], sheet[:slots][:right][:source]]
    end
    assert_equal expected, actual
    assert_equal (1..12).to_a, reading_order(imposer.impose, 4, binding: :right)
  end

  it "computes the slot geometry for pages with different sizes and rotations" do
    imposer = HexaPDF::Imposition::SaddleStitch.new(@source, pages_per_signature: 4,
                                                    paper_size: [420, 320], duplex: :short_edge)
    front, back = imposer.layout

    # Smaller page (150x250) centered in the left slot.
    assert_equal [1, 0, 0, 1, 30, 35], front[:slots][:left][:matrix]
    assert_equal [30, 35, 180, 285], front[:slots][:left][:trim]
    # Standard page in the right slot.
    assert_equal [1, 0, 0, 1, 215, 10], front[:slots][:right][:matrix]
    assert_equal [215, 10, 415, 310], front[:slots][:right][:trim]
    assert_equal [30, 10, 415, 310], front[:trim_box]

    # Page with distinct trim/bleed boxes in the left slot.
    assert_equal [1, 0, 0, 1, -4, 1], back[:slots][:left][:matrix]
    assert_equal [5, 10, 205, 310], back[:slots][:left][:trim]
    assert_equal [-1, 4, 211, 316], back[:slots][:left][:bleed]
    # Page rotated by 90 degrees in the right slot.
    assert_equal [0, -1, 1, 0, 215, 310], back[:slots][:right][:matrix]
    assert_equal [215, 10, 415, 310], back[:slots][:right][:trim]
    assert_equal [5, 10, 415, 310], back[:trim_box]
    assert_equal [0, 4, 415, 316], back[:bleed_box]
  end

  it "keeps trim and bleed distinct on the imposed sheets" do
    target = impose(pages_per_signature: 4, paper_size: [420, 320], duplex: :short_edge)
    assert_equal [0, 0, 420, 320], target.pages[1][:MediaBox].to_a
    assert_equal [5, 10, 415, 310], target.pages[1][:TrimBox].to_a
    assert_equal [0, 4, 415, 316], target.pages[1][:BleedBox].to_a
    assert_equal [30, 10, 415, 310], target.pages[0][:TrimBox].to_a
  end

  it "places the page content with the computed matrices" do
    target = impose(pages_per_signature: 4, paper_size: [420, 320], duplex: :short_edge)
    assert_equal [[1, 0, 0, 1, 30, 35], [1, 0, 0, 1, 215, 10]], cm_operators(target.pages[0])
    back_cms = cm_operators(target.pages[1])
    assert_equal [1, 0, 0, 1, -4, 1], back_cms[0]
    assert_equal [0, -1, 1, 0, 215, 310], back_cms[1]
  end

  it "rotates the back sides when the duplex flipping axis is horizontal" do
    imposer = HexaPDF::Imposition::SaddleStitch.new(@source, pages_per_signature: 4,
                                                    paper_size: [420, 320], duplex: :long_edge)
    front, back = imposer.layout
    # Front sides are not rotated.
    assert_equal [1, 0, 0, 1, 30, 35], front[:slots][:left][:matrix]
    # Back sides are rotated 180 degrees around the sheet center.
    assert_equal [-1, 0, 0, -1, 424, 319], back[:slots][:left][:matrix]
    assert_equal [215, 10, 415, 310], back[:slots][:left][:trim]
    assert_equal [0, 1, -1, 0, 205, 10], back[:slots][:right][:matrix]
    assert_equal [5, 10, 205, 310], back[:slots][:right][:trim]
  end

  it "does not rotate the back sides when the duplex flipping axis is vertical" do
    imposer = HexaPDF::Imposition::SaddleStitch.new(@source, pages_per_signature: 4,
                                                    paper_size: [420, 320], duplex: :short_edge)
    assert_equal [1, 0, 0, 1, -4, 1], imposer.layout[1][:slots][:left][:matrix]
  end

  it "shifts the content outwards by the creep amount per sheet layer" do
    imposer = HexaPDF::Imposition::SaddleStitch.new(@source, pages_per_signature: 12,
                                                    paper_size: [420, 320], duplex: :short_edge,
                                                    creep: 2)
    layout = imposer.layout
    # Outermost sheet: no creep.
    assert_equal [1, 0, 0, 1, 5, 10], layout[0][:slots][:left][:matrix]
    # Second sheet: 2pt creep away from the spine.
    assert_equal [1, 0, 0, 1, 3, 10], layout[2][:slots][:left][:matrix]
    assert_equal [3, 10, 203, 310], layout[2][:slots][:left][:trim]
    assert_equal [0, -1, 1, 0, 217, 310], layout[2][:slots][:right][:matrix]
    # Innermost sheet: 4pt creep.
    assert_equal [1, 0, 0, 1, 1, 10], layout[4][:slots][:left][:matrix]
    assert_equal [1, 0, 0, 1, 219, 10], layout[4][:slots][:right][:matrix]
  end

  it "pads the last signature with blank pages" do
    imposer = HexaPDF::Imposition::SaddleStitch.new(@source, pages_per_signature: 16,
                                                    paper_size: [420, 320], duplex: :short_edge)
    blank_slots = imposer.layout.each_with_index.with_object([]) do |(sheet, index), result|
      result << [index, :left] unless sheet[:slots][:left][:source]
      result << [index, :right] unless sheet[:slots][:right][:source]
    end
    assert_equal [[0, :left], [1, :right], [2, :left], [3, :right]], blank_slots

    target = imposer.impose
    assert_equal 8, target.pages.count
    # Blank slots produce no content on the imposed sheets.
    assert_equal({right: 1}, slot_pages(target.pages[0], 420))
    assert_equal({left: 2}, slot_pages(target.pages[1], 420))
    assert_equal({right: 3}, slot_pages(target.pages[2], 420))
    assert_equal({left: 4}, slot_pages(target.pages[3], 420))
    assert_equal({left: 12, right: 5}, slot_pages(target.pages[4], 420))
    assert_equal 1, do_operators(target.pages[0]).size
    assert_equal 2, do_operators(target.pages[4]).size
    assert_equal (1..12).to_a, reading_order(target, 16)
  end

  it "recovers the reading order for a single multi-sheet signature" do
    target = impose(pages_per_signature: 12, paper_size: [420, 320], duplex: :short_edge)
    assert_equal 6, target.pages.count
    assert_equal (1..12).to_a, reading_order(target, 12)
  end

  it "recreates link annotations with transformed rectangles and remapped destinations" do
    target = impose(pages_per_signature: 4, paper_size: [420, 320], duplex: :short_edge)

    # Link from page 1 (index 0) to page 12 (index 11) via a named destination.
    annotations = target.pages[0][:Annots]
    assert_equal 1, annotations.size
    link = annotations[0]
    assert_equal :Link, link[:Subtype]
    assert_equal [235, 30, 295, 50], link[:Rect].to_a
    destination = link[:Dest]
    assert_same_page target.pages[4], target.deref(destination[0])
    assert_equal :XYZ, destination[1]
    assert_equal [55, 260, 2], destination[2..4].to_a

    # Link from page 5 (index 4) to a FitR destination on the rotated page 9 (index 8).
    annotations = target.pages[2][:Annots]
    assert_equal 1, annotations.size
    link = annotations[0]
    assert_equal [245, 40, 305, 60], link[:Rect].to_a
    action = link[:A]
    assert_equal :GoTo, action[:S]
    destination = action[:D]
    assert_same_page target.pages[4], target.deref(destination[0])
    assert_equal :FitR, destination[1]
    assert_equal [315, 20, 405, 110], destination[2..5].to_a
  end

  it "copies external link actions unchanged" do
    target = impose(pages_per_signature: 4, paper_size: [420, 320], duplex: :short_edge)
    annotations = target.pages[3][:Annots]
    assert_equal 1, annotations.size
    action = annotations[0][:A]
    assert_equal :URI, action[:S]
      assert_equal "https://example.com/", action[:URI]
  end

  it "copies the outline with remapped destinations" do
    target = impose(pages_per_signature: 4, paper_size: [420, 320], duplex: :short_edge)

    start_item = target.outline[:First]
    assert_equal "Start", start_item.title
    destination = start_item[:Dest]
    assert_same_page target.pages[0], target.deref(destination[0])
    assert_equal :XYZ, destination[1]
    assert_equal [225, 300], destination[2..3].to_a

    rotated = start_item[:Next]
    assert_equal "Rotated", rotated.title
    destination = rotated[:Dest]
    assert_same_page target.pages[4], target.deref(destination[0])
    assert_equal :XYZ, destination[1]
    assert_equal [355, 50], destination[2..3].to_a

    sub = rotated[:First]
    assert_equal "Sub", sub.title
    destination = sub[:Dest]
    assert_same_page target.pages[3], target.deref(destination[0])
    assert_equal :FitH, destination[1]
    assert_equal [110], destination[2..2].to_a
  end

  it "flattens printable annotations and skips non-printable ones" do
    target = impose(pages_per_signature: 4, paper_size: [420, 320], duplex: :short_edge)
    # Page 2 (index 1) carries the rotated page (index 2) with the annotations.
    dos = do_operators(target.pages[1])
    assert_equal 3, dos.size
    cms = cm_operators(target.pages[1])
    # The appearance is drawn with the page's placement matrix followed by the mapping of
    # the appearance bounding box to the annotation rectangle.
    assert_equal [0, -1, 1, 0, 215, 310], cms[-2]
    assert_equal [1, 0, 0, 1, 50, 50], cms[-1]
    # The non-printable annotation (F=0) is not flattened; only one appearance was drawn.
    appearance_count = target.pages[1][:Resources][:XObject].value.count do |_name, xobject|
      target.deref(xobject).stream.include?("re f")
    end
    assert_equal 1, appearance_count
  end

  it "does not modify the source document" do
    snapshot = serialized(@source)
    impose(pages_per_signature: 4, paper_size: [420, 320], duplex: :short_edge)
    assert_equal snapshot, serialized(@source)
  end

  it "accepts a predefined paper size symbol" do
    target = impose(pages_per_signature: 4, paper_size: :A4, duplex: :short_edge)
    assert_equal 6, target.pages.count
    assert_equal [0, 0, 595.275591, 841.889764], target.pages[0][:MediaBox].to_a
  end
end
