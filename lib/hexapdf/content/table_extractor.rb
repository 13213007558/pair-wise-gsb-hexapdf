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
# following permission added to Section 15 as permitted in Section 7(a):
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

require 'hexapdf/content/processor'
require 'hexapdf/content/smart_text_extractor'

module HexaPDF
  module Content

    # Extracts tables that are drawn with horizontal and vertical vector lines from a page.
    #
    # == General Information
    #
    # Many PDF documents contain tables whose grid is drawn with stroked line segments
    # (operators 'm'/'l'/'re' combined with 'S', 's', 'B' or 'b'). This class reconstructs the
    # grid topology of such tables on a given page (optionally restricted to a rectangular
    # region) and assigns the page's text to the detected cells.
    #
    # Only vector graphics are analyzed; there is no OCR or raster image recognition involved.
    #
    # == Algorithm
    #
    # 1. All stroked, axis-aligned line segments (in user space) are collected together with
    #    the text runs of the page.
    #
    # 2. Nearly collinear segments are snapped onto common grid lines and overlapping,
    #    duplicated or slightly gapped pieces are merged. This handles lines that are drawn in
    #    multiple pieces, are slightly misaligned or are painted several times.
    #
    # 3. The merged lines are grouped into clusters of intersecting lines. Each cluster with
    #    at least two horizontal and two vertical lines forms one table. Two tables whose
    #    lines are separated by more than the configured tolerance are therefore never joined
    #    into one.
    #
    # 4. For each table the elementary edges between neighboring grid lines are classified as
    #    present or absent based on how much of the edge is covered by actual line segments. A
    #    cell is then every maximal grid-aligned rectangle whose four borders are present and
    #    whose interior is not crossed by a present edge. Missing inner borders (merged cells)
    #    naturally lead to cells spanning multiple rows or columns. Areas without sufficient
    #    border coverage are left as holes instead of being forced into a complete rectangle.
    #
    # 5. If an edge is only partially covered, both interpretations (edge present/absent) are
    #    reasonable. In this case the primary interpretation is chosen by coverage but an
    #    Ambiguity object is recorded on the table (and on the affected cells) instead of
    #    silently committing to a single reading.
    #
    # == Tolerances
    #
    # All tolerances are specified in PDF user space units (1/72 inch by default) of the
    # processed page, so their meaning is independent of any rendering resolution:
    #
    # +tolerance+::
    #     Maximum misalignment of parallel line segments that are still snapped onto a single
    #     grid line, maximum gap between collinear segment pieces that is bridged, and maximum
    #     distance between line endpoints that is still treated as an intersection when
    #     clustering lines into tables. Default: 2.0.
    #
    # +min_edge_coverage+::
    #     Minimum fraction (0-1) of an elementary grid edge that has to be covered by line
    #     segments for the edge to be treated as present. An edge covered at most
    #     (1 - min_edge_coverage) is treated as absent. Anything in between is ambiguous and
    #     recorded. Default: 0.9.
    #
    # Example:
    #
    #   tables = HexaPDF::Content::TableExtractor.extract(page, region: [50, 100, 545, 700])
    #   table = tables.first
    #   table.rows       # y-coordinates of the row boundaries, top to bottom
    #   table.columns    # x-coordinates of the column boundaries, left to right
    #   table.cells.each do |cell|
    #     puts cell.text
    #   end
    #
    # See: HexaPDF::Type::Page#extract_tables
    class TableExtractor

      # Describes a place where the extracted lines allow more than one reasonable
      # interpretation of the table structure.
      #
      # Instead of silently forcing a complete rectangular grid, the TableExtractor records an
      # instance of this class for every grid edge whose existence cannot be decided with
      # certainty. The #resolution contains the interpretation that was used for the returned
      # cells; the alternative interpretation can be derived from #message.
      Ambiguity = Struct.new(:type, :orientation, :position, :from, :to, :coverage,
                             :resolution, keyword_init: true) do

        # Returns a human readable description of the ambiguity, including the chosen
        # resolution and the alternative interpretation.
        def message
          action = (resolution == :present ? 'treated as present (cells stay split)'
                                           : 'treated as absent (cells are merged)')
          alternative = (resolution == :present ? 'absent' : 'present')
          format('%s edge at %g from %g to %g is only %d%% covered by line segments; %s; ' \
                 'alternative interpretation: %s',
                 orientation, position, from, to, (coverage * 100).round, action, alternative)
        end

      end

      # Represents a single cell of an extracted table.
      #
      # A cell always covers a rectangular area of the table's grid, starting at #row/#column
      # and spanning #row_span rows and #column_span columns. Merged cells in the original
      # table therefore show up as cells with a span greater than one.
      class Cell

        # The zero-based row index of the cell (row 0 is the top-most row).
        attr_reader :row

        # The zero-based column index of the cell (column 0 is the left-most column).
        attr_reader :column

        # The number of grid rows the cell spans.
        attr_reader :row_span

        # The number of grid columns the cell spans.
        attr_reader :column_span

        # The bounding box of the cell as [llx, lly, urx, ury] in user space coordinates.
        attr_reader :bbox

        # The Ambiguity objects affecting the borders of this cell.
        attr_reader :ambiguities

        # The text runs (see
        # HexaPDF::Content::SmartTextExtractor::TextRunCollector::TextRun) assigned to this
        # cell, sorted top to bottom and left to right.
        attr_reader :text_runs

        def initialize(row:, column:, row_span:, column_span:, bbox:) # :nodoc:
          @row = row
          @column = column
          @row_span = row_span
          @column_span = column_span
          @bbox = bbox.freeze
          @ambiguities = []
          @text_runs = []
        end

        # Returns +true+ if at least one border of the cell is affected by an ambiguity, i.e.
        # if the extent of the cell is not fully certain.
        def ambiguous?
          !@ambiguities.empty?
        end

        # Returns the text of the cell.
        #
        # Text runs on the same baseline are concatenated; separate lines are joined with a
        # newline character. Empty cells return an empty string.
        def text
          @text ||= begin
            lines = []
            @text_runs.sort_by {|run| [-run.baseline, run.left] }.each do |run|
              if lines.empty? || (lines[-1][0].baseline - run.baseline).abs > run.height * 0.5
                lines << [run]
              else
                lines[-1] << run
              end
            end
            lines.map {|line| line.map(&:string).join }.join("\n")
          end
        end

      end

      # Represents a single extracted table.
      class Table

        # The y-coordinates of the horizontal grid lines, sorted top to bottom. Contains
        # (number of rows + 1) entries.
        attr_reader :rows

        # The x-coordinates of the vertical grid lines, sorted left to right. Contains
        # (number of columns + 1) entries.
        attr_reader :columns

        # All detected cells of the table (Cell objects), sorted by row and column.
        attr_reader :cells

        # All ambiguities encountered while reconstructing the grid (Ambiguity objects).
        attr_reader :ambiguities

        def initialize(rows:, columns:, cells:, ambiguities:) # :nodoc:
          @rows = rows.freeze
          @columns = columns.freeze
          @cells = cells.sort_by {|cell| [cell.row, cell.column] }.freeze
          @ambiguities = ambiguities.freeze
        end

        # Returns the bounding box of the table as [llx, lly, urx, ury].
        def bbox
          [@columns.first, @rows.last, @columns.last, @rows.first]
        end

        # Returns the cell covering the given zero-based grid row and column, or +nil+ if the
        # position is a hole (i.e. not covered by any cell).
        def [](row, column)
          @cells.find do |cell|
            cell.row <= row && row < cell.row + cell.row_span &&
              cell.column <= column && column < cell.column + cell.column_span
          end
        end

        # Returns +true+ if the detected cells completely tile the table's bounding grid.
        #
        # A result of +false+ means that parts of the grid are holes where the drawn lines
        # didn't allow a reliable cell detection; nothing was invented to fill them.
        def complete?
          covered = Array.new(@rows.size - 1) { Array.new(@columns.size - 1, false) }
          @cells.each do |cell|
            (cell.row...(cell.row + cell.row_span)).each do |row|
              (cell.column...(cell.column + cell.column_span)).each do |column|
                covered[row][column] = true
              end
            end
          end
          covered.all? {|row| row.all? }
        end

      end

      # A normalized, merged straight line, i.e. one grid line candidate. The +intervals+
      # array contains the covered [from, to] ranges along the line. :nodoc:
      Line = Struct.new(:orientation, :position, :intervals)

      # A raw axis-aligned segment as collected from the content stream. :nodoc:
      Segment = Struct.new(:orientation, :position, :min, :max)

      # Processor that collects stroked, axis-aligned line segments (transformed into user
      # space) as well as the text runs of a page. :nodoc:
      class LineProcessor < Processor

        include SmartTextExtractor::TextRunCollector

        # The collected raw segments (array of Segment).
        attr_reader :segments

        # The tolerance (in user space units) used for deciding whether a segment is
        # axis-aligned.
        attr_accessor :tolerance

        def initialize
          super
          @segments = []
          @tolerance = 2.0
          reset_path
        end

        private

        def reset_path
          @current_point = nil
          @subpath_start = nil
          @path_segments = []
        end

        def move_to(x, y)
          @current_point = @subpath_start = graphics_state.ctm.evaluate(x, y)
        end

        def line_to(x, y)
          return unless @current_point
          point = graphics_state.ctm.evaluate(x, y)
          @path_segments << [@current_point, point]
          @current_point = point
        end

        def curve_to(_x1, _y1, _x2, _y2, x3, y3)
          @current_point = graphics_state.ctm.evaluate(x3, y3) if @current_point
        end

        def curve_to_no_first_control_point(_x2, _y2, x3, y3)
          @current_point = graphics_state.ctm.evaluate(x3, y3) if @current_point
        end
        alias curve_to_no_second_control_point curve_to_no_first_control_point

        def append_rectangle(x, y, width, height)
          ctm = graphics_state.ctm
          ll = ctm.evaluate(x, y)
          lr = ctm.evaluate(x + width, y)
          ur = ctm.evaluate(x + width, y + height)
          ul = ctm.evaluate(x, y + height)
          @path_segments << [ll, lr] << [lr, ur] << [ur, ul] << [ul, ll]
          @current_point = @subpath_start = ll
        end

        def close_subpath
          if @current_point && @subpath_start && @current_point != @subpath_start
            @path_segments << [@current_point, @subpath_start]
          end
          @current_point = @subpath_start
        end

        def flush_path
          @path_segments.each do |(x1, y1), (x2, y2)|
            dx = (x2 - x1).abs
            dy = (y2 - y1).abs
            next if dx <= @tolerance && dy <= @tolerance # degenerate segment
            if dy <= @tolerance
              @segments << Segment.new(:horizontal, (y1 + y2) / 2.0, *[x1, x2].minmax)
            elsif dx <= @tolerance
              @segments << Segment.new(:vertical, (x1 + x2) / 2.0, *[y1, y2].minmax)
            end
            # Segments that are not axis-aligned (within tolerance) cannot be table borders
            # and are ignored.
          end
          reset_path
        end

        def stroke_path
          flush_path
        end
        alias fill_and_stroke_path_non_zero stroke_path
        alias fill_and_stroke_path_even_odd stroke_path

        def close_and_stroke_path
          close_subpath
          flush_path
        end
        alias close_fill_and_stroke_path_non_zero close_and_stroke_path
        alias close_fill_and_stroke_path_even_odd close_and_stroke_path

        def end_path
          reset_path
        end
        alias fill_path_non_zero end_path
        alias fill_path_even_odd end_path

        def show_text(str)
          collect_text_runs(decode_text_with_positioning(str))
        end
        alias show_text_with_positioning show_text

      end

      # All text runs found inside the region (array of
      # HexaPDF::Content::SmartTextExtractor::TextRunCollector::TextRun). Only available after
      # #extract has been called.
      attr_reader :text_runs

      # The text runs inside the region that could not be assigned to any cell. Only available
      # after #extract has been called.
      attr_reader :unassigned_text_runs

      # Extracts the tables from the given page and returns them.
      #
      # See TableExtractor.new for the available options.
      def self.extract(page, **options)
        new(page, **options).extract
      end

      # Creates a new TableExtractor for the given HexaPDF::Type::Page object.
      #
      # +region+::
      #     The rectangular area of the page that is analyzed, given as [llx, lly, urx, ury]
      #     in user space coordinates (or as HexaPDF::Rectangle). Only lines intersecting the
      #     region and text inside it are taken into account. Defaults to the page's crop box.
      #
      # +tolerance+::
      #     Geometric tolerance in user space units; see the class documentation for details.
      #
      # +min_edge_coverage+::
      #     Edge coverage threshold (0-1); see the class documentation for details.
      def initialize(page, region: nil, tolerance: 2.0, min_edge_coverage: 0.9)
        @page = page
        @region = normalize_region(region || page.box(:crop))
        @tolerance = tolerance.to_f
        @min_edge_coverage = min_edge_coverage.to_f
        @text_runs = []
        @unassigned_text_runs = []
      end

      # Extracts the tables from the page and returns an array of Table objects, sorted from
      # top to bottom and left to right.
      def extract
        processor = LineProcessor.new
        processor.tolerance = @tolerance
        @page.process_contents(processor)

        segments = processor.segments.select {|segment| segment_in_region?(segment) }
        @text_runs = processor.text_runs.select do |run|
          x = (run.left + run.right) / 2.0
          y = (run.bottom + run.top) / 2.0
          x >= @region[0] && x <= @region[2] && y >= @region[1] && y <= @region[3]
        end

        lines = merge_segments(segments)
        assigned = {}
        tables = cluster_lines(lines).filter_map {|cluster| build_table(cluster, assigned) }
        @unassigned_text_runs = @text_runs.reject {|run| assigned[run] }
        tables.sort_by! {|table| [-table.bbox[3], table.bbox[0]] }
        tables
      end

      private

      # Normalizes the region argument into an [llx, lly, urx, ury] array of floats.
      def normalize_region(region)
        if region.respond_to?(:left)
          [region.left, region.bottom, region.right, region.top].map(&:to_f)
        else
          llx, lly, urx, ury = region.to_a.map(&:to_f)
          x0, x1 = [llx, urx].minmax
          y0, y1 = [lly, ury].minmax
          [x0, y0, x1, y1]
        end
      end

      # Returns +true+ if the segment intersects the region.
      def segment_in_region?(segment)
        if segment.orientation == :horizontal
          segment.position >= @region[1] && segment.position <= @region[3] &&
            segment.max >= @region[0] && segment.min <= @region[2]
        else
          segment.position >= @region[0] && segment.position <= @region[2] &&
            segment.max >= @region[1] && segment.min <= @region[3]
        end
      end

      # Snaps nearly collinear segments onto common grid lines and merges overlapping,
      # duplicated or slightly gapped pieces into Line objects with disjoint intervals.
      def merge_segments(segments)
        lines = []
        [:horizontal, :vertical].each do |orientation|
          oriented = segments.select {|s| s.orientation == orientation }.sort_by(&:position)
          clusters = []
          oriented.each do |segment|
            if clusters.empty? || segment.position - clusters[-1][-1].position > @tolerance
              clusters << [segment]
            else
              clusters[-1] << segment
            end
          end
          clusters.each do |cluster|
            total = cluster.sum {|s| s.max - s.min }
            position = cluster.sum {|s| s.position * (s.max - s.min) } / total
            intervals = cluster.map {|s| [s.min, s.max] }.sort
            intervals = intervals.each_with_object([]) do |(a, b), result|
              if !result.empty? && a <= result[-1][1] + @tolerance
                result[-1][1] = b if b > result[-1][1]
              else
                result << [a, b]
              end
            end
            lines << Line.new(orientation, position, intervals)
          end
        end
        lines
      end

      # Groups lines into clusters of intersecting line pieces. Pieces whose endpoints are
      # farther apart than the tolerance end up in different clusters, so adjacent but
      # separate tables are not joined into one.
      #
      # Clustering is done on the individual covered intervals (not on whole lines) because
      # collinear lines of two separate tables share a single grid line position but must
      # still form two tables.
      def cluster_lines(lines)
        rods = lines.flat_map do |line|
          line.intervals.map {|from, to| [line.orientation, line.position, from, to] }
        end
        parent = rods.each_index.to_a
        find = lambda do |i|
          parent[i] = find.call(parent[i]) while parent[i] != parent[parent[i]]
          parent[i]
        end
        horizontals, verticals = rods.each_index.partition {|i| rods[i][0] == :horizontal }
        horizontals.each do |hi|
          _, hy, hx0, hx1 = rods[hi]
          verticals.each do |vi|
            _, vx, vy0, vy1 = rods[vi]
            next unless vx >= hx0 - @tolerance && vx <= hx1 + @tolerance &&
              hy >= vy0 - @tolerance && hy <= vy1 + @tolerance
            parent[find.call(hi)] = find.call(vi)
          end
        end
        rods.each_index.group_by {|i| find.call(i) }.values.filter_map do |cluster|
          grouped = cluster.group_by {|i| [rods[i][0], rods[i][1]] }
          next if grouped.keys.count {|orientation, _| orientation == :horizontal } < 2 ||
            grouped.keys.count {|orientation, _| orientation == :vertical } < 2
          grouped.map do |(orientation, position), indices|
            Line.new(orientation, position,
                     indices.map {|i| [rods[i][2], rods[i][3]] }.sort)
          end
        end
      end

      # Builds a Table object from a cluster of intersecting lines.
      #
      # The +assigned+ hash records which text runs have been assigned to a cell.
      def build_table(lines, assigned)
        h_lines, v_lines = lines.partition {|l| l.orientation == :horizontal }
        ys = h_lines.map(&:position).sort.reverse
        xs = v_lines.map(&:position).sort
        return if ys.size < 2 || xs.size < 2

        h_intervals = h_lines.to_h {|l| [l.position, l.intervals] }
        v_intervals = v_lines.to_h {|l| [l.position, l.intervals] }

        ambiguities = []
        # h_edges[y_index][x_index]: status of the elementary horizontal edge between
        # (xs[x_index], ys[y_index]) and (xs[x_index + 1], ys[y_index]).
        h_edges = ys.map do |y|
          (0...(xs.size - 1)).map do |i|
            classify_edge(coverage(h_intervals[y], xs[i], xs[i + 1]),
                          ambiguities, :horizontal, y, xs[i], xs[i + 1])
          end
        end
        # v_edges[x_index][y_index]: status of the elementary vertical edge between
        # (xs[x_index], ys[y_index + 1]) and (xs[x_index], ys[y_index]).
        v_edges = xs.map do |x|
          (0...(ys.size - 1)).map do |j|
            classify_edge(coverage(v_intervals[x], ys[j + 1], ys[j]),
                          ambiguities, :vertical, x, ys[j + 1], ys[j])
          end
        end

        cells = find_cells(xs, ys, h_edges, v_edges)
        assign_ambiguities(cells, ambiguities)
        assign_text(cells, assigned)
        Table.new(rows: ys, columns: xs, cells: cells, ambiguities: ambiguities)
      end

      # Returns the fraction of the range [from, to] that is covered by the given intervals.
      def coverage(intervals, from, to)
        intervals.sum {|a, b| [0, [b, to].min - [a, from].max].max } / (to - from)
      end

      # Classifies an elementary edge based on its coverage ratio. Ambiguous edges are
      # recorded together with the chosen resolution.
      def classify_edge(ratio, ambiguities, orientation, position, from, to)
        if ratio >= @min_edge_coverage
          :present
        elsif ratio <= 1.0 - @min_edge_coverage
          :absent
        else
          resolution = (ratio >= 0.5 ? :present : :absent)
          ambiguities << Ambiguity.new(type: :partial_edge, orientation: orientation,
                                       position: position, from: from, to: to,
                                       coverage: ratio, resolution: resolution)
          resolution
        end
      end

      # Finds all maximal grid-aligned rectangles whose four borders are present and whose
      # interior is not crossed by a present edge.
      #
      # Such rectangles can never overlap: the border edges of one rectangle would otherwise
      # lie strictly inside the other, contradicting its validity. Areas without sufficient
      # border coverage are left as holes.
      def find_cells(xs, ys, h_edges, v_edges)
        cells = []
        (0...(ys.size - 1)).each do |top|
          ((top + 1)...ys.size).each do |bottom|
            (0...(xs.size - 1)).each do |left|
              ((left + 1)...xs.size).each do |right|
                next unless borders_present?(h_edges, v_edges, top, bottom, left, right)
                next if interior_edges?(h_edges, v_edges, top, bottom, left, right)
                cells << Cell.new(row: top, column: left, row_span: bottom - top,
                                  column_span: right - left,
                                  bbox: [xs[left], ys[bottom], xs[right], ys[top]])
              end
            end
          end
        end
        cells
      end

      # Returns +true+ if all elementary edges on the rectangle's border are present.
      def borders_present?(h_edges, v_edges, top, bottom, left, right)
        (left...right).all? {|i| h_edges[top][i] == :present && h_edges[bottom][i] == :present } &&
          (top...bottom).all? {|j| v_edges[left][j] == :present && v_edges[right][j] == :present }
      end

      # Returns +true+ if a present edge lies strictly inside the rectangle.
      def interior_edges?(h_edges, v_edges, top, bottom, left, right)
        ((top + 1)...bottom).any? {|j| (left...right).any? {|i| h_edges[j][i] == :present } } ||
          ((left + 1)...right).any? {|i| (top...bottom).any? {|j| v_edges[i][j] == :present } }
      end

      # Assigns the recorded ambiguities to the cells whose borders they affect.
      def assign_ambiguities(cells, ambiguities)
        ambiguities.each do |ambiguity|
          cells.each do |cell|
            left, bottom, right, top = cell.bbox
            affected = if ambiguity.orientation == :horizontal
                         (top == ambiguity.position || bottom == ambiguity.position) &&
                           left <= ambiguity.from && right >= ambiguity.to
                       else
                         (left == ambiguity.position || right == ambiguity.position) &&
                           bottom <= ambiguity.from && top >= ambiguity.to
                       end
            cell.ambiguities << ambiguity if affected
          end
        end
      end

      # Assigns each collected text run to the cell containing its center.
      def assign_text(cells, assigned)
        @text_runs.each do |run|
          next if assigned[run]
          x = (run.left + run.right) / 2.0
          y = (run.bottom + run.top) / 2.0
          cell = cells.find do |candidate|
            left, bottom, right, top = candidate.bbox
            x >= left && x <= right && y >= bottom && y <= top
          end
          next unless cell
          cell.text_runs << run
          assigned[run] = true
        end
      end

    end

  end
end
