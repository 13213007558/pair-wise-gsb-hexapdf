# -*- encoding: utf-8; frozen_string_literal: true -*-

require 'geom2d/algorithms/polygon_operation'
require 'hexapdf/filter'
require 'hexapdf/serializer'
require 'hexapdf/content/processor'
require 'hexapdf/utils/bit_stream'

module HexaPDF
  module Content

    # Rewrites content streams to irreversibly remove text, vector graphics and bitmap data inside
    # page rectangles.
    class Redaction < Processor

      PAINT_OPERATORS = [:S, :s, :f, :F, :'f*', :B, :'B*', :b, :'b*'].freeze
      TEXT_SHOW_OPERATORS = [:Tj, :TJ, :"'", :'"']

      def self.redact(page, rectangles, color:)
        rectangles = rectangles.first.is_a?(Numeric) ? [rectangles] : rectangles
        targets = rectangles.map {|rectangle| send(:normalize_target, rectangle) }
        return if targets.empty?

        new(page.document, targets, color: color, apply: false).process_page(page)
        redactor = new(page.document, targets, color: color, apply: true)
        redactor.process_page(page)
        page.document.task(:optimize, compact: true, object_streams: :preserve,
                         xref_streams: :preserve)
      end

      def self.normalize_target(rectangle)
        left, bottom, right, top = rectangle.map(&:to_f)
        left, right = right, left if left > right
        bottom, top = top, bottom if bottom > top
        Geom2D::PolygonSet.new([Geom2D::Polygon([left, bottom], [right, bottom],
                                                [right, top], [left, top])])
      end

      def initialize(document, targets, color:, apply:)
        super()
        @document = document
        @targets = targets
        @color = color
        @apply = apply
        @serializer = Serializer.new
        @result = +''.b
        @clips = []
        @path = nil
        @path_tokens = nil
        @pending_clips = []
        @form_stack = []
        @wrapper_number = 0
        @font_bounds = {}
      end

      def process_page(page)
        reject_intersecting_annotation(page)
        page_box = rectangle_to_polyset(page.box(:crop))

        if @apply
          resources = duplicate_page_resources(page)
          stream = process_stream(page.contents, resources, page_box)
          prune_xobjects(resources, stream)
          stream << mark_stream
          replacement = @document.add({Filter: :FlateDecode}, stream: stream)
          page[:Contents] = replacement
        else
          process_stream(page.contents, page.resources, page_box)
        end
      end

      def process(operator, operands = [])
        case operator
        when :q then save_state(operator, operands)
        when :Q then restore_state(operator, operands)
        when :cm then invoke_and_serialize(operator, operands)
        when :gs then set_graphics_state(operands[0])
        when :m, :re, :l, :c, :v, :y, :h then append_path_operator(operator, operands)
        when :W, :'W*' then queue_clip(operator, operands)
        when *PAINT_OPERATORS then paint_path(operator, operands)
        when :n then end_path(operator, operands)
        when :BT, :ET then handle_text_object(operator, operands)
        when *TEXT_SHOW_OPERATORS then show_text_operator(operator, operands)
        when :Do then paint_xobject(operands[0])
        when :sh then paint_shading
        when :BI
          if inline_image_visible?(operands)
            reject('inline image intersects a redaction rectangle')
          else
            invoke_and_serialize(operator, operands)
          end
        else
          invoke(operator, operands)
          serialize(operator, operands)
        end
      end

      private

      def move_text_next_line_and_show_text(_text)
      end

      def set_spacing_move_text_next_line_and_show_text(_word_space, _char_space, _text)
      end

      def reject(message)
        raise HexaPDF::Error, "Cannot perform content redaction: #{message}"
      end

      def invoke(operator, operands)
        @operators.fetch(operator) { @operators[operator] = Operator::BaseOperator.new(operator.to_s) }.
          invoke(self, *operands)
      end

      def serialize(operator, operands)
        @result << @operators.fetch(operator) do
          @operators[operator] = Operator::BaseOperator.new(operator.to_s)
        end.serialize(@serializer, *operands)
      end

      def invoke_and_serialize(operator, operands)
        invoke(operator, operands)
        serialize(operator, operands)
      end

      def process_stream(contents, stream_resources, initial_clip)
        previous_result = @result
        previous_resources = @resources
        previous_original_resources = @original_resources
        previous_clips = @clips

        @result = +''.b
        self.resources = stream_resources
        @clips = [initial_clip]
        reset_path
        Parser.parse(contents, self)
        reject('unclosed path construction') if @path
        @result
      ensure
        @result = previous_result unless previous_result.nil?
        @resources = previous_resources unless previous_resources.nil?
        @original_resources = previous_original_resources unless previous_original_resources.nil?
        @clips = previous_clips unless previous_clips.nil?
      end

      def mark_stream
        operands = @color.map {|value| value.to_f.positive? && value <= 1 ? value.to_f : value.to_f / 255.0 }
        operator = operands.length == 1 ? :g : (operands.length == 4 ? :k : :rg)
        result = +''.b
        @targets.each do |target|
          polygon = target.polygons.first
          result << "#{format_number(polygon[0].x)} #{format_number(polygon[0].y)} " \
                   "#{format_number(polygon[2].x - polygon[0].x)} " \
                   "#{format_number(polygon[2].y - polygon[0].y)} re\n"
        end
        result << operands.map {|v| format_number(v) }.join(' ') << " #{operator}\n"
        result
      end

      def format_number(number)
        number == number.to_i ? number.to_i.to_s : @serializer.serialize_numeric(number)
      end

      def reject_intersecting_annotation(page)
        page.each_annotation do |annotation|
          next if annotation.flagged?(:invisible) || annotation.flagged?(:hidden)
          next unless rectangle_to_polyset(annotation[:Rect]) &&
                      visible_polyset?(rectangle_to_polyset(annotation[:Rect]), graphics_state.ctm)
          reject('intersecting annotations are not redacted')
        end
      end

      def duplicate_page_resources(page)
        resources = duplicate_dictionary(page.resources)
        page[:Resources] = resources
        make_xobjects_mutable(resources)
        resources
      end

      def duplicate_dictionary(dictionary)
        copy = dictionary.value.dup
        copy.each {|key, value| copy[key] = value.dup if value.kind_of?(::Hash) || value.kind_of?(PDFArray) }
        @document.wrap(copy, type: :XXResources)
      end

      def make_xobjects_mutable(resources)
        return unless resources[:XObject]
        resources[:XObject] = resources[:XObject].value.dup
      end

      def prune_xobjects(resources, contents)
        return unless resources[:XObject]
        used = {}
        Parser.parse(contents) do |operator, operands|
          used[operands[0]] = true if operator == :Do
        end
        resources[:XObject].value.keys.each do |name|
          resources[:XObject].delete(name) unless used.key?(name)
        end
      end

      def save_state(operator, operands)
        invoke(operator, operands)
        @clips << @clips.last.dup
        serialize(operator, operands)
      end

      def restore_state(operator, operands)
        reject('restored graphics state without a matching save') unless @clips.size > 1
        reject('unclosed path during graphics state restoration') if @path
        invoke(operator, operands)
        @clips.pop
        serialize(operator, operands)
      end

      def set_graphics_state(name)
        state_dict = resources.ext_gstate(name)
        invoke(:gs, [name])
        serialize(:gs, [name])
      end

      def handle_text_object(operator, operands)
        reject('text object started with an open path') if @path
        invoke_and_serialize(operator, operands)
      end

      def reset_path
        @path = nil
        @path_tokens = nil
        @pending_clips = []
        graphics_object = :none
      end

      def append_path_operator(operator, operands)
        reject('path construction after clipping operator') if @pending_clips.any?
        @path ||= {subpaths: [[]], closed: []}
        @path_tokens ||= +''.b
        @path_tokens << @operators[operator].serialize(@serializer, *operands)
        invoke(operator, operands)

        case operator
        when :m
          @path[:subpaths] << [] unless @path[:subpaths].last.empty?
          @path[:subpaths].last << operands
        when :re
          x, y, width, height = operands
          subpath = [[x, y], [x + width, y], [x + width, y + height], [x, y + height], [x, y]]
          @path[:subpaths] << [] unless @path[:subpaths].last.empty?
          @path[:subpaths].last.concat(subpath)
        when :l
          @path[:subpaths].last << operands
        when :h
          subpath = @path[:subpaths].last
          subpath << subpath.first.dup if subpath.length >= 2 && subpath.last != subpath.first
        when :c, :v, :y
          append_curve_points(operator, operands)
        end
      end

      def append_curve_points(operator, operands)
        subpath = @path[:subpaths].last
        reject('curve without current point') if subpath.empty?
        start = subpath.last
        control1, control2, endpoint = case operator
                                       when :c then operands.each_slice(2).to_a
                                       when :v then [start, *operands.each_slice(2).to_a]
                                       else [operands.each_slice(2).to_a.first, operands.each_slice(2).to_a.first, operands.each_slice(2).to_a.last]
                                       end
        1.upto(16) do |index|
          t = index / 16.0
          subpath << bezier_point(start, control1, control2, endpoint, t)
        end
      end

      def bezier_point(p0, p1, p2, p3, t)
        one_minus = 1.0 - t
        [
          one_minus**3 * p0[0] + 3 * one_minus**2 * t * p1[0] +
            3 * one_minus * t**2 * p2[0] + t**3 * p3[0],
          one_minus**3 * p0[1] + 3 * one_minus**2 * t * p1[1] +
            3 * one_minus * t**2 * p2[1] + t**3 * p3[1],
        ]
      end

      def queue_clip(operator, operands)
        reject('clipping operator outside a path') unless @path
        @pending_clips << operator
        @path_tokens << @operators[operator].serialize(@serializer, *operands)
      end

      def paint_path(operator, operands)
        apply_pending_clips
        visible = painted_path_visible?(operator)
        invoke_pending_clip_operators
        invoke(operator, operands)

        if visible
          if @path_tokens =~ /W\*?\n\z/
            @result << @path_tokens
            @result << "n\n"
          end
        else
          @result << @path_tokens << @operators[operator].serialize(@serializer, *operands)
        end
      ensure
        reset_path
      end

      def paint_xobject(name)
        xobject = @document.deref(resources.xobject(name))
        if xobject[:Subtype] == :Form
          paint_form_xobject(name, xobject)
        elsif xobject[:Subtype] == :Image
          paint_image_xobject(name, xobject)
        elsif xobject_visible?(xobject)
          reject("unsupported XObject subtype #{xobject[:Subtype]}")
        else
          serialize(:Do, [name])
        end
      end

      def xobject_visible?(xobject)
        case xobject[:Subtype]
        when :Image
          visible_polyset?(unit_polygon, graphics_state.ctm)
        else
          bbox = xobject[:BBox] ? rectangle_to_polyset(xobject[:BBox]) : nil
          bbox.nil? || visible_polyset?(bbox, graphics_state.ctm)
        end
      end

      def paint_form_xobject(name, form)
        reject('reference Form XObject intersects a redaction rectangle') if form.reference_xobject?
        matrix = graphics_state.ctm.dup
        form_bbox = rectangle_to_polyset(form.box)
        unless visible_polyset?(form_bbox, matrix)
          serialize(:Do, [name])
          return
        end

        reject('recursive Form XObject use') if @form_stack.include?(form.data)
        current_resources = resources
        form_matrix = form[:Matrix]
        if @apply
          form = clone_form(form)
        end
        current_form = form

        @form_stack << current_form.data
        graphics_state.save
        graphics_state.ctm.premultiply(*form_matrix.value)
        form_polyset = transformed_polyset(rectangle_to_polyset(current_form.box), graphics_state.ctm.dup)
        clip = intersect_polysets(@clips.last, form_polyset)
        @clips << clip
        result = process_stream(current_form.contents, current_form.resources, clip)
        current_form.contents = result if @apply
        prune_xobjects(current_form.resources, result) if @apply
        page_bbox = transformed_polyset(form_polyset, graphics_state.ctm.dup)
        graphics_state.restore
        @clips.pop
        @form_stack.pop
        self.resources = current_resources
        if @apply
          wrapper = create_use_wrapper(form, page_bbox, TransformationMatrix.new)
          serialize(:Do, [add_xobject(wrapper)])
        else
          serialize(:Do, [name])
        end
      end

      def clone_form(form)
        copy = @document.add(form.value.dup)
        copy.stream = fully_decoded_stream(form)
        copied_resources = duplicate_dictionary(form.resources)
        copy[:Resources] = copied_resources
        make_xobjects_mutable(copied_resources)
        copy.set_filter(:FlateDecode)
        copy[:Matrix] = [1, 0, 0, 1, 0, 0]
        copy
      end

      def paint_image_xobject(name, image)
        reject('soft mask graphics state intersects a redaction rectangle') if graphics_state.soft_mask != :None
        quad = Geom2D::PolygonSet.new([unit_polygon])
        unless visible_polyset?(quad, graphics_state.ctm)
          serialize(:Do, [name])
          return
        end

        matrix = graphics_state.ctm
        full = extract_polygons(quad).first.each_vertex.all? {|point| matrix_point_in_targets?(matrix, point) }
        inverse = inverse_matrix(matrix)
        local_target = if full
                         unit_polygon
                       else
                         @targets.map do |target|
                           intersect_polysets(unit_polygon, transformed_polyset(target, inverse))
                         end.reduce {|result, target| union_polysets(result, target) }
                       end
        unless full
          local_clip = transformed_polyset(@clips.last, inverse)
          local_target = intersect_polysets(local_target, intersect_polysets(unit_polygon, local_clip))
        end
        reject('cannot determine image region to redact') if local_target.nr_of_contours.zero?

        if @apply
          image = ImageSanitizer.new(@document, image).redact(local_target)
          wrapper = create_use_wrapper(image, unit_polygon, matrix)
          serialize(:Do, [add_xobject(wrapper)])
        else
          ImageSanitizer.validate(image)
          serialize(:Do, [name])
        end
      end

      def add_xobject(xobject)
        resources[:XObject] = resources[:XObject].value.dup
        name = "Re#{@wrapper_number += 1}".to_sym
        resources[:XObject][name] = xobject
        name
      end

      def create_use_wrapper(inner, local_bbox, placement_matrix)
        bbox = bounding_rectangle(local_bbox)
        inner_name = "Use#{@wrapper_number += 1}".to_sym
        stream = +"q "
        stream << placement_matrix.to_a.map {|value| format_number(value) }.join(' ')
        stream << " cm /#{inner_name} Do Q\n"
        @document.add({Type: :XObject, Subtype: :Form, BBox: bbox,
                       Resources: {XObject: {inner_name => inner}},
                       Filter: :FlateDecode}, stream: stream)
      end

      def bounding_rectangle(polyset)
        bbox = polyset.bbox
        [bbox.min_x, bbox.min_y, bbox.max_x, bbox.max_y]
      end

      def unit_polygon
        Geom2D::PolygonSet.new([Geom2D::Polygon([0, 0], [1, 0], [1, 1], [0, 1])])
      end

      def matrix_point_in_targets?(matrix, point)
        transformed = Geom2D::Point(*matrix.evaluate(point.x, point.y))
        point_in_target?(transformed)
      end

      def union_polysets(first, second)
        Geom2D::Algorithms::PolygonOperation.run(first, second, :union)
      rescue StandardError
        first
      end

      def inverse_matrix(matrix)
        determinant = matrix.a * matrix.d - matrix.b * matrix.c
        reject('singular image transformation') if determinant.abs < 1e-12
        inverse_determinant = 1.0 / determinant
        TransformationMatrix.new(
          matrix.d * inverse_determinant, -matrix.b * inverse_determinant,
          -matrix.c * inverse_determinant, matrix.a * inverse_determinant,
          (matrix.c * matrix.f - matrix.d * matrix.e) * inverse_determinant,
          (matrix.b * matrix.e - matrix.a * matrix.f) * inverse_determinant
        )
      end

      def decoded_stream(stream_object)
        HexaPDF::Filter.string_from_source(stream_object.stream_decoder)
      end

      def fully_decoded_stream(stream_object)
          raw = stream_object.raw_stream
          if raw.kind_of?(StreamData)
            decoded_stream(stream_object)
          else
            source = HexaPDF::Filter.source_from_string(raw.to_s)
            filters = Array(stream_object[:Filter])
            parms = Array(stream_object[:DecodeParms])
            filters.zip(parms).reverse_each do |filter, parameter|
              source = stream_object.send(:filter_for_name, filter).decoder(source, parameter) unless filter.nil?
            end
            HexaPDF::Filter.string_from_source(source)
          end
      end

      def end_path(operator, operands)
        pending = @pending_clips.dup
        apply_pending_clips
        invoke_pending_clip_operators
        invoke(operator, operands)
        if pending.any?
          @result << @path_tokens << @operators[operator].serialize(@serializer, *operands)
        end
      ensure
        reset_path
      end

      def apply_pending_clips
        return if @pending_clips.empty?
        validate_path
        clip = path_polyset
        reject('empty clipping path') if clip.nr_of_contours.zero?
        @clips[-1] = intersect_polysets(@clips.last, clip)
      end

      def invoke_pending_clip_operators
        @pending_clips.size.times do |index|
          invoke(@pending_clips[index], [])
          graphics_object = :clipping_path if index < @pending_clips.size - 1
        end
      end

      def validate_path
        reject('invalid path construction') unless @path && @path[:subpaths].any? {|subpath| subpath.length >= 3 }
      end

      def path_polyset
        polygons = @path[:subpaths].select {|subpath| subpath.length >= 3 }.map do |subpath|
          Geom2D::Polygon.new(subpath.map {|point| graphics_state.ctm.evaluate(*point) })
        end
        Geom2D::PolygonSet.new(polygons)
      end

      def painted_path_visible?(operator)
        validate_path
        reject('soft mask graphics state intersects a redaction rectangle') if graphics_state.soft_mask != :None
        if stroked_operator?(operator) && graphics_state.stroke_color.color_space.family == :Pattern
          reject_painted(operator, [], 'tiling pattern')
        end
        if filled_operator?(operator) && graphics_state.fill_color.color_space.family == :Pattern
          reject_painted(operator, [], 'tiling pattern')
        end
        return false unless painted_alpha_visible?(operator)
        filled_path_intersects_targets? || stroke_or_clip_intersects_targets?
      end

      def stroked_operator?(operator)
        [:S, :s, :B, :'B*', :b, :'b*'].include?(operator)
      end

      def filled_operator?(operator)
        [:f, :F, :'f*', :B, :'B*', :b, :'b*'].include?(operator)
      end

      def painted_alpha_visible?(operator)
        (!stroked_operator?(operator) || graphics_state.stroke_alpha != 0) &&
          (!filled_operator?(operator) || graphics_state.fill_alpha != 0)
      end

      def path_intersects_targets?
        points = @path[:subpaths].flat_map {|subpath| subpath }.map do |point|
          graphics_state.ctm.evaluate(*point)
        end
        xs = points.map(&:first).minmax
        ys = points.map(&:last).minmax
        polygon = Geom2D::Polygon.new([[xs[0], ys[0]], [xs[1], ys[0]], [xs[1], ys[1]], [xs[0], ys[1]]])
        visible_polyset?(Geom2D::PolygonSet.new([polygon]), TransformationMatrix.new)
      end

      def filled_path_intersects_targets?
        path_intersects_targets?
      end

      def stroke_or_clip_intersects_targets?
        result = @path[:subpaths].any? do |subpath|
          subpath.each_cons(2).any? do |point1, point2|
            segment_intersects_targets?(point1, point2)
          end
        end
        result
      end

      def segment_intersects_targets?(point1, point2)
        width = graphics_state.line_width.to_f
        transformed = [point1, point2].map {|point| graphics_state.ctm.evaluate(*point) }
        xs = transformed.map(&:first).minmax
        ys = transformed.map(&:last).minmax
        margin = [graphics_state.ctm.a.abs, graphics_state.ctm.b.abs,
                  graphics_state.ctm.c.abs, graphics_state.ctm.d.abs].max * width / 2.0
        polygon = Geom2D::Polygon.new([[xs[0] - margin, ys[0] - margin], [xs[1] + margin, ys[0] - margin],
                                       [xs[1] + margin, ys[1] + margin], [xs[0] - margin, ys[1] + margin]])
        result = visible_polyset?(Geom2D::PolygonSet.new([polygon]), TransformationMatrix.new)
        result
      end

      def rectangle_to_polyset(rectangle)
        Geom2D::PolygonSet.new([Geom2D::Polygon([rectangle.left, rectangle.bottom],
                                                [rectangle.right, rectangle.bottom],
                                                [rectangle.right, rectangle.top],
                                                [rectangle.left, rectangle.top])])
      rescue StandardError
        nil
      end

      def transformed_polyset(polyset, matrix = graphics_state.ctm)
        polygons = extract_polygons(polyset)
        Geom2D::PolygonSet.new(polygons.map do |polygon|
          Geom2D::Polygon.new(polygon.each_vertex.map {|point| matrix.evaluate(point.x, point.y) })
        end)
      end

      def extract_polygons(polyset)
        return polyset.polygons.flat_map {|polygon| extract_polygons(polygon) } if polyset.is_a?(Geom2D::PolygonSet)
        [polyset]
      end

      def intersect_polysets(first, second)
        Geom2D::Algorithms::PolygonOperation.run(first, second, :intersection)
      rescue StandardError
        conservative_intersection(first, second)
      end

      def conservative_intersection(first, second)
        first_bbox = first.bbox
        second_bbox = second.bbox
        return Geom2D::PolygonSet.new if bbox_disjoint?(first_bbox, second_bbox)
        first
      end

      def bbox_disjoint?(first, second)
        first.max_x < second.min_x || first.min_x > second.max_x ||
          first.max_y < second.min_y || first.min_y > second.max_y
      end

      def visible_polyset?(polyset, matrix = graphics_state.ctm)
        transformed = transformed_polyset(polyset, matrix)
        return false if transformed.nr_of_contours.zero?
        bbox = transformed.bbox
        @targets.any? do |target|
          next false if bbox_disjoint?(bbox, target.bbox)
          intersection = intersect_polysets(intersect_polysets(transformed, @clips.last), target)
          next true if intersection.nr_of_contours.positive?
          transformed.polygons.any? do |polygon|
            polygon.each_vertex.any? {|point| point_in_target?(point) && point_in_clip?(point) }
          end
        end
      end

      def point_in_target?(point)
        @targets.any? {|target| point_in_polyset?(point, target) }
      end

      def point_in_clip?(point)
        point_in_polyset?(point, @clips.last)
      end

      def point_in_polyset?(point, polyset)
        polyset.polygons.any? {|polygon| point_in_polygon?(point, polygon) }
      end

      def point_in_polygon?(point, polygon)
        inside = false
        vertices = polygon.each_vertex.to_a
        vertices.each_with_index do |vertex, index|
          other = vertices[(index + 1) % vertices.length]
          next unless (vertex.y > point.y) != (other.y > point.y)
          x_intersection = (other.x - vertex.x) * (point.y - vertex.y) / (other.y - vertex.y) + vertex.x
          inside = !inside if point.x < x_intersection
        end
        inside
      end

      def reject_painted(operator, operands, kind)
        invoke(operator, operands) rescue nil
        reject("unsupported #{kind} intersects a redaction rectangle")
      end

      def paint_shading
        reject('shading intersects a redaction rectangle') if shading_visible?
      end

      def shading_visible?
        visible_polyset?(@clips.last, TransformationMatrix.new)
      end

      def inline_image_visible?(operands)
        dictionary = operands[0]
        width = dictionary[:W] || dictionary[:Width]
        height = dictionary[:H] || dictionary[:Height]
        return true unless width && height
        local = Geom2D::PolygonSet.new([Geom2D::Polygon([0, 0], [1, 0], [1, 1], [0, 1])])
        visible_polyset?(local, graphics_state.ctm)
      end

      def show_text_operator(operator, operands)
        font = graphics_state.font
        reject('text without a font intersects a redaction rectangle') if font.nil?
        if graphics_state.soft_mask != :None
          reject('soft mask graphics state intersects a redaction rectangle')
        elsif font[:Subtype] == :Type3
          reject('Type3 font text intersects a redaction rectangle')
        elsif font.writing_mode == :vertical
          reject('vertical text intersects a redaction rectangle')
        elsif [4, 5, 6, 7].include?(graphics_state.text_rendering_mode.value)
          reject('text used as clipping glyph intersects a redaction rectangle')
        elsif font.bounding_box.nil?
          reject('text without font bounding box intersects a redaction rectangle')
        end

        data = operands.last
        text_matrix_for_line(operator)
        word_spacing, character_spacing = text_spacing_for(operator, operands)
        boxes = begin
                  build_glyph_boxes(data, graphics_state.tm.dup,
                                   word_spacing: word_spacing,
                                   character_spacing: character_spacing)
                rescue HexaPDF::Error
                  reject('text with undecodable character codes')
                end
        hidden = boxes.any? {|box| glyph_box_visible?(box) }
        if hidden
          invoke_text_state(operator, operands)
          graphics_state.tm = @post_text_matrix
          replacement = rewritten_text(operator, operands, data, boxes)
          @result << replacement
        else
          invoke_and_serialize(operator, operands)
        end
      end

      def glyph_box_visible?(box)
        points = box.points.each_slice(2).map {|point| Geom2D::Point(*point) }
        polygon = Geom2D::Polygon.new(points)
        visible_polyset?(Geom2D::PolygonSet.new([polygon]), TransformationMatrix.new)
      end

      def text_spacing_for(operator, operands)
        if operator == :'"'
          [operands[0], operands[1]]
        else
          [graphics_state.word_spacing, graphics_state.character_spacing]
        end
      end

      def invoke_text_state(operator, operands)
        if operator == :'"'
          invoke(:Tw, [operands[0]])
          invoke(:Tc, [operands[1]])
        end
      end

      def text_matrix_for_line(operator)
        if operator == :"'" || operator == :'"'
          graphics_state.tm.translate(0, -graphics_state.leading)
          graphics_state.tlm = graphics_state.tm.dup
        end
      end

      def text_matrix_operation
        matrix = graphics_state.tm
        "#{matrix.to_a.map {|value| format_number(value) }.join(' ')} Tm\n"
      end

      def build_glyph_boxes(data, matrix, word_spacing:, character_spacing:)
        boxes = []
        below = font_bounds[1] * graphics_state.scaled_font_size + graphics_state.text_rise
        above = font_bounds[3] * graphics_state.scaled_font_size + graphics_state.text_rise
        Array(data).each do |item|
          if item.kind_of?(Numeric)
            matrix.translate(-item * graphics_state.scaled_font_size, 0)
            next
          end
          graphics_state.font.decode(item).each do |code|
            width = glyph_width(code, word_spacing, character_spacing)
            ll = matrix.evaluate(0, below)
            lr = matrix.evaluate(width, below)
            ul = matrix.evaluate(0, above)
            ur = matrix.evaluate(width, above)
            boxes << Processor::GlyphBox.new(code, '', ll[0], ll[1], lr[0], lr[1], ul[0], ul[1])
            matrix.translate(width, 0)
          end
        end
        @post_text_matrix = matrix.dup
        boxes
      end

      def font_bounds
        @font_bounds ||= {}
        @font_bounds[graphics_state.font] ||= graphics_state.font.bounding_box
      end

      def glyph_width(code, word_spacing, character_spacing)
        font = graphics_state.font
        width = font.width(code) * graphics_state.scaled_font_size +
                graphics_state.scaled_character_spacing
        width += graphics_state.scaled_word_spacing if code == 32 && font.word_spacing_applicable?
        width
      end

      def rewritten_text(operator, operands, data, boxes)
        prefix = case operator
                 when :'"'
                   "#{format_number(operands[0])} Tw\n#{format_number(operands[1])} Tc\n"
                 else
                   ''.b
        end
        prefix << rewrite_text_data(data, boxes)
        prefix << text_matrix_operation
        prefix
      end

      def rewrite_text_data(data, boxes)
        output = []
        index = 0
        Array(data).each do |item|
          if item.kind_of?(Numeric)
            output << format_number(item)
            next
          end
          codes = graphics_state.font.decode(item)
          offset = 0
          codes.each do |code|
            break if index >= boxes.length
            box = boxes[index]
            length = code_byte_length(code, item, offset)
            encoded = item.byteslice(offset, length)
            offset += length
            if glyph_box_visible?(box)
              output << format_number(-glyph_width_in_text_units(code))
            else
              flush_pending_number(output)
              output << @serializer.serialize_string(encoded)
            end
            index += 1
          end
        end
        "[#{output.join(' ')}] TJ\n"
      end

      def flush_pending_number(output)
        output << '0' if output.last&.start_with?(/\A-?(\d|\.)/)
      end

      def code_byte_length(code, item, offset)
        return 1 unless graphics_state.font.is_a?(Type::FontType0)
        max = item.bytesize - offset
        [4, 3, 2, 1].find {|length| length <= max && item.byteslice(offset, length).bytes.inject(0) {|value, byte| (value << 8) | byte } == code } || 1
      end

      def glyph_width_in_text_units(code)
        font = graphics_state.font
        unit = graphics_state.font_size * font.glyph_scaling_factor
        return 0 if unit.zero? || graphics_state.scaled_horizontal_scaling.zero?
        glyph_width(code, graphics_state.word_spacing, graphics_state.character_spacing) /
          (unit * graphics_state.scaled_horizontal_scaling)
      end

      class ImageSanitizer

        SUPPORTED_COLOR_SPACES = {
          DeviceGray: 1, CalGray: 1, DeviceRGB: 3, CalRGB: 3, DeviceCMYK: 4,
        }.freeze

        def self.validate(image)
          new(image.document, image).validate_image
        end

        def initialize(document, image)
          @document = document
          @image = image
        end

        def redact(target)
          validate_image
          copy = @document.add(@image.value.dup)
          copy.stream = decoded_samples_for(@image)
          copy.stream = rewrite_samples(copy, target)
          copy.set_filter(:FlateDecode)
          copy.delete(:DecodeParms)
          if copy[:SMask]
            mask = @document.add(copy[:SMask].value.dup)
            mask.stream = decoded_samples_for(copy[:SMask])
            mask.stream = rewrite_samples(mask, target, opaque: true)
            mask.set_filter(:FlateDecode)
            mask.delete(:DecodeParms)
            copy[:SMask] = mask
          end
          copy
        end

      def validate_image(image = @image)
          filters = Array(image[:Filter])
          unless filters.empty? || filters == [:FlateDecode] ||
                 (filters - [:ASCIIHexDecode, :ASCII85Decode, :LZWDecode, :FlateDecode,
                             :RunLengthDecode]).empty?
            raise HexaPDF::Error, "Cannot perform content redaction: unsupported compressed image"
          end
          if image.key?(:Decode) || image.key?(:Mask)
            raise HexaPDF::Error, "Cannot perform content redaction: unsupported image decoding"
          end
          unless image.width.to_i.positive? && image.height.to_i.positive? &&
              [1, 2, 4, 8, 16].include?(image[:BitsPerComponent])
            raise HexaPDF::Error, "Cannot perform content redaction: unsupported image dimensions"
          end
          if image[:ImageMask] && (image.key?(:ColorSpace) || image[:BitsPerComponent] != 1)
            raise HexaPDF::Error, "Cannot perform content redaction: unsupported image mask"
          end
          components_for(image) unless image[:ImageMask]
          validate_image(@document.deref(image[:SMask])) if image[:SMask]
        end

        private

        def decoded_samples_for(image)
          raw = image.raw_stream
          if raw.kind_of?(StreamData)
            HexaPDF::Filter.string_from_source(image.stream_decoder)
          else
            source = HexaPDF::Filter.source_from_string(raw.to_s)
            filters = Array(image[:Filter])
            parameters = Array(image[:DecodeParms])
            filters.zip(parameters).reverse_each do |filter, parameter|
              source = image.send(:filter_for_name, filter).decoder(source, parameter) unless filter.nil?
            end
            HexaPDF::Filter.string_from_source(source)
          end
        end

        def rewrite_samples(image, target, opaque: false)
          width = image.width
          height = image.height
          bpc = image[:BitsPerComponent]
          sample_count = opaque || image[:ImageMask] ? 1 : components_for(image)
          row_length = (width * sample_count * bpc + 7) / 8
          source = image.stream
          if source.length < row_length * height
            raise HexaPDF::Error, "Cannot perform content redaction: decoded image has invalid size"
          end

          output = ''.b
          height.times do |row|
            output << rewrite_row(source.byteslice(row * row_length, row_length).b,
                                  row, width, sample_count, bpc, target, image, opaque)
          end
          output
        end

        def rewrite_row(row_data, row, width, sample_count, bpc, target, image, opaque)
          reader = HexaPDF::Utils::BitStreamReader.new(row_data)
          writer = HexaPDF::Utils::BitStreamWriter.new
          result = +''.b
          width.times do |column|
            redacted = pixel_redacted?(column, row, target)
            sample_count.times do |component|
              value = reader.read(bpc) || 0
              value = replacement_value(bpc, component, sample_count, opaque, image) if redacted
              result << writer.write(value, bpc)
            end
          end
          result << writer.finalize
          result.byteslice(0, row_data.length).ljust(row_data.length, "\0".b)
        end

        def replacement_value(bpc, component, sample_count, opaque, image)
          return (1 << bpc) - 1 if opaque || image[:ImageMask]
          sample_count == 4 && component == 3 ? (1 << bpc) - 1 : 0
        end

        def components_for(image)
          return 1 if image[:ImageMask]
          color_space = image[:ColorSpace]
          if color_space == :Indexed || (color_space.is_a?(Array) && color_space[0] == :Indexed)
            1
          elsif (count = SUPPORTED_COLOR_SPACES[color_space])
            count
          elsif color_space.is_a?(Array) && color_space[0] == :ICCBased
            count = @document.deref(color_space[1])[:N]
            unless [1, 3, 4].include?(count)
              raise HexaPDF::Error, "Cannot perform content redaction: unsupported ICC image"
            end
            count
          else
            raise HexaPDF::Error, "Cannot perform content redaction: unsupported image color space"
          end
        end

        def pixel_redacted?(column, row, target)
          x0 = column.to_f / @image.width
          x1 = (column + 1).to_f / @image.width
          y0 = 1.0 - (row + 1).to_f / @image.height
          y1 = 1.0 - row.to_f / @image.height
          pixel = Geom2D::PolygonSet.new([Geom2D::Polygon([x0, y0], [x1, y0], [x1, y1], [x0, y1])])
          Geom2D::Algorithms::PolygonOperation.run(pixel, target, :intersection).nr_of_contours.positive?
        rescue StandardError
          false
        end

      end
    end
  end
end
