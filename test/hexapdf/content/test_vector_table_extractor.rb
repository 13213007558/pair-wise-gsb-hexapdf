# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/content/vector_table_extractor'
require 'hexapdf/document'

describe HexaPDF::Content::VectorTableExtractor do
  before do
    @doc = HexaPDF::Document.new
    @page = @doc.pages.add([0, 0, 400, 400])
  end

  def stroke_lines(canvas, lines)
    lines.each {|line| canvas.line(*line) }
    canvas.stroke
  end

  def table_pdf
    canvas = @page.canvas.stroke_color(0).line_width(1)
    lines = [
      [20, 100, 70, 100], [71, 100, 120, 100],
      [20, 190, 70, 190], [71, 190, 120, 190],
      [20, 220, 120, 220],
      [20, 100, 20, 220],
      [70, 100, 70, 190],
      [120, 100, 120, 220]
    ]
    stroke_lines(canvas, lines)
    canvas.line(20, 220.3, 120, 220.3).stroke
    canvas.rectangle(124, 100, 60, 120).stroke
    canvas.line(124, 160, 184, 160).stroke
    canvas.move_to(10, 20).curve_to(90, 60, p1: [40, 60], p2: [60, 20]).stroke
    canvas.font('Helvetica', size: 10).
      text('Top', at: [56, 205]).
      text('Left', at: [29, 130]).
      text('Right', at: [80, 130]).
      text('Other', at: [132, 190])
  end

  it "extracts merged and empty cells from a generated PDF" do
    table_pdf
    tables = @page.extract_vector_tables(area: [0, 80, 210, 240])

    assert_equal(2, tables.size)
    table = tables[0]
    assert_in_delta(20, table.left)
    assert_in_delta(100, table.bottom)
    assert_in_delta(120, table.right)
    assert_in_delta(220.0, table.top)
    assert_equal([0, 1, 1], table.cells.map(&:row))
    assert_equal([0, 0, 1], table.cells.map(&:column))
    assert_equal([1, 1, 1], table.cells.map(&:row_span))
    assert_equal([2, 1, 1], table.cells.map(&:column_span))
    assert_equal(['Top', 'Left', 'Right'], table.cells.map(&:text))
    assert_equal([100.0, 190.0, 220.0], table.row_boundaries)
    assert_equal([20.0, 70.0, 120.0], table.column_boundaries)
    ambiguity_types = table.ambiguities.map(&:type)
    assert_equal(3, ambiguity_types.count(:bridged_line_gap))
    assert_equal(4, ambiguity_types.count(:approximate_junction))
  end

  it "keeps neighboring tables separate even with a small aligned gap" do
    table_pdf
    tables = @page.extract_vector_tables(area: [0, 80, 210, 240], gap_tolerance: 6)

    assert_equal([120.0, 184.0], tables.map(&:right))
    assert_equal([3, 2], tables.map {|table| table.cells.size })
  end

  it "does not connect bezier curves" do
    table_pdf
    processor = HexaPDF::Content::VectorTableExtractor::Processor.new
    @page.process_contents(processor)

    assert_equal(14, processor.segments.size)
    assert_equal(2, @page.extract_vector_tables(area: [0, 80, 210, 240]).size)
  end

  it "does not treat bezier curves as missing cell borders" do
    canvas = @page.canvas.stroke_color(0)
    stroke_lines(canvas, [
      [20, 100, 100, 100],
      [20, 130, 100, 130],
      [20, 100, 20, 130]
    ])
    canvas.move_to(100, 100).curve_to(100, 130, p1: [120, 105], p2: [120, 125]).stroke

    tables = @page.extract_vector_tables(area: [0, 90, 120, 140])

    assert_empty(tables)
  end

  it "ignores filled paths and paths discarded with n" do
    canvas = @page.canvas
    canvas.rectangle(20, 250, 20, 20).fill
    canvas.rectangle(50, 250, 20, 20).end_path
    processor = HexaPDF::Content::VectorTableExtractor::Processor.new

    @page.process_contents(processor)

    assert_empty(processor.segments)
  end

  it "assigns text inside rectangles" do
    table_pdf
    table = @page.extract_vector_tables(area: [120, 80, 190, 230]).first

    assert_equal(2, table.cells.size)
    assert_equal(['Other', ''], table.cells.map(&:text))
  end

  it "rejects invalid areas and tolerances" do
    assert_raises(ArgumentError) { @page.extract_vector_tables(area: [0, 0, 10]) }
    assert_raises(ArgumentError) { @page.extract_vector_tables(area: [0, 0, 0, 10]) }
    assert_raises(ArgumentError) { @page.extract_vector_tables(alignment_tolerance: -1) }
    assert_raises(ArgumentError) { @page.extract_vector_tables(gap_tolerance: -1) }
  end

  it "can be invoked through the content module" do
    table_pdf
    tables = HexaPDF::Content::VectorTableExtractor.extract(@page, area: [0, 80, 210, 240])

    assert_equal(2, tables.size)
  end

  it "uses PDF user-space coordinates after transformations" do
    @page.canvas.transform(2, 0, 0, 2, 10, 20) do
      @page.canvas.stroke_color(0).rectangle(0, 0, 30, 20).stroke
      @page.canvas.line(0, 10, 30, 10).stroke
      @page.canvas.font('Helvetica', size: 5).text('X', at: [8, 12])
    end

    table = @page.extract_vector_tables(area: [0, 0, 80, 80]).first

    assert_equal([20.0, 40.0, 60.0], table.row_boundaries)
    assert_equal([10.0, 70.0], table.column_boundaries)
    assert_equal(['X', ''], table.cells.map(&:text))
  end

  it "accepts slightly skewed axis lines only within tolerance" do
    canvas = @page.canvas.stroke_color(0)
    canvas.line(20, 100, 80, 100.4).stroke
    canvas.line(20, 130, 80, 130).stroke
    canvas.line(20.1, 100, 20, 130).stroke
    canvas.line(79.9, 100, 80, 130).stroke

    assert_equal(1, @page.extract_vector_tables(area: [0, 90, 100, 140]).size)
    assert_empty(@page.extract_vector_tables(area: [0, 90, 100, 140], alignment_tolerance: 0.2))
  end

  it "preserves multi-line cell text" do
    canvas = @page.canvas.stroke_color(0)
    canvas.rectangle(20, 250, 80, 50).stroke
    canvas.font('Helvetica', size: 10).text('Line1', at: [35, 280]).text('Line2', at: [35, 265])

    table = @page.extract_vector_tables(area: [0, 240, 110, 310]).first

    assert_equal("Line1\nLine2", table.cells.first.text)
  end

  it "reconstructs spaces between separately positioned text runs" do
    canvas = @page.canvas.stroke_color(0)
    canvas.rectangle(20, 300, 100, 40).stroke
    canvas.font('Helvetica', size: 10).text('Hello', at: [25, 315]).text('World', at: [68, 315])

    table = @page.extract_vector_tables(area: [0, 290, 130, 350]).first

    assert_equal('Hello World', table.cells.first.text)
  end

  it "does not invent missing borders" do
    canvas = @page.canvas.stroke_color(0)
    stroke_lines(canvas, [
      [60, 100, 100, 100],
      [60, 130, 100, 130],
      [20, 160, 100, 160],
      [20, 100, 20, 160],
      [60, 100, 60, 126],
      [60, 127, 60, 160],
      [100, 100, 100, 160]
    ])
    canvas.font('Helvetica', size: 10).text('Open', at: [28, 140])

    tables = @page.extract_vector_tables(area: [0, 80, 120, 180], gap_tolerance: 3)
    local = tables.find {|table| table.cells.any? {|cell| cell.bottom == 100 && cell.top == 130 } }

    refute_nil(local)
    assert_includes(local.row_boundaries, 100.0)
    assert(local.cells.any? {|cell| cell.text == '' })
  end

  it "reports an incomplete grid without inventing cells" do
    canvas = @page.canvas.stroke_color(0)
    stroke_lines(canvas, [
      [20, 100, 100, 100],
      [20, 130, 100, 130],
      [20, 160, 100, 160],
      [60, 105, 60, 126],
      [60, 134, 60, 155],
      [90, 105, 90, 120]
    ])

    table = @page.extract_vector_tables(area: [0, 80, 120, 180], alignment_tolerance: 5,
                                        gap_tolerance: 5).first

    assert_empty(table.cells)
    assert_includes(table.ambiguities.map(&:type), :incomplete_grid)
  end
end
