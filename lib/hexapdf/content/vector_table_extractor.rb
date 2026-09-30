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
# In accordance with Section 7(b) of the GNU Affero General Public License,
# a covered work must retain the producer line in every PDF that is created
# or manipulated using HexaPDF.
#
# If the GNU Affero General Public License doesn't fit your need,
# commercial licenses are available at <https://gettalong.at/hexapdf/>.
#++

require 'set'
require 'hexapdf/content/processor'
require 'hexapdf/content/smart_text_extractor'

module HexaPDF
  module Content

    # Extracts tables represented by horizontal and vertical stroked line segments.
    #
    # The extractor works in PDF user-space units (normally points). It does not perform OCR or
    # image analysis and it never invents missing borders to complete a table. Missing lines can
    # therefore result in fewer cells and are reported as ambiguities.
    module VectorTableExtractor

      # A stroked straight segment, either horizontal or vertical.
      Segment = Struct.new(:x0, :y0, :x1, :y1, :line_width)

      # A cell found from the observed grid lines.
      Cell = Struct.new(:row, :column, :row_span, :column_span, :text,
                        :left, :bottom, :right, :top)

      # Information about an interpretation that could not be resolved unambiguously.
      Ambiguity = Struct.new(:type, :message, :left, :bottom, :right, :top)

      # A table and the cells contained in it.
      Table = Struct.new(:left, :bottom, :right, :top, :row_boundaries,
                         :column_boundaries, :cells, :ambiguities)

      # Collects stroked axis-aligned line segments and visible text runs.
      class Processor < HexaPDF::Content::Processor

        include SmartTextExtractor::TextRunCollector

        # All collected straight segments in PDF user-space coordinates.
        attr_reader :segments

        def initialize(resources = nil)
          super()
          @segments = []
          @path_subpaths = []
          @current_point = nil
        end

        def move_to(x, y)
          @current_point = graphics_state.ctm.evaluate(x, y)
          @path_subpaths << {segments: [], curve: false, start: @current_point}
        end

        def line_to(x, y)
          return unless @current_point

          @path_subpaths << {segments: [], curve: false, start: @current_point} if @path_subpaths.empty?
          endpoint = graphics_state.ctm.evaluate(x, y)
          @path_subpaths.last[:segments] << [@current_point, endpoint]
          @current_point = endpoint
        end

        def curve_to(*)
          @path_subpaths << {segments: [], curve: false, start: @current_point} if @path_subpaths.empty?
          @path_subpaths.last[:curve] = true
          @current_point = nil
        end
        alias curve_to_no_first_control_point curve_to
        alias curve_to_no_second_control_point curve_to

        def close_subpath
          subpath = @path_subpaths.last
          if subpath && @current_point && @current_point != subpath[:start]
            subpath[:segments] << [@current_point, subpath[:start]]
          end
          @current_point = subpath&.dig(:start)
        end

        def append_rectangle(x, y, width, height)
          corners = [[x, y], [x + width, y], [x + width, y + height], [x, y + height]]
          transformed = corners.map {|point| graphics_state.ctm.evaluate(*point) }
          segments = [[transformed[0], transformed[1]], [transformed[1], transformed[2]],
                      [transformed[2], transformed[3]], [transformed[3], transformed[0]]]
          @path_subpaths << {segments: segments, curve: false, start: transformed[0]}
          @current_point = nil
        end

        def stroke_path
          flush_path
        end
        alias close_and_stroke_path stroke_path
        alias fill_and_stroke_path_non_zero stroke_path
        alias fill_and_stroke_path_even_odd stroke_path
        alias close_fill_and_stroke_path_non_zero stroke_path
        alias close_fill_and_stroke_path_even_odd stroke_path

        def end_path
          @path_subpaths.clear
          @current_point = nil
        end
        alias fill_path_non_zero end_path
        alias fill_path_even_odd end_path

        def show_text(text)
          mode = graphics_state.text_rendering_mode.value
          return if mode == 3 || mode == 7

          collect_text_runs(decode_text_with_positioning(text))
        end
        alias show_text_with_positioning show_text

        private

        def flush_path
          @path_subpaths.each do |subpath|
            next if subpath[:curve]

            subpath[:segments].each do |(start_point, endpoint)|
              segment = Segment.new(start_point[0], start_point[1], endpoint[0], endpoint[1],
                                   graphics_state.line_width)
              normalize_axis_aligned_segment(segment)
              @segments << segment
            end
          end
          @path_subpaths.clear
          @current_point = nil
        end

        def normalize_axis_aligned_segment(segment)
          if segment.y0 == segment.y1
            segment.x0, segment.x1 = [segment.x0, segment.x1].minmax
          elsif segment.x0 == segment.x1
            segment.y0, segment.y1 = [segment.y0, segment.y1].minmax
          end
        end

      end

      # Extracts tables from a page's content streams.
      #
      # +area+ is +[left, bottom, right, top]+ in PDF user-space coordinates. If it is nil, the
      # page's media box is used.
      #
      # Options:
      #
      # alignment_tolerance:: Maximum perpendicular distance, in page units, between lines that
      #                       represent the same grid boundary.
      # gap_tolerance:: Maximum longitudinal gap, in page units, that is interpreted as a broken
      #                 line rather than separate lines.
      def self.extract(page, area: nil, alignment_tolerance: 0.5, gap_tolerance: 1.0)
        raise ArgumentError, "alignment_tolerance must be non-negative" if alignment_tolerance.negative?
        raise ArgumentError, "gap_tolerance must be non-negative" if gap_tolerance.negative?

        processor = Processor.new
        page.process_contents(processor)
        area = normalize_area(area || page.box(:media))
        segments = segments_in_area(processor.segments, area, alignment_tolerance)
        text_runs = processor.text_runs.select {|run| run_in_area?(run, area) }
        components = connected_components(segments, alignment_tolerance, gap_tolerance)

        components.filter_map do |component|
          table = build_table(component)
          next unless table

          unassigned_runs = assign_text(table, text_runs)
          table.ambiguities.concat(component_ambiguities(component, table,
                                                         alignment_tolerance))
          table.ambiguities.concat(unassigned_text_ambiguities(table, unassigned_runs))
          table
        end
      end

      Lane = Struct.new(:position, :segments, :intervals)
      Component = Struct.new(:segments, :horizontal, :vertical, :junctions,
                             :alignment_tolerance, :gap_tolerance)

      def self.normalize_area(area)
        values = Array(area).map(&:to_f)
        raise ArgumentError, "Area must contain four coordinates" unless values.size == 4
        raise ArgumentError, "Area must have positive width and height" if values[2] <= values[0] ||
          values[3] <= values[1]

        [values[0], values[1], values[2], values[3]]
      end
      private_class_method :normalize_area

      def self.segments_in_area(segments, area, alignment_tolerance)
        segments.filter_map do |segment|
          clipped = clip_segment(segment, area, alignment_tolerance)
          next unless clipped && segment_length(clipped).positive?

          clipped
        end
      end
      private_class_method :segments_in_area

      def self.run_in_area?(run, area)
        run.left < area[2] && run.right > area[0] && run.bottom < area[3] && run.top > area[1]
      end
      private_class_method :run_in_area?

      def self.connected_components(segments, alignment_tolerance, gap_tolerance)
        parents = Array.new(segments.size) {|index| index }
        all_junctions = []

        find = lambda do |index|
          parents[index] = find.call(parents[index]) unless parents[index] == index
          parents[index]
        end
        union = lambda do |left, right|
          parents[find.call(left)] = find.call(right)
        end

        connect_parallel_segments(segments, alignment_tolerance, union)
        connect_perpendicular_segments(segments, alignment_tolerance, all_junctions, union)

        groups = {}
        segments.each_with_index do |segment, index|
          (groups[find.call(index)] ||= []) << segment
        end

        groups.values.filter_map do |group|
          horizontal = group.select {|segment| segment.y0 == segment.y1 }
          vertical = group - horizontal
          next if horizontal.empty? || vertical.empty?

          component = Component.new(group, horizontal, vertical, [], alignment_tolerance,
                                    gap_tolerance)
          component.junctions.concat(all_junctions.select do |junction|
            group.include?(junction[:horizontal]) && group.include?(junction[:vertical])
          end)
          component
        end
      end
      private_class_method :connected_components

      def self.component_alignment_tolerance(component)
        component.alignment_tolerance
      end
      private_class_method :component_alignment_tolerance

      def self.component_gap_tolerance(component)
        component.gap_tolerance
      end
      private_class_method :component_gap_tolerance

      def self.clip_segment(segment, area, tolerance)
        if segment.y0 == segment.y1
          left = [segment.x0, area[0]].max
          right = [segment.x1, area[2]].min
          return if right <= left || segment.y0 < area[1] || segment.y0 > area[3]

          Segment.new(left, segment.y0, right, segment.y1, segment.line_width)
        elsif segment.x0 == segment.x1
          bottom = [segment.y0, area[1]].max
          top = [segment.y1, area[3]].min
          return if top <= bottom || segment.x0 < area[0] || segment.x0 > area[2]

          Segment.new(segment.x0, bottom, segment.x1, top, segment.line_width)
        elsif near_axis_aligned?(segment, tolerance)
          normalized = axis_aligned_segment(segment)
          clip_segment(normalized, area, tolerance)
        end
      end
      private_class_method :clip_segment

      def self.near_axis_aligned?(segment, tolerance)
        dx = (segment.x1 - segment.x0).abs
        dy = (segment.y1 - segment.y0).abs
        [dy, dx].min <= tolerance
      end
      private_class_method :near_axis_aligned?

      def self.axis_aligned_segment(segment)
        if (segment.y1 - segment.y0).abs <= (segment.x1 - segment.x0).abs
          y = (segment.y0 + segment.y1) / 2.0
          x0, x1 = [segment.x0, segment.x1].minmax
          Segment.new(x0, y, x1, y, segment.line_width)
        else
          x = (segment.x0 + segment.x1) / 2.0
          y0, y1 = [segment.y0, segment.y1].minmax
          Segment.new(x, y0, x, y1, segment.line_width)
        end
      end
      private_class_method :axis_aligned_segment

      def self.segment_length(segment)
        Math.sqrt((segment.x1 - segment.x0)**2 + (segment.y1 - segment.y0)**2)
      end
      private_class_method :segment_length

      def self.connect_parallel_segments(segments, alignment_tolerance, union)
        segments.each_with_index do |segment, index|
          (index + 1).upto(segments.size - 1) do |other_index|
            other = segments[other_index]
            next unless same_orientation?(segment, other)
            next unless parallel_distance(segment, other) <= alignment_tolerance
            next if interval_gap(segment, other).positive?

            union.call(index, other_index)
          end
        end
      end
      private_class_method :connect_parallel_segments

      def self.connect_perpendicular_segments(segments, alignment_tolerance, junctions, union)
        segments.each_with_index do |segment, index|
          segments.each_with_index do |vertical, vertical_index|
            next if index == vertical_index || segment.y0 != segment.y1 ||
                    vertical.y0 == vertical.y1

            horizontal = segment
            x_overlaps = vertical.x0 >= horizontal.x0 && vertical.x0 <= horizontal.x1
            y_overlaps = horizontal.y0 >= vertical.y0 && horizontal.y0 <= vertical.y1
            horizontal_gap = x_overlaps ? 0 : [[horizontal.x0 - vertical.x0, 0].max,
                                              [vertical.x0 - horizontal.x1, 0].max].max
            vertical_gap = y_overlaps ? 0 : [[vertical.y0 - horizontal.y0, 0].max,
                                            [horizontal.y0 - vertical.y1, 0].max].max
            tolerance = alignment_tolerance + (horizontal.line_width + vertical.line_width) / 2.0
            next if horizontal_gap > tolerance || vertical_gap > tolerance

            union.call(index, vertical_index)
            approximate = horizontal_gap.positive? || vertical_gap.positive?
            junctions << {x: vertical.x0, y: horizontal.y0, approximate: approximate,
                          horizontal: horizontal, vertical: vertical,
                          horizontal_gap: horizontal_gap, vertical_gap: vertical_gap}
          end
        end
      end
      private_class_method :connect_perpendicular_segments

      def self.same_orientation?(segment, other)
        (segment.y0 == segment.y1) == (other.y0 == other.y1)
      end
      private_class_method :same_orientation?

      def self.parallel_distance(segment, other)
        segment.y0 == segment.y1 ? (segment.y0 - other.y0).abs : (segment.x0 - other.x0).abs
      end
      private_class_method :parallel_distance

      def self.interval_gap(segment, other)
        if segment.y0 == segment.y1
          [segment.x0, other.x0].max - [segment.x1, other.x1].min
        else
          [segment.y0, other.y0].max - [segment.y1, other.y1].min
        end
      end
      private_class_method :interval_gap

      def self.build_table(component)
        alignment_tolerance = component_alignment_tolerance(component)
        gap_tolerance = component_gap_tolerance(component)
        horizontal_lanes = build_lanes(component.horizontal, true, alignment_tolerance, gap_tolerance)
        vertical_lanes = build_lanes(component.vertical, false, alignment_tolerance, gap_tolerance)
        cells = find_cells(horizontal_lanes, vertical_lanes, gap_tolerance)
        return unless horizontal_lanes.size >= 2 && vertical_lanes.size >= 2

        if cells.empty?
          left = component.vertical.map(&:x0).min
          bottom = component.horizontal.map(&:y0).min
          right = component.vertical.map(&:x1).max
          top = component.horizontal.map(&:y1).max
          row_boundaries = horizontal_lanes.map(&:position)
          column_boundaries = vertical_lanes.map(&:position)
          ambiguity = Ambiguity.new(:incomplete_grid,
                                    'Grid lines do not enclose a complete cell',
                                    left, bottom, right, top)
          return Table.new(left, bottom, right, top, row_boundaries, column_boundaries, [],
                           [ambiguity])
        end

        left = cells.map(&:left).min
        bottom = cells.map(&:bottom).min
        right = cells.map(&:right).max
        top = cells.map(&:top).max
        row_boundaries = cells.flat_map {|cell| [cell.bottom, cell.top] }.uniq.sort
        column_boundaries = cells.flat_map {|cell| [cell.left, cell.right] }.uniq.sort
        sorted_cells = cells.sort_by {|cell| [-cell.top, cell.left] }
        table = Table.new(left, bottom, right, top, row_boundaries, column_boundaries,
                          sorted_cells, [])
        assign_cell_indices(table)
        table.ambiguities.concat(bridged_line_ambiguities(horizontal_lanes, vertical_lanes,
                                                          cells, gap_tolerance))
        table
      end
      private_class_method :build_table

      def self.assign_text(table, text_runs)
        assigned = Set.new
        cell_runs = Hash.new {|hash, cell| hash[cell] = [] }

        text_runs.each do |run|
          cell = containing_cell(table.cells, run, 0)
          next unless cell

          cell_runs[cell] << run
          assigned << run
        end
        cell_runs.each {|cell, runs| cell.text = runs_to_text(runs) }
        table.cells.each {|cell| cell.text ||= '' }

        text_runs.reject {|run| assigned.include?(run) }
      end
      private_class_method :assign_text

      def self.runs_to_text(runs)
        heights = runs.map(&:height).sort
        line_tolerance = [[heights[heights.size / 2].to_f, 1.0].max * 0.5, 0.5].max
        sorted = runs.sort_by {|run| [-run.top, run.left] }
        lines = []
        sorted.each do |run|
          center_y = (run.bottom + run.top) / 2.0
          line = lines.find {|entry| (entry[:center] - center_y).abs <= line_tolerance }
          if line
            line[:runs] << run
            line[:center] = line[:runs].sum {|item| (item.bottom + item.top) / 2.0 } / line[:runs].size
          else
            lines << {center: center_y, runs: [run]}
          end
        end
        lines.map do |line_runs|
          line = line_runs[:runs].sort_by(&:left)
          line.each_with_index.each_with_object(+'') do |(run, index), result|
            previous = line[index - 1]
            result << ' ' if previous && run.left - previous.right > run.height * 0.25
            result << run.string
          end
        end.join("\n")
      end
      private_class_method :runs_to_text

      def self.component_ambiguities(component, table, alignment_tolerance)
        ambiguities = []
        approximate_junctions(component).each do |junction|
          next unless point_near_table?(junction, table, alignment_tolerance)

          ambiguities << Ambiguity.new(:approximate_junction,
                                      'Horizontal and vertical line meet only approximately',
                                      junction[:x] - alignment_tolerance,
                                      junction[:y] - alignment_tolerance,
                                      junction[:x] + alignment_tolerance,
                                      junction[:y] + alignment_tolerance)
        end
        ambiguities
      end
      private_class_method :component_ambiguities

      def self.approximate_junctions(component)
        component.junctions.select {|junction| junction[:approximate] }.uniq do |junction|
          [junction[:x].round(3), junction[:y].round(3),
           [junction[:horizontal_gap].round(3), junction[:vertical_gap].round(3)]]
        end
      end
      private_class_method :approximate_junctions

      def self.unassigned_text_ambiguities(table, text_runs)
        text_runs.select {|run| run_in_rectangle?(run, table) }.map do |run|
          Ambiguity.new(:unassigned_text, 'Text run is not enclosed by a complete cell',
                        run.left, run.bottom, run.right, run.top)
        end
      end
      private_class_method :unassigned_text_ambiguities

      def self.build_lanes(segments, horizontal, alignment_tolerance, gap_tolerance)
        groups = position_groups(segments, horizontal, alignment_tolerance)
        groups.map do |position, grouped_segments|
          intervals = grouped_segments.map {|segment| segment_interval(segment, horizontal) }.sort
          Lane.new(position, grouped_segments, intervals)
        end.sort_by(&:position)
      end
      private_class_method :build_lanes

      def self.position_groups(segments, horizontal, tolerance)
        sorted = segments.sort_by {|segment| horizontal ? segment.y0 : segment.x0 }
        groups = []
        sorted.each do |segment|
          position = horizontal ? segment.y0 : segment.x0
          candidates = groups.select do |group|
            group.all? {|item| (position - (horizontal ? item.y0 : item.x0)).abs <= tolerance }
          end
          if candidates.empty?
            groups << [segment]
          else
            candidates.min_by {|group| group.size } << segment
          end
        end
        groups.each_with_object({}) do |grouped_segments, result|
          positions = grouped_segments.map {|item| horizontal ? item.y0 : item.x0 }.sort
          middle = (positions.size - 1) / 2
          result[positions[middle].to_f] = grouped_segments
        end
      end
      private_class_method :position_groups

      def self.segment_interval(segment, horizontal)
        horizontal ? [segment.x0, segment.x1] : [segment.y0, segment.y1]
      end
      private_class_method :segment_interval

      def self.find_cells(horizontal_lanes, vertical_lanes, gap_tolerance)
        cells = []
        horizontal_lanes.each_with_index do |lower_lane, lower_index|
          (lower_index + 1).upto(horizontal_lanes.size - 1) do |upper_index|
            upper_lane = horizontal_lanes[upper_index]
            vertical_lanes.each_with_index do |left_lane, left_index|
              (left_index + 1).upto(vertical_lanes.size - 1) do |right_index|
                right_lane = vertical_lanes[right_index]
                next unless rectangle_closed?(lower_lane, upper_lane, left_lane, right_lane,
                                              gap_tolerance)
                next if contains_full_divider?(horizontal_lanes, vertical_lanes, lower_index,
                                               upper_index, left_index, right_index, gap_tolerance)

                cells << Cell.new(nil, nil, nil, nil, '', left_lane.position,
                                  lower_lane.position, right_lane.position, upper_lane.position)
              end
            end
          end
        end
        select_maximal_rectangles(cells)
      end
      private_class_method :find_cells

      def self.rectangle_closed?(lower_lane, upper_lane, left_lane, right_lane, gap_tolerance)
        vertical_interval = [lower_lane.position, upper_lane.position]
        horizontal_interval = [left_lane.position, right_lane.position]
        interval_covers?(left_lane.intervals, vertical_interval, gap_tolerance) &&
          interval_covers?(right_lane.intervals, vertical_interval, gap_tolerance) &&
          interval_covers?(lower_lane.intervals, horizontal_interval, gap_tolerance) &&
          interval_covers?(upper_lane.intervals, horizontal_interval, gap_tolerance)
      end
      private_class_method :rectangle_closed?

      def self.interval_covers?(intervals, interval, gap_tolerance)
        merged_intervals(intervals, gap_tolerance).any? do |candidate|
          candidate[0] - gap_tolerance <= interval[0] &&
            interval[1] <= candidate[1] + gap_tolerance
        end
      end
      private_class_method :interval_covers?

      def self.bridged_line_ambiguities(horizontal_lanes, vertical_lanes, cells, gap_tolerance)
        ambiguities = []
        cells.each do |cell|
          horizontal_lanes.each do |lane|
            next unless lane.position == cell.bottom || lane.position == cell.top

            interval = [cell.left, cell.right]
            if bridged_interval?(lane.intervals, interval, gap_tolerance)
              ambiguities << Ambiguity.new(:bridged_line_gap,
                                          'A horizontal boundary was completed across a line gap',
                                          interval[0], lane.position - gap_tolerance,
                                          interval[1], lane.position + gap_tolerance)
            end
          end
          vertical_lanes.each do |lane|
            next unless lane.position == cell.left || lane.position == cell.right

            interval = [cell.bottom, cell.top]
            if bridged_interval?(lane.intervals, interval, gap_tolerance)
              ambiguities << Ambiguity.new(:bridged_line_gap,
                                          'A vertical boundary was completed across a line gap',
                                          lane.position - gap_tolerance, interval[0],
                                          lane.position + gap_tolerance, interval[1])
            end
          end
        end
        ambiguities.uniq {|ambiguity| [ambiguity.type, ambiguity.left, ambiguity.bottom,
                                       ambiguity.right, ambiguity.top] }
      end
      private_class_method :bridged_line_ambiguities

      def self.bridged_interval?(intervals, interval, gap_tolerance)
        !interval_covers?(intervals, interval, 0) &&
          interval_covers?(intervals, interval, gap_tolerance)
      end
      private_class_method :bridged_interval?

      def self.merged_intervals(intervals, gap_tolerance)
        intervals.sort.each_with_object([]) do |interval, merged|
          if merged.empty? || interval[0] - merged[-1][1] > gap_tolerance
            merged << interval.dup
          else
            merged[-1][1] = [merged[-1][1], interval[1]].max
          end
        end
      end
      private_class_method :merged_intervals

      def self.contains_full_divider?(horizontal_lanes, vertical_lanes, lower_index, upper_index,
                                    left_index, right_index, gap_tolerance)
        left = vertical_lanes[left_index].position
        right = vertical_lanes[right_index].position
        bottom = horizontal_lanes[lower_index].position
        top = horizontal_lanes[upper_index].position
        horizontal = horizontal_lanes[(lower_index + 1)...upper_index].any? do |lane|
          interval_covers?(lane.intervals, [left, right], gap_tolerance)
        end
        vertical = vertical_lanes[(left_index + 1)...right_index].any? do |lane|
          interval_covers?(lane.intervals, [bottom, top], gap_tolerance)
        end
        horizontal || vertical
      end
      private_class_method :contains_full_divider?

      def self.select_maximal_rectangles(cells)
        cells.reject do |cell|
          cells.any? do |other|
            next if other.equal?(cell)

            other.left <= cell.left && other.bottom <= cell.bottom && other.right >= cell.right &&
              other.top >= cell.top &&
              (other.left < cell.left || other.bottom < cell.bottom ||
               other.right > cell.right || other.top > cell.top)
          end
        end
      end
      private_class_method :select_maximal_rectangles

      def self.assign_cell_indices(table)
        table.cells.each do |cell|
          bottom_index = table.row_boundaries.index(cell.bottom)
          top_index = table.row_boundaries.index(cell.top)
          left_index = table.column_boundaries.index(cell.left)
          right_index = table.column_boundaries.index(cell.right)
          cell.row = table.row_boundaries.size - top_index - 1
          cell.column = left_index
          cell.row_span = top_index - bottom_index
          cell.column_span = right_index - left_index
        end
      end
      private_class_method :assign_cell_indices

      def self.containing_cell(cells, run, tolerance)
        center_x = (run.left + run.right) / 2.0
        center_y = (run.bottom + run.top) / 2.0
        candidates = cells.select do |cell|
          center_x >= cell.left - tolerance && center_x <= cell.right + tolerance &&
            center_y >= cell.bottom - tolerance && center_y <= cell.top + tolerance
        end
        candidates.min_by {|cell| (cell.right - cell.left) * (cell.top - cell.bottom) }
      end
      private_class_method :containing_cell

      def self.run_in_rectangle?(run, rectangle)
        run.left < rectangle.right && run.right > rectangle.left && run.bottom < rectangle.top &&
          run.top > rectangle.bottom
      end
      private_class_method :run_in_rectangle?

      def self.point_near_table?(point, table, tolerance)
        point[:x] >= table.left - tolerance && point[:x] <= table.right + tolerance &&
          point[:y] >= table.bottom - tolerance && point[:y] <= table.top + tolerance
      end
      private_class_method :point_near_table?

    end
  end
end
