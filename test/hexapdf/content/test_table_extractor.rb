# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/content/table_extractor'
require 'hexapdf/document'

describe HexaPDF::Content::TableExtractor do
  # Draws a grid-based table on the given canvas.
  #
  # +xs+/+ys+:: Grid line coordinates (ys bottom to top).
  # +skip_h+:: Elementary horizontal edges to skip, as [y_index, x_index] pairs (merged cells).
  # +skip_v+:: Elementary vertical edges to skip, as [x_index, y_index] pairs.
  # +jitter+:: Maximum random-ish misalignment applied to line coordinates.
  # +pieces+:: If true, every line is drawn in two pieces with a small gap.
  # +duplicates+:: If true, every line is drawn twice.
  def draw_table(canvas, xs, ys, skip_h: [], skip_v: [], jitter: 0, pieces: false,
                 duplicates: false)
    repetitions = (duplicates ? 2 : 1)
    ys.each_with_index do |y, yi|
      xs.each_cons(2).with_index do |(x0, x1), xi|
        next if skip_h.include?([yi, xi])
        repetitions.times do |rep|
          yo = y + jitter * ((yi + xi + rep).even? ? 0.5 : -0.5)
          if pieces
            mid = (x0 + x1) / 2.0
            canvas.line(x0, yo, mid - 0.5, yo)
            canvas.line(mid + 0.5, yo, x1, yo)
          else
            canvas.line(x0, yo, x1, yo)
          end
        end
      end
    end
    xs.each_with_index do |x, xi|
      ys.each_cons(2).with_index do |(y0, y1), yi|
        next if skip_v.include?([xi, yi])
        repetitions.times do |rep|
          xo = x + jitter * ((xi + yi + rep).even? ? 0.5 : -0.5)
          if pieces
            mid = (y0 + y1) / 2.0
            canvas.line(xo, y0, xo, mid - 0.5)
            canvas.line(xo, mid + 0.5, xo, y1)
          else
            canvas.line(xo, y0, xo, y1)
          end
        end
      end
    end
    canvas.stroke
  end

  def create_page
    doc = HexaPDF::Document.new
    page = doc.pages.add
    page.canvas.font('Helvetica', size: 10)
    page
  end

  def extract(page, **options)
    HexaPDF::Content::TableExtractor.extract(page, **options)
  end

  describe "simple grid" do
    before do
      @page = create_page
      draw_table(@page.canvas, [100, 150, 200, 300], [500, 550, 600, 700])
      @page.canvas.text('A1', at: [110, 660])
      @page.canvas.text('B2', at: [160, 560])
      @table = extract(@page).first
    end

    it "finds a single table with the correct row/column boundaries" do
      assert_equal(1, extract(@page).size)
      assert_equal([100, 150, 200, 300], @table.columns)
      assert_equal([700, 600, 550, 500], @table.rows)
      assert_equal([100, 500, 300, 700], @table.bbox)
    end

    it "detects all elementary cells" do
      assert_equal(9, @table.cells.size)
      assert(@table.complete?)
      assert_empty(@table.ambiguities)
      cell = @table[0, 0]
      assert_equal(0, cell.row)
      assert_equal(0, cell.column)
      assert_equal(1, cell.row_span)
      assert_equal(1, cell.column_span)
      assert_equal([100, 600, 150, 700], cell.bbox)
      refute(cell.ambiguous?)
    end

    it "assigns text to the containing cells and leaves empty cells empty" do
      assert_equal('A1', @table[0, 0].text)
      assert_equal('B2', @table[1, 1].text)
      assert_equal('', @table[2, 2].text)
    end
  end

  it "handles lines drawn in pieces, slightly misaligned and duplicated" do
    page = create_page
    draw_table(page.canvas, [100, 150, 200, 300], [500, 550, 600, 700],
               jitter: 1, pieces: true, duplicates: true)
    page.canvas.text('A1', at: [110, 660])
    table = extract(page).first

    assert_equal([100, 150, 200, 300], table.columns.map {|x| x.round(1) })
    assert_equal([700, 600, 550, 500], table.rows.map {|y| y.round(1) })
    assert_equal(9, table.cells.size)
    assert(table.complete?)
    assert_equal('A1', table[0, 0].text)
  end

  it "detects merged cells via missing inner borders" do
    page = create_page
    # 3x3 grid; top-left 2x2 block merged, bottom row columns 1-2 merged
    draw_table(page.canvas, [100, 150, 200, 250], [400, 450, 500, 550],
               skip_h: [[2, 0], [2, 1]],      # no horizontal line at y=500 in columns 0-1
               skip_v: [[1, 1], [1, 2],       # no vertical line at x=150 in rows 0-1
                        [2, 0]])              # no vertical line at x=200 in row 2
    page.canvas.text('M', at: [110, 510])
    page.canvas.text('E', at: [210, 510])
    page.canvas.text('F', at: [210, 460])
    page.canvas.text('G', at: [110, 410])
    table = extract(page).first

    assert_equal(5, table.cells.size)
    merged = table[0, 0]
    assert_equal(2, merged.row_span)
    assert_equal(2, merged.column_span)
    assert_equal('M', merged.text)
    assert_same(merged, table[1, 1])
    assert_equal('E', table[0, 2].text)
    assert_equal('F', table[1, 2].text)
    bottom = table[2, 1]
    assert_equal(1, bottom.row_span)
    assert_equal(2, bottom.column_span)
    assert_equal('', bottom.text)
    assert_equal('G', table[2, 0].text)
    assert(table.complete?)
  end

  it "keeps adjacent tables separate" do
    page = create_page
    draw_table(page.canvas, [100, 200, 300], [500, 550, 600])
    draw_table(page.canvas, [320, 420], [500, 550, 600])
    page.canvas.text('left', at: [110, 560])
    page.canvas.text('right', at: [330, 560])
    tables = extract(page)

    assert_equal(2, tables.size)
    assert_equal([100, 200, 300], tables[0].columns)
    assert_equal([320, 420], tables[1].columns)
    assert_equal('left', tables[0][0, 0].text)
    assert_equal('right', tables[1][0, 0].text)
  end

  it "restricts the extraction to the given region" do
    page = create_page
    draw_table(page.canvas, [100, 200, 300], [500, 550, 600])
    draw_table(page.canvas, [320, 420], [500, 550, 600])
    page.canvas.text('left', at: [110, 560])
    page.canvas.text('right', at: [330, 560])

    tables = extract(page, region: [90, 490, 310, 610])
    assert_equal(1, tables.size)
    assert_equal([100, 200, 300], tables[0].columns)
    assert_equal('left', tables[0][0, 0].text)
  end

  it "records an ambiguity for partially covered edges instead of forcing a grid" do
    page = create_page
    canvas = page.canvas
    [100, 200, 300].each {|x| canvas.line(x, 500, x, 700) }
    [500, 700].each {|y| canvas.line(100, y, 300, y) }
    canvas.line(100, 600, 165, 600) # 65% of the edge from 100 to 200
    canvas.line(200, 600, 300, 600)
    canvas.stroke
    table = extract(page).first

    assert_equal(4, table.cells.size) # primary interpretation: edge present, cells split
    assert_equal(1, table.ambiguities.size)
    ambiguity = table.ambiguities.first
    assert_equal(:partial_edge, ambiguity.type)
    assert_equal(:horizontal, ambiguity.orientation)
    assert_in_delta(600, ambiguity.position)
    assert_in_delta(0.65, ambiguity.coverage)
    assert_equal(:present, ambiguity.resolution)
    assert_match(/alternative interpretation: absent/, ambiguity.message)
    assert(table[0, 0].ambiguous?)
    assert(table[1, 0].ambiguous?)
    refute(table[0, 1].ambiguous?)
  end

  it "resolves low-coverage ambiguous edges as absent" do
    page = create_page
    canvas = page.canvas
    [100, 200, 300].each {|x| canvas.line(x, 500, x, 700) }
    [500, 700].each {|y| canvas.line(100, y, 300, y) }
    canvas.line(100, 600, 135, 600) # 35% of the edge from 100 to 200
    canvas.line(200, 600, 300, 600)
    canvas.stroke
    table = extract(page).first

    assert_equal(3, table.cells.size) # primary interpretation: edge absent, cells merged
    assert_equal(2, table[0, 0].row_span)
    assert_equal(1, table.ambiguities.size)
    assert_equal(:absent, table.ambiguities.first.resolution)
  end

  it "leaves holes instead of inventing cells for incomplete grids" do
    page = create_page
    canvas = page.canvas
    # 2x2 grid where the bottom edge of the bottom-left cell is missing
    [100, 200, 300].each {|x| canvas.line(x, 500, x, 700) }
    canvas.line(100, 700, 300, 700)
    canvas.line(100, 600, 300, 600)
    canvas.line(200, 500, 300, 500) # only the right bottom edge
    canvas.stroke
    table = extract(page).first

    assert_equal(3, table.cells.size)
    refute(table.complete?)
    assert_nil(table[1, 0])
    assert_equal([100, 500, 300, 700], table.bbox)
  end

  it "supports tables drawn with rectangles" do
    page = create_page
    canvas = page.canvas
    canvas.rectangle(100, 500, 200, 200)
    canvas.line(100, 600, 300, 600)
    canvas.line(200, 500, 200, 700)
    canvas.stroke
    page.canvas.text('X', at: [110, 660])
    table = extract(page).first

    assert_equal([100, 200, 300], table.columns)
    assert_equal([700, 600, 500], table.rows)
    assert_equal(4, table.cells.size)
    assert_equal('X', table[0, 0].text)
  end

  it "ignores non-stroked paths and diagonal lines" do
    page = create_page
    canvas = page.canvas
    draw_table(canvas, [100, 200, 300], [500, 550, 600])
    canvas.rectangle(50, 50, 20, 20).fill # filled, not stroked
    canvas.line(400, 500, 450, 560).stroke # diagonal
    tables = extract(page)

    assert_equal(1, tables.size)
    assert_equal([100, 200, 300], tables[0].columns)
  end

  it "collects unassigned text runs" do
    page = create_page
    draw_table(page.canvas, [100, 200, 300], [500, 550, 600])
    page.canvas.text('inside', at: [110, 560])
    page.canvas.text('outside', at: [400, 700])
    extractor = HexaPDF::Content::TableExtractor.new(page)
    tables = extractor.extract

    assert_equal(1, tables.size)
    assert_equal('inside', tables[0][0, 0].text)
    assert_equal('outside', extractor.unassigned_text_runs.map(&:string).join)
  end

  it "is available via HexaPDF::Type::Page#extract_tables" do
    page = create_page
    draw_table(page.canvas, [100, 200, 300], [500, 550, 600])
    tables = page.extract_tables

    assert_equal(1, tables.size)
    assert_kind_of(HexaPDF::Content::TableExtractor::Table, tables.first)
  end
end
