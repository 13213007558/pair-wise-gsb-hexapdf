# -*- encoding: utf-8; frozen_string_literal: true -*-
#
#--
# This file is part of HexaPDF.
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

require 'set'
require 'hexapdf/serializer'
require 'hexapdf/content/processor'

module HexaPDF
  module Content

    # Performs content-level redaction on page and Form XObject content streams.
    class Redaction < Processor

      RedactionError = Class.new(HexaPDF::Error)
      UNSUPPORTED_OPERATORS = %i[sh d0 d1].freeze
      PATH_PAINT_OPERATORS = %i[S s f F f* B B* b b*].freeze
      TEXT_SHOW_OPERATORS = %i[Tj ' TJ].freeze

      def self.normalize_rectangles(rectangles)
        rectangles.map do |rectangle|
          values = Array(rectangle).map(&:to_f)
          if values.size != 4 || values[0] == values[2] || values[1] == values[3]
            raise ArgumentError, 'Redaction rectangle must contain four different coordinates'
          end
          xs = [values[0], values[2]].minmax
          ys = [values[1], values[3]].minmax
          [xs[0], ys[0], xs[1], ys[1]]
        end
      end

      def initialize(document, resources, rectangles, clips: [], fill: true,
                   clones: [], xobject_counter: nil)
        super(resources)
        @document = document
        @rectangles = self.class.normalize_rectangles(rectangles)
        @fill = fill
        @clones = clones
        @clip_stack = [clips.dup]
        @path = []
        @current_point = nil
        @path_started = false
        @pending_clip_rule = nil
        @result = +''
        @serializer = Serializer.new
        @changed = false
        @xobject_counter_ref = xobject_counter || [0]
      end

      attr_reader :result
      attr_reader :changed

      def prune_unused_xobjects
        used = Set.new
        HexaPDF::Content::Parser.parse(result) do |operator, operands|
          used << operands[0] if operator == :Do
        end
        xobjects = resources[:XObject]
        return unless xobjects
        xobjects.each.to_a.each do |name, _|
          next if used.include?(name)
          xobjects.delete(name)
        end
      end

      def result_with_fill
        return result unless @fill
        result + @rectangles.map do |left, bottom, right, top|
          "q 1 g #{left} #{bottom} #{right - left} #{top - bottom} re f Q\n"
        end.join
      end

      def process(operator, operands = [])
        if TEXT_SHOW_OPERATORS.include?(operator)
          handle_text_operator(operator, operands)
        elsif operator == :BI
          handle_inline_image(operands)
        elsif operator == :Do
          handle_xobject(operands[0])
        elsif PATH_PAINT_OPERATORS.include?(operator)
          invoke_and_handle_state(operator, operands)
        else
          reject!("Redaction cannot safely handle the #{operator} operator") if
            UNSUPPORTED_OPERATORS.include?(operator)
          reject!("Redaction cannot safely handle the #{operator} operator") unless
            Operator::DEFAULT_OPERATORS.key?(operator)
          emit_operator(operator, operands)
          invoke_and_handle_state(operator, operands)
        end
      end

      private

      def invoke_and_handle_state(operator, operands)
        case operator
        when :q then save_state
        when :Q then restore_state
        when :m
          begin_path_operation
          move_to(operands)
        when :re then append_rectangle(operands)
        when :l then line_to(operands)
        when :c then curve_to(operands[0..1], operands[2..3], operands[4..5])
        when :v then curve_to(@current_point, operands[0..1], operands[2..3])
        when :y then curve_to(operands[0..1], operands[2..3], @current_point)
        when :h then @operators[:h].invoke(self)
        when :W, :'W*' then mark_clip(operator)
        when :n then end_empty_path
        else
          if PATH_PAINT_OPERATORS.include?(operator)
            paint_path(operator, operands)
          else
            @operators[operator].invoke(self, *operands) if @operators.key?(operator)
          end
        end
      end

      def emit_operator(operator, operands)
        @result << @operators[operator].serialize(@serializer, *operands)
      end

      def reject!(message)
        raise RedactionError, message
      end

      def save_state
        @operators[:q].invoke(self)
        @clip_stack << current_clips.dup
      end

      def restore_state
        reject!('Unmatched graphics state restoration operator Q') if @clip_stack.size == 1
        @operators[:Q].invoke(self)
        @clip_stack.pop
      end

      def move_to(operands)
        @operators[:m].invoke(self, *operands)
        start_subpath
        @path.last << operands.dup
        @current_point = operands.dup
      end

      def line_to(operands)
        @operators[:l].invoke(self, *operands)
        @path.last << operands.dup
        @current_point = operands.dup
      end

      def append_rectangle(operands)
        @operators[:re].invoke(self, *operands)
        x, y, width, height = operands
        @path << [[x, y], [x + width, y], [x + width, y + height], [x, y + height]]
        @path_started = true
        @current_point = [x + width, y + height]
      end

      def curve_to(point1, point2, point3)
        start_subpath unless @path_started
        flatten_cubic(@current_point, point1, point2, point3).drop(1).each do |point|
          @path.last << point
        end
        @current_point = point3.dup
      end

      def mark_clip(operator)
        @operators[operator].invoke(self)
        @pending_clip_rule = (operator == :W ? :nonzero : :even_odd)
      end

      def end_empty_path
        apply_pending_clip if @pending_clip_rule
        @operators[:n].invoke(self)
        reset_path
      end

      def paint_path(operator, operands)
        stroke = %i[S s B B* b b*].include?(operator)
        fill = %i[f F f* B B* b b*].include?(operator)
        fill_rule = %i[f* B* b*].include?(operator) ? :even_odd : :nonzero
        polygons = transformed_path_polygons
        if path_intersects?(polygons, stroke: stroke, fill: fill, fill_rule: fill_rule)
          reject_pattern_color!(stroke)
          @result << "n\n"
          @changed = true
          @operators[:n].invoke(self)
        else
          emit_operator(operator, operands)
          @operators[operator].invoke(self)
        end
        apply_pending_clip if @pending_clip_rule
        reset_path
      end

      def start_subpath
        @path << [] unless @path_started
        @path_started = true
      end

      def begin_path_operation
        @path = []
        @current_point = nil
        @path_started = false
      end

      def reset_path
        @path = []
        @current_point = nil
        @path_started = false
        @pending_clip_rule = nil
      end

      def flatten_cubic(p0, p1, p2, p3, steps = 16)
        (0..steps).map do |index|
          t = index.to_f / steps
          mt = 1 - t
          [
            mt**3 * p0[0] + 3 * mt**2 * t * p1[0] + 3 * mt * t**2 * p2[0] + t**3 * p3[0],
            mt**3 * p0[1] + 3 * mt**2 * t * p1[1] + 3 * mt * t**2 * p2[1] + t**3 * p3[1],
          ]
        end
      end

      def transformed_path_polygons
        @path.map do |polygon|
          (polygon + [polygon.first]).map {|point| ctm.evaluate(*point) }
        end
      end

      def apply_pending_clip
        transformed_path_polygons.each do |polygon|
          reject!('Redaction cannot safely handle empty clipping paths') if polygon.empty?
          current_clips << {polygon: polygon, rule: @pending_clip_rule}
        end
      end

      def current_clips
        @clip_stack.last
      end

      def ctm
        graphics_state.ctm
      end

      def handle_text_operator(operator, operands)
        case operator
        when :Tj
          rewritten = rewrite_text_string(operands[0])
          emit_text(operator, operands, rewritten ? :TJ : operator,
                    rewritten ? [rewritten] : [operands[0]])
        when :'"'
          rewritten = rewrite_text_string(operands[2])
          emit_text(operator, operands, rewritten ? :TJ : operator,
                    rewritten ? [rewritten] : [operands[2]], advance_line: true,
                    spacing: operands[0..1])
        when :"'"
          rewritten = rewrite_text_string(operands[0])
          emit_text(operator, operands, rewritten ? :TJ : operator,
                    rewritten ? [rewritten] : [operands[0]], advance_line: true)
        when :TJ
          rewritten = rewrite_positioned_text(operands[0])
          emit_text(operator, operands, :TJ, rewritten ? [rewritten] : [operands[0]])
        end
      end

      def rewrite_text_string(string)
        items = split_text(string)
        boxes = glyph_boxes(items.map {|code, _bytes| code })
        affected_indices = boxes.each_index.select do |index|
          visible_geometry?(boxes[index].points.each_slice(2).to_a) == :visible
        end
        return if affected_indices.empty?
        @changed = true
        items_to_tj_array(items, affected_indices)
      end

      def rewrite_positioned_text(array)
        items = []
        array.each do |item|
          if item.kind_of?(String)
            split_text(item).each do |code, bytes|
              items << [code, bytes]
            end
          else
            items << [nil, item]
          end
        end
        glyph_positions = []
        items.each_with_index {|(code, _), index| glyph_positions << index unless code.nil? }
        boxes = glyph_boxes(glyph_positions.map {|index| items[index][0] })
        affected_positions = Set.new
        boxes.each_with_index do |box, glyph_index|
          if visible_geometry?(box.points.each_slice(2).to_a) == :visible
            affected_positions << glyph_positions[glyph_index]
          end
        end
        return if affected_positions.empty?
        @changed = true
        positioned_items_to_tj_array(items, affected_positions)
      end

      def items_to_tj_array(items, affected_indices)
        output = []
        bytes = +''
        items.each_with_index do |(code, item_bytes), index|
          add_glyph_item(output, bytes, code, item_bytes, affected_indices.include?(index))
        end
        flush_bytes(output, bytes)
        output
      end

      def positioned_items_to_tj_array(items, affected_positions)
        output = []
        bytes = +''
        items.each_with_index do |(code, value), index|
          if code.nil?
            flush_bytes(output, bytes)
            output << value
          else
            add_glyph_item(output, bytes, code, value, affected_positions.include?(index))
          end
        end
        flush_bytes(output, bytes)
        output
      end

      def add_glyph_item(output, bytes, code, item_bytes, redacted)
        if redacted
          flush_bytes(output, bytes)
          output << -font_width(code) / 1000.0
        else
          bytes << item_bytes
        end
      end

      def flush_bytes(output, bytes)
        unless bytes.empty?
          output << bytes.dup
          bytes.clear
        end
      end

      def emit_text(original_operator, original_operands, emitted_operator, argument_lists,
                    advance_line: false, spacing: nil)
        arguments = argument_lists.first
        if advance_line
          if spacing
            @operators[:Tw].invoke(self, spacing[0])
            @operators[:Tc].invoke(self, spacing[1])
          end
          @operators[:'T*'].invoke(self)
        end
        if emitted_operator == :TJ
          @operators[:TJ].invoke(self, arguments)
          serialized_arguments = +''
          arguments.each_with_index do |argument, index|
            serialized_arguments << ' ' if index > 0
            if argument.is_a?(Numeric)
              serialized_arguments << @serializer.serialize_numeric(argument)
            else
              serialized_arguments << @serializer.serialize(argument.b)
            end
          end
          @result << "[#{serialized_arguments}]TJ\n"
        else
          @operators[original_operator].invoke(self, *original_operands)
          emit_operator(original_operator, original_operands)
        end
      end

      def split_text(string)
        font = graphics_state.font
        reject!('Text is shown without a font') unless font
        if font.is_a?(HexaPDF::Type::FontType0)
          reject!('Redaction cannot safely split this composite font text') unless
            font[:Encoding].is_a?(Symbol) || font[:Encoding].is_a?(HexaPDF::Stream)
          codes = font.decode(string)
          encode_type0_codes(codes, string)
        else
          bytes = string.bytes.map {|byte| [byte, byte.chr.b] }
          codes = bytes.map(&:first)
          codes.zip(bytes).map do |code, encoded|
            item_bytes = encoded.is_a?(Array) ? encoded[1] : encoded
            [code, item_bytes]
          end
        end
      end

      def encode_type0_codes(codes, string)
        lengths = code_lengths(codes, string.bytesize)
        offset = 0
        codes.each_with_index.map do |code, index|
          bytes = string.byteslice(offset, lengths[index])
          offset += lengths[index]
          [code, bytes]
        end
      end

      def code_lengths(codes, total_length)
        single_byte = Array.new(codes.size, 1)
        return single_byte if codes.size == total_length
        double_byte = codes.map {|code| code > 255 ? 2 : 1 }
        return double_byte if double_byte.sum == total_length
        reject!('Cannot safely split text string into character codes')
      end

      def glyph_boxes(codes)
        font = graphics_state.font
        reject!('Vertical text redaction is not supported') if font.writing_mode == :vertical
        reject!('Text clipping rendering modes cannot safely be redacted') if
          graphics_state.text_rendering_mode.value >= 4
        reject!('Type 3 fonts cannot safely be redacted') if font.is_a?(HexaPDF::Type::FontType3)
        bounding_box = font.bounding_box
        reject!('Font has no bounding box information') unless bounding_box
        below = bounding_box[1] * scaled_font_size / graphics_state.scaled_horizontal_scaling +
          graphics_state.text_rise
        above = bounding_box[3] * scaled_font_size / graphics_state.scaled_horizontal_scaling +
          graphics_state.text_rise
        tm = graphics_state.tm.dup
        codes.map do |code|
          width = glyph_advance_width(code)
          matrix = ctm.dup.premultiply(*tm)
          box = Processor::GlyphBox.new(code, '?', *matrix.evaluate(0, below),
                                       *matrix.evaluate(width, below),
                                       *matrix.evaluate(0, above))
          tm.translate(width, 0)
          box
        end
      end

      def glyph_advance_width(code)
        font = graphics_state.font
        unscaled_width = font_width(code)
        unscaled_width * scaled_font_size + graphics_state.scaled_character_spacing +
          (code == 32 && font.word_spacing_applicable? ?
            graphics_state.scaled_word_spacing : 0)
      end

      def font_width(code)
        font = graphics_state.font
        font.width(code)
      end

      def scaled_font_size
        graphics_state.scaled_font_size
      end

      def handle_xobject(name)
        xobject = resources.xobject(name)
        subtype = xobject[:Subtype]
        if subtype == :Form
          handle_form(name, xobject)
        elsif subtype == :Image
          handle_image(name, xobject)
        else
          reject!("Redaction cannot safely handle XObject subtype #{subtype}")
        end
      end

      def handle_form(name, form)
        reject!('Reference Form XObjects cannot safely be redacted') if form.reference_xobject?
        form_matrix = HexaPDF::Content::TransformationMatrix.new(*(form[:Matrix] || [1, 0, 0, 1, 0, 0]))
        form_ctm = ctm.dup.premultiply(*form_matrix)
        bbox = form.box.value
        bbox_polygon = rectangle_polygon(bbox).map {|point| form_ctm.evaluate(*point) }
        relation = polygon_relation(bbox_polygon)
        return emit_operator(:Do, [name]) if relation == :none
        return if relation == :full && current_clips.empty?

        form_clips = current_clips + [{polygon: bbox_polygon, rule: :nonzero}]
        child = Redaction.new(@document, form_resources(form), @rectangles,
                              clips: form_clips, fill: false, clones: @clones,
                              xobject_counter: @xobject_counter_ref)
        child.graphics_state.ctm = form_ctm
        HexaPDF::Content::Parser.parse(form.contents, child)
        unless child.changed
          return emit_operator(:Do, [name])
        end
        child.prune_unused_xobjects
        cloned_form = clone_stream(form)
        cloned_form[:Resources] = child.resources
        cloned_form.contents = child.result
        replacement_name = unique_xobject_name(resources[:XObject])
        resources[:XObject][replacement_name] = cloned_form
        @result << @operators[:Do].serialize(@serializer, replacement_name)
        @changed = true
      end

      def form_resources(form)
        source = form[:Resources] || @original_resources
        copied = copy_resources(source)
        @document.wrap(copied, type: :XXResources)
      end

      def copy_resources(resources)
        value = HexaPDF::Object.deep_copy(resources.value)
        [:ExtGState, :ColorSpace, :Pattern, :Shading, :XObject, :Font, :Properties].each do |key|
          next unless value[key].kind_of?(Hash)
          value[key] = value[key].dup
        end
        value
      end

      def unique_xobject_name(xobjects)
        loop do
          @xobject_counter_ref[0] += 1
          candidate = "RCT#{@xobject_counter_ref[0]}".to_sym
          return candidate unless xobjects.key?(candidate)
        end
      end

      def clone_stream(stream)
        cloned = @document.wrap(stream.value.dup, stream: stream.stream.dup)
        @document.add(cloned)
        @clones << cloned
        cloned
      end

      def handle_image(name, image)
        polygon = image_polygon
        relation = polygon_relation(polygon)
        return emit_operator(:Do, [name]) if relation == :none
        if relation == :full && current_clips.empty?
          @changed = true
          return
        end
        pixel_ranges = pixel_ranges(image)
        return emit_operator(:Do, [name]) if pixel_ranges.nil?
        redacted_image = redact_image(image, *pixel_ranges)
        replacement_name = unique_xobject_name(resources[:XObject])
        resources[:XObject][replacement_name] = redacted_image
        @result << @operators[:Do].serialize(@serializer, replacement_name)
        @changed = true
      end

      def image_polygon
        [[0, 0], [1, 0], [1, 1], [0, 1]].map {|point| ctm.evaluate(*point) }
      end

      def polygon_relation(polygon)
        return :none unless @rectangles.any? {|rectangle| polygons_overlap?(polygon, rectangle) }
        @rectangles.each do |rectangle|
          next unless polygons_overlap?(polygon, rectangle)
          return :full if polygon.all? {|point| point_in_rectangle?(point, rectangle) }
          rectangle_sample_points(rectangle).each do |point|
            next unless point_in_polygon?(point, polygon)
            return :visible if visible_point?(point)
          end
        end
        :uncertain
      end

      def rectangle_sample_points(rectangle)
        left, bottom, right, top = rectangle
        mid_x = (left + right) / 2.0
        mid_y = (bottom + top) / 2.0
        [[left, bottom], [right, bottom], [right, top], [left, top],
         [mid_x, bottom], [mid_x, top], [left, mid_y], [right, mid_y], [mid_x, mid_y]]
      end

      def polygons_overlap?(polygon, rectangle)
        return true if polygon.any? {|point| point_in_rectangle?(point, rectangle) }
        rectangle_polygon(rectangle).any? {|point| point_in_polygon?(point, polygon) } ||
          polygon.each_cons(2).any? do |p1, p2|
            rectangle_edges(rectangle).any? {|q1, q2| segment_intersection(p1, p2, q1, q2) }
          end
      end

      def point_in_polygon?(point, polygon)
        point_in_polygons?(point, [polygon], :nonzero)
      end

      def rectangle_polygon(rectangle)
        left, bottom, right, top = rectangle
        [[left, bottom], [right, bottom], [right, top], [left, top]]
      end

      def redact_image(image, x_range, y_range)
        info = image_information(image)
        cloned = clone_stream(image)
        pixels = image.stream.dup
        row_size = (info[:width] * info[:components] * info[:bits] + 7) / 8
        expected = row_size * info[:height]
        reject!('Image data does not match its dimensions') unless pixels.bytesize == expected
        redact_pixel_data(pixels, info, x_range, y_range)
        assign_image_data(cloned, pixels, info[:components], info[:bits])
        redact_soft_mask(cloned, info, x_range, y_range)
        cloned
      end

      def image_information(image)
        filters = Array(image[:Filter])
        unless filters.all? {|filter| filter.nil? || filter == :FlateDecode || filter == :LZWDecode ||
                                      filter == :RunLengthDecode }
          reject!('Encoded images cannot be partially redacted without pixel re-encoding')
        end
        if image[:ImageMask]
          reject!('Image masks cannot safely be partially redacted')
        end
        if image.key?(:Mask) || image.key?(:Decode)
          reject!('Images with masks or custom decode mappings cannot safely be partially redacted')
        end
        components = image_components(image[:ColorSpace])
        bits = image[:BitsPerComponent]
        unless [1, 2, 4, 8].include?(bits)
          reject!("Images with #{bits} bits per component cannot safely be partially redacted")
        end
        smask = image[:SMask]
        if smask && (smask[:BitsPerComponent] != 8 || smask[:ColorSpace] != :DeviceGray ||
                     smask.width != image.width || smask.height != image.height)
          reject!('Unsupported soft mask on partially redacted image')
        end
        {width: image.width, height: image.height, components: components, bits: bits, smask: smask}
      end

      def image_components(color_space)
        family = color_space.is_a?(Array) ? color_space[0] : color_space
        case family
        when :DeviceGray, :CalGray then 1
        when :DeviceRGB, :CalRGB then 3
        when :ICCBased then (color_space[1][:N] || 3)
        when :DeviceCMYK then 4
        else
          reject!("Unsupported image color space #{family.inspect}")
        end
      end

      def pixel_ranges(image)
        info = {width: image.width, height: image.height}
        min_x = nil
        max_x = nil
        min_y = nil
        max_y = nil
        info[:height].times do |y|
          info[:width].times do |x|
            center = ctm.evaluate((x + 0.5) / info[:width], (y + 0.5) / info[:height])
            next unless current_clips.all? {|clip| point_in_clip?(center, clip) }
            next unless @rectangles.any? do |rectangle|
              center[0] >= rectangle[0] && center[0] <= rectangle[2] &&
                center[1] >= rectangle[1] && center[1] <= rectangle[3]
            end
            min_x = x if min_x.nil? || x < min_x
            max_x = x if max_x.nil? || x > max_x
            min_y = y if min_y.nil? || y < min_y
            max_y = y if max_y.nil? || y > max_y
          end
        end
        return nil if min_x.nil?
        [(min_x..max_x), (min_y..max_y)]
      end

      def redact_pixel_data(pixels, info, x_range, y_range)
        components = info[:components]
        bits = info[:bits]
        y_range.each do |y|
          x_range.each do |x|
            data_y = info[:height] - y - 1
            components.times do |component|
              write_pixel_component(pixels, info[:width], components, bits, x, data_y,
                                   component, 0)
            end
          end
        end
      end

      def write_pixel_component(data, width, components, bits, x, y, component, value)
        if bits == 8
          index = y * width * components + x * components + component
          data.setbyte(index, value)
        else
          bit_index = (y * width * components + x * components + component) * bits
          byte_index = bit_index / 8
          shift = 8 - bits - (bit_index % 8)
          mask = ((1 << bits) - 1) << shift
          data.setbyte(byte_index, (data.getbyte(byte_index) & ~mask) | ((value << shift) & mask))
        end
      end

      def assign_image_data(image, data, components, bits)
        image.stream = data
        image.set_filter(:FlateDecode, Predictor: 15, Colors: components,
                                     Columns: image.width, BitsPerComponent: bits)
      end

      def redact_soft_mask(image, info, x_range, y_range)
        mask = info[:smask]
        return unless mask
        cloned_mask = clone_stream(mask)
        data = mask.stream.dup
        y_range.each do |y|
          x_range.each do |x|
            data.setbyte((info[:height] - y - 1) * info[:width] + x, 0)
          end
        end
        cloned_mask.stream = data
        cloned_mask.set_filter(:FlateDecode, Predictor: 15, Colors: 1,
                                          Columns: info[:width], BitsPerComponent: 8)
        image[:SMask] = cloned_mask
      end

      def handle_inline_image(operands)
        dictionary, _data = operands
        reject!('Encoded inline images cannot safely be partially redacted') if dictionary.key?(:F)
        reject!('Inline images use an unsupported color space for redaction') unless
          dictionary[:CS].nil? || dictionary[:CS] == :DeviceRGB || dictionary[:CS] == :DeviceGray
        polygon = image_polygon
        relation = polygon_relation(polygon)
        return emit_operator(:BI, operands) if relation == :none
        if relation != :full || !current_clips.empty?
          reject!('Inline images cannot safely be partially or clipped redacted')
        end
        @changed = true
      end

      def path_intersects?(polygons, stroke:, fill:, fill_rule: :nonzero)
        polygons.any? do |polygon|
          stroked = stroke && stroke_polygons(polygon).compact.any? do |candidate|
            visible_geometry?(candidate) != :none || contains_visible_redaction_point?(candidate, :nonzero, [candidate])
          end
          filled = fill && (visible_geometry?(polygon, fill_rule, polygons) != :none ||
            contains_visible_redaction_point?(polygon, fill_rule, polygons))
          stroked || filled
        end
      end

      def contains_visible_redaction_point?(polygon, fill_rule, fill_polygons)
        @rectangles.any? do |rectangle|
          rectangle_sample_points(rectangle).any? do |point|
            visible_point?(point) && point_in_polygons?(point, fill_polygons, fill_rule)
          end
        end
      end

      def stroke_polygons(polygon)
        scale = average_scale
        half = (graphics_state.line_width.abs * scale) / 2.0
        return [polygon] if half.zero?
        polygon.each_cons(2).map do |point1, point2|
          dx = point2[0] - point1[0]
          dy = point2[1] - point1[1]
          length = Math.sqrt(dx**2 + dy**2)
          if length.zero?
            [point1[0] - half, point1[1] - half, point1[0] + half, point1[1] + half]
          else
            nx = -dy / length * half
            ny = dx / length * half
            [[point1[0] + nx, point1[1] + ny], [point2[0] + nx, point2[1] + ny],
             [point2[0] - nx, point2[1] - ny], [point1[0] - nx, point1[1] - ny]]
          end
        end
      end

      def average_scale
        origin = ctm.evaluate(0, 0)
        x_point = ctm.evaluate(1, 0)
        y_point = ctm.evaluate(0, 1)
        [Math.sqrt((x_point[0] - origin[0])**2 + (x_point[1] - origin[1])**2),
         Math.sqrt((y_point[0] - origin[0])**2 + (y_point[1] - origin[1])**2)].max
      end

      def reject_pattern_color!(stroke)
        color = stroke ? graphics_state.stroke_color : graphics_state.fill_color
        return unless color.respond_to?(:color_space) && color.color_space.family == :Pattern
        reject!('Redaction cannot safely handle pattern-painted vector graphics')
      end

      def visible_geometry?(polygon, fill_rule = nil, fill_polygons = nil)
        candidates = polygon + polygon_intersection_points(polygon)
        points = candidates.select {|point| visible_point?(point) }
        return :none if points.empty? && !edge_intersects_redaction?(polygon)
        return :uncertain unless points.any? do |point|
          fill_rule.nil? || point_in_polygons?(point, fill_polygons || [polygon], fill_rule)
        end
        :visible
      end

      def visible_point?(point)
        @rectangles.any? {|rectangle| point_in_rectangle?(point, rectangle) } &&
          current_clips.all? {|clip| point_in_clip?(point, clip) }
      end

      def edge_intersects_redaction?(polygon)
        @rectangles.any? do |rectangle|
          polygon.each_cons(2).any? {|p1, p2| segment_intersects_rectangle?(p1, p2, rectangle) }
        end
      end

      def polygon_intersection_points(polygon)
        @rectangles.flat_map do |rectangle|
          rectangle_edges(rectangle).flat_map do |edge|
            polygon.each_cons(2).map {|p1, p2| segment_intersection(p1, p2, edge[0], edge[1]) }
          end
        end.compact
      end

      def rectangle_edges(rectangle)
        left, bottom, right, top = rectangle
        [[[left, bottom], [right, bottom]], [[right, bottom], [right, top]],
         [[right, top], [left, top]], [[left, top], [left, bottom]]]
      end

      def point_in_rectangle?(point, rectangle)
        return false unless point.is_a?(Array) && point.size == 2 &&
                            point.all? {|coordinate| coordinate.is_a?(Numeric) }
        point[0] >= rectangle[0] && point[0] <= rectangle[2] &&
          point[1] >= rectangle[1] && point[1] <= rectangle[3]
      end

      def segment_intersects_rectangle?(p1, p2, rectangle)
        rectangle_edges(rectangle).any? {|q1, q2| segment_intersection(p1, p2, q1, q2) }
      end

      def segment_intersection(p1, p2, p3, p4)
        return unless [p1, p2, p3, p4].all? {|point| point.is_a?(Array) && point.size == 2 &&
                                                point.all? {|coordinate| coordinate.is_a?(Numeric)} }
        x1, y1 = p1
        x2, y2 = p2
        x3, y3 = p3
        x4, y4 = p4
        denominator = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
        return if denominator.abs < 1e-12
        t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)).to_f / denominator
        u = -((x1 - x2) * (y1 - y3) - (y1 - y2) * (x1 - x3)).to_f / denominator
        return unless (0..1).cover?(t) && (0..1).cover?(u)
        [x1 + t * (x2 - x1), y1 + t * (y2 - y1)]
      end

      def point_in_clip?(point, clip)
        point_in_polygons?(point, [clip[:polygon]], clip[:rule])
      end

      def point_in_polygons?(point, polygons, rule)
        winding = polygons.sum {|polygon| winding_number(point, closed_polygon(polygon)) }
        if rule == :even_odd
          winding.odd?
        else
          winding != 0
        end
      end

      def closed_polygon(polygon)
        polygon.last == polygon.first ? polygon : polygon + [polygon.first]
      end

      def winding_number(point, polygon)
        x, y = point
        polygon.each_cons(2).sum(0) do |(x1, y1), (x2, y2)|
          if y1 < y
            next(y2 >= y && cross_value(x1, y1, x2, y2, x, y) > 0 ? 1 : 0)
          end
          next(y2 < y && cross_value(x1, y1, x2, y2, x, y) < 0 ? -1 : 0)
        end
      end

      def cross_value(x1, y1, x2, y2, x, y)
        (x2 - x1) * (y - y1) - (y2 - y1) * (x - x1)
      end

    end
  end
end
