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

require 'hexapdf/error'
require 'hexapdf/document'
require 'hexapdf/content/transformation_matrix'

module HexaPDF
  module Imposition

    # Imposes the pages of a source document (which has to be in reading order) onto sheets
    # for saddle-stitched booklet printing.
    #
    # The source document's pages are grouped into signatures of #pages_per_signature pages
    # each. Each signature consists of +pages_per_signature / 4+ sheets and each sheet carries
    # two pages on its front and two on its back, arranged so that folding and stacking the
    # printed sheets yields the original reading order. If the page count of the source
    # document is not a multiple of the signature size, the last signature is padded with
    # blank pages.
    #
    # The imposed result is written to a *new* HexaPDF::Document; the source document is only
    # read and never modified.
    #
    # Each source page is placed into a left or right slot of a sheet with its trim size
    # centered in the slot (no scaling is applied). Source pages may differ in size and
    # rotation; the /Rotate value of a page is taken into account so that the page appears
    # upright on the sheet. Bleed is preserved: the page content is imported using its bleed
    # box and the imposed sheets get separate /TrimBox and /BleedBox entries computed from
    # the placed pages, keeping the distinction between the trim and bleed areas.
    #
    # Annotations and outline items (bookmarks) are carried over to the imposed document:
    #
    # * Link annotations are re-created on the correct sheet page with their rectangle (and
    #   quad points) transformed into sheet coordinates. Internal destinations (direct or via
    #   GoTo actions) are remapped so that they still point to the correct content; other
    #   actions (e.g. URI actions) are copied unchanged.
    # * Printable annotations of other types are flattened, i.e. their appearance streams are
    #   drawn into the sheet's content stream at the correct position.
    # * The document outline is copied with all destinations remapped in the same way.
    #
    # Documents containing interactive forms (AcroForm fields) are rejected because form
    # fields cannot be reproduced on the imposed sheets.
    #
    # Example:
    #
    #   source = HexaPDF::Document.open("book.pdf")
    #   imposed = HexaPDF::Imposition::SaddleStitch.impose(source, pages_per_signature: 16,
    #                                                      paper_size: :A3, binding: :left,
    #                                                      duplex: :short_edge, creep: 0.5)
    #   imposed.write("book-imposed.pdf")
    class SaddleStitch

      # Exact clockwise rotation matrices for multiples of 90 degrees as [a, b, c, d, e, f]
      # arrays. Using integers avoids floating point noise in the computed coordinates.
      ROTATION_MATRICES = {
        0 => [1, 0, 0, 1, 0, 0].freeze,
        90 => [0, -1, 1, 0, 0, 0].freeze,
        180 => [-1, 0, 0, -1, 0, 0].freeze,
        270 => [0, 1, -1, 0, 0, 0].freeze,
      }.freeze

      # The source document in reading order.
      attr_reader :source

      # The number of pages per signature (a positive multiple of 4).
      attr_reader :pages_per_signature

      # The paper size given to the constructor.
      attr_reader :paper_size

      # The binding side, :left or :right.
      attr_reader :binding

      # The duplex flipping mode, :long_edge or :short_edge.
      attr_reader :duplex

      # The creep (shingling) amount per sheet layer, in PDF points.
      attr_reader :creep

      # The width of an imposed sheet.
      attr_reader :sheet_width

      # The height of an imposed sheet.
      attr_reader :sheet_height

      # Imposes the given +source+ document and returns the imposed document. See #initialize
      # for the available options.
      def self.impose(source, **options)
        new(source, **options).impose
      end

      # Creates a new saddle-stitch imposer for the +source+ document (a
      # HexaPDF::Document in reading order).
      #
      # The following options are available:
      #
      # pages_per_signature:: The number of reading-order pages per signature. Has to be a
      #                       positive multiple of 4. Default: 4.
      #
      # paper_size::          The size of the imposed sheets, either a symbol naming a
      #                       predefined size (see HexaPDF::Type::Page::PAPER_SIZE), a
      #                       [width, height] array or a four-element box. Each sheet holds
      #                       two pages side by side, so it is usually landscape. Default: :A4.
      #
      # binding::             The binding side: :left for left-to-right documents (odd pages
      #                       on the right half of a sheet's front) or :right for
      #                       right-to-left documents. Default: :left.
      #
      # duplex::              How the printer flips the sheets for duplex printing:
      #                       :long_edge or :short_edge. If the flipping axis is the
      #                       horizontal axis of the sheet (i.e. :long_edge for landscape
      #                       sheets or :short_edge for portrait sheets), the back sides are
      #                       rotated 180 degrees so that they come out upright. Default:
      #                       :long_edge.
      #
      # creep::               The creep (shingling) compensation per sheet layer, in PDF
      #                       points. The content of sheet +i+ of a signature (counted from
      #                       the outermost sheet) is shifted +creep * i+ points away from the
      #                       spine. Default: 0.
      #
      # Raises an HexaPDF::Error if the source document has no pages or contains an
      # interactive form.
      def initialize(source, pages_per_signature: 4, paper_size: :A4, binding: :left,
                     duplex: :long_edge, creep: 0)
        @source = source
        @pages_per_signature = pages_per_signature
        @paper_size = paper_size
        @binding = binding
        @duplex = duplex
        @creep = creep
        validate_options!
        @sheet_width, @sheet_height = normalize_paper_size(paper_size)
        @page_count = source.pages.count
        if @page_count == 0
          raise HexaPDF::Error, "Cannot impose a document without pages"
        end
        acro_form = resolve_reference(source.catalog.value[:AcroForm])
        fields = acro_form && resolve_reference(acro_form[:Fields])
        if fields && !fields.empty?
          raise HexaPDF::Error,
                "Saddle-stitch imposition does not support documents with interactive forms"
        end
        @page_indices = {}
        source.pages.each_with_index {|page, index| @page_indices[page.data.object_id] = index }
        @layout = compute_layout
      end

      # Imposes the source document and returns the imposed document (a new
      # HexaPDF::Document).
      #
      # The imposed pages are ordered by signature, then by sheet (outermost sheet first) and
      # finally by side (front before back), i.e. in the order in which the sheets have to be
      # printed.
      def impose
        target = HexaPDF::Document.new
        page_map = {}
        @layout.each do |sheet|
          page = target.pages.add([0, 0, @sheet_width, @sheet_height])
          page.box(:trim, sheet[:trim_box]) if sheet[:trim_box]
          page.box(:bleed, sheet[:bleed_box]) if sheet[:bleed_box]
          canvas = page.canvas
          sheet[:slots].each_value do |slot|
            next unless slot[:source]
            source_page = @source.pages[slot[:source]]
            form = import_form_xobject(target, source_page)
            bbox = form[:BBox]
            canvas.transform(*slot[:matrix]) { canvas.xobject(form, at: [bbox[0], bbox[1]]) }
            page_map[slot[:source]] = {page: page, matrix: slot[:matrix]}
            flatten_printable_annotations(target, canvas, source_page, slot[:matrix])
          end
        end
        copy_link_annotations(target, page_map)
        copy_outline(target, page_map)
        target
      end

      # Returns the computed layout of the imposed sheets as an array of hashes, in output
      # order. Each sheet hash has the following keys:
      #
      # :signature:: The zero-based index of the signature the sheet belongs to.
      # :sheet::     The zero-based index of the sheet within the signature (0 is the
      #              outermost sheet).
      # :side::      Either :front or :back.
      # :slots::     A hash with the keys :left and :right, one for each half of the sheet.
      #              Each slot hash contains :source (the zero-based index of the source
      #              page or +nil+ for a blank page), :matrix (the transformation matrix
      #              [a, b, c, d, e, f] mapping source page coordinates to sheet
      #              coordinates) as well as :trim and :bleed (the placed trim and bleed
      #              rectangles in sheet coordinates, each [llx, lly, urx, ury]).
      # :trim_box::  The trim box of the whole sheet (the union of the placed trim
      #              rectangles) or +nil+ if the sheet is completely blank.
      # :bleed_box:: The bleed box of the whole sheet or +nil+ if the sheet is completely
      #              blank.
      attr_reader :layout

      private

      # Validates the constructor options.
      def validate_options!
        unless @pages_per_signature.kind_of?(Integer) && @pages_per_signature > 0 &&
            @pages_per_signature % 4 == 0
          raise ArgumentError, "pages_per_signature must be a positive multiple of 4"
        end
        unless [:left, :right].include?(@binding)
          raise ArgumentError, "binding must be :left or :right"
        end
        unless [:long_edge, :short_edge].include?(@duplex)
          raise ArgumentError, "duplex must be :long_edge or :short_edge"
        end
        unless @creep.kind_of?(Numeric) && @creep >= 0
          raise ArgumentError, "creep must be a non-negative number"
        end
      end

      # Returns [width, height] for the given paper size specification.
      def normalize_paper_size(paper_size)
        box = case paper_size
              when Symbol
                begin
                  HexaPDF::Type::Page.media_box(paper_size)
                rescue HexaPDF::Error
                  nil
                end
              when Array
                if paper_size.size == 2 && paper_size.all?(Numeric)
                  [0, 0, *paper_size]
                elsif paper_size.size == 4 && paper_size.all?(Numeric)
                  paper_size
                end
              end
        unless box
          raise ArgumentError, "paper_size must be a known paper size symbol, a " \
                               "[width, height] array or a [llx, lly, urx, ury] box"
        end
        [box[2] - box[0], box[3] - box[1]]
      end

      # Computes the layout of all imposed sheets.
      def compute_layout
        sheets_per_signature = @pages_per_signature / 4
        signature_count = (@page_count + @pages_per_signature - 1) / @pages_per_signature
        rotate_back = rotate_back_side?
        layout = []
        signature_count.times do |signature|
          base = signature * @pages_per_signature
          sheets_per_signature.times do |sheet|
            creep_offset = @creep * sheet
            [:front, :back].each do |side|
              local_left, local_right = sheet_page_indices(sheet, side)
              rotate = (side == :back && rotate_back)
              slots = {
                left: place_slot(:left, page_index(base, local_left), creep_offset, rotate),
                right: place_slot(:right, page_index(base, local_right), creep_offset, rotate),
              }
              layout << {
                signature: signature, sheet: sheet, side: side, slots: slots,
                trim_box: clip_rect(union_rects(slots[:left][:trim], slots[:right][:trim])),
                bleed_box: clip_rect(union_rects(slots[:left][:bleed], slots[:right][:bleed])),
              }
            end
          end
        end
        layout
      end

      # Returns the global source page index for the signature-local index +local+ of the
      # signature starting at +base+, or +nil+ if the index refers to a padding (blank)
      # page.
      def page_index(base, local)
        index = base + local
        index < @page_count ? index : nil
      end

      # Returns the signature-local page indices [left, right] for the given sheet (counted
      # from the outermost sheet) and side of a signature.
      def sheet_page_indices(sheet, side)
        n = @pages_per_signature
        if side == :front
          left = n - 1 - 2 * sheet
          right = 2 * sheet
        else
          left = 2 * sheet + 1
          right = n - 2 - 2 * sheet
        end
        @binding == :left ? [left, right] : [right, left]
      end

      # Returns +true+ if the back sides of the sheets have to be rotated 180 degrees, i.e.
      # if the duplex flipping axis is the horizontal axis of the sheet.
      def rotate_back_side?
        landscape = @sheet_width >= @sheet_height
        (@duplex == :long_edge) == landscape
      end

      # Computes the placement of the source page with the given index (or of a blank page
      # if +nil+) in the +slot_side+ half of a sheet.
      #
      # The page's trim box is centered in the slot and shifted +creep_offset+ points away
      # from the spine. If +rotate+ is +true+, the whole placement is additionally rotated
      # 180 degrees around the center of the sheet (for the back side of sheets when the
      # duplex flipping axis is horizontal).
      def place_slot(slot_side, source_index, creep_offset, rotate)
        return {source: nil, matrix: nil, trim: nil, bleed: nil} unless source_index

        page = @source.pages[source_index]
        crop = read_page_box(page, :crop)
        rotation = page[:Rotate] % 360
        unless ROTATION_MATRICES.key?(rotation)
          raise HexaPDF::Error,
                "Page #{source_index + 1} has an invalid rotation of #{page[:Rotate]} degrees"
        end
        crop_width = crop[2] - crop[0]
        crop_height = crop[3] - crop[1]
        displayed_width = (rotation == 90 || rotation == 270) ? crop_height : crop_width
        displayed_height = (rotation == 90 || rotation == 270) ? crop_width : crop_height

        slot_width = @sheet_width / 2.0
        origin_x = (slot_side == :left ? 0 : slot_width) + (slot_width - displayed_width) / 2
        origin_y = (@sheet_height - displayed_height) / 2
        origin_x += (slot_side == :left ? -creep_offset : creep_offset)

        rotation_matrix = ROTATION_MATRICES[rotation]
        rm = Content::TransformationMatrix.new(*rotation_matrix)
        corners = rect_corners(*crop)
        corners = corners.map {|x, y| rm.evaluate(x, y) }
        min_x = corners.map(&:first).min
        min_y = corners.map(&:last).min

        matrix = if rotate
                   Content::TransformationMatrix.new(-1, 0, 0, -1, @sheet_width, @sheet_height)
                 else
                   Content::TransformationMatrix.new
                 end
        matrix.translate(origin_x, origin_y)
        matrix.translate(-min_x, -min_y)
        matrix.premultiply(*rotation_matrix)

        bleed = read_page_box(page, :bleed)
        {
          source: source_index,
          matrix: matrix.to_a,
          trim: transform_rect(matrix, crop),
          bleed: transform_rect(matrix, bleed),
        }
      end

      # Returns the crop or bleed box of the page as a four-element array, taking the fallback
      # values and the clipping to the media box into account (like HexaPDF::Type::Page#box
      # does but without modifying the page).
      def read_page_box(page, type)
        media_box = page[:MediaBox].to_a
        box = case type
              when :crop then page[:CropBox] || page[:MediaBox]
              when :bleed then page[:BleedBox] || page[:CropBox] || page[:MediaBox]
              end
        box = box.to_a
        return box if box == media_box
        if box[2] < media_box[0] || box[0] > media_box[2] ||
            box[3] < media_box[1] || box[1] > media_box[3]
          [0, 0, 0, 0]
        else
          [[box[0], media_box[0]].max, [box[1], media_box[1]].max,
           [box[2], media_box[2]].min, [box[3], media_box[3]].min]
        end
      end

      # Returns the four corners of the given rectangle.
      def rect_corners(left, bottom, right, top)
        [[left, bottom], [left, top], [right, bottom], [right, top]]
      end

      # Transforms the rectangle [llx, lly, urx, ury] with the given matrix and returns the
      # bounding box of the transformed corners.
      def transform_rect(matrix, rect)
        corners = rect_corners(*rect).map {|x, y| matrix.evaluate(x, y) }
        [corners.map(&:first).min, corners.map(&:last).min,
         corners.map(&:first).max, corners.map(&:last).max]
      end

      # Returns the union of the given rectangles (or +nil+ if all are +nil+).
      def union_rects(*rects)
        rects = rects.compact
        return nil if rects.empty?
        [rects.map {|r| r[0] }.min, rects.map {|r| r[1] }.min,
         rects.map {|r| r[2] }.max, rects.map {|r| r[3] }.max]
      end

      # Returns the raw value of the given entry of a source dictionary (a hash or a
      # HexaPDF::Dictionary), resolving references and unwrapping dictionaries. This allows
      # inspecting and importing the value without modifying the source document (wrapping a
      # dictionary or accessing its fields may fill in default values).
      def raw_entry(dict, key)
        value = (dict.kind_of?(HexaPDF::Dictionary) ? dict.value : dict)[key]
        value = resolve_reference(value)
        value.kind_of?(HexaPDF::Dictionary) ? value.value : value
      end

      # Resolves the given value if it is a reference.
      def resolve_reference(value)
        value.kind_of?(HexaPDF::Reference) ? @source.deref(value) : value
      end

      # Clips the rectangle to the sheet's media box. Returns +nil+ if +rect+ is +nil+.
      def clip_rect(rect)
        return nil unless rect
        [[rect[0], 0].max, [rect[1], 0].max,
         [rect[2], @sheet_width].min, [rect[3], @sheet_height].min]
      end

      # Imports the content of the source page into the target document as a Form XObject
      # and returns it. The bleed box of the page is used as the form's bounding box so
      # that bleed content is preserved.
      def import_form_xobject(target, source_page)
        dict = {
          Type: :XObject,
          Subtype: :Form,
          BBox: read_page_box(source_page, :bleed),
          Resources: source_page[:Resources] || {},
        }
        target.add(target.import(dict), stream: source_page.contents)
      end

      # Draws the appearances of all printable, non-link annotations of the source page
      # onto the sheet's canvas, transformed by the given placement matrix.
      def flatten_printable_annotations(target, canvas, source_page, matrix)
        source_page.each_annotation do |annotation|
          next if annotation[:Subtype] == :Link || !printable?(annotation)
          appearance = annotation.appearance
          next unless appearance
          bbox = appearance[:BBox]
          next if bbox[2] - bbox[0] == 0 || bbox[3] - bbox[1] == 0

          rect = annotation[:Rect]
          form = target.import(appearance)
          canvas.transform(*matrix) do
            canvas.xobject(form, at: [rect[0], rect[1]], width: rect[2] - rect[0],
                                 height: rect[3] - rect[1])
          end
        end
      end

      # Returns +true+ if the annotation should appear when the page is printed.
      def printable?(annotation)
        annotation.flagged?(:print) && !annotation.flagged?(:hidden) &&
          !annotation.flagged?(:invisible) && !annotation.flagged?(:no_view)
      end

      # Re-creates the link annotations of all source pages on the respective imposed
      # pages, with transformed rectangles and remapped destinations.
      def copy_link_annotations(target, page_map)
        @source.pages.each_with_index do |source_page, index|
          placement = page_map[index]
          next unless placement
          source_page.each_annotation do |annotation|
            next unless annotation[:Subtype] == :Link
            next if annotation.flagged?(:hidden) || annotation.flagged?(:invisible)
            dict = build_link_annotation(target, annotation, placement[:matrix], page_map)
            next unless dict
            link = target.add(dict)
            page = placement[:page]
            page[:Annots] = (page[:Annots] ? page[:Annots].to_a : []) + [link]
          end
        end
      end

      # Builds the dictionary for the imposed counterpart of the given link annotation.
      # Returns +nil+ if the link has neither a destination nor an action or if its
      # destination cannot be remapped.
      def build_link_annotation(target, annotation, matrix, page_map)
        m = Content::TransformationMatrix.new(*matrix)
        dict = {Type: :Annot, Subtype: :Link, Rect: transform_rect(m, annotation[:Rect].to_a)}
        dict[:F] = annotation[:F] if annotation[:F] != 0
        dict[:Contents] = annotation[:Contents] if annotation.key?(:Contents)
        dict[:Border] = annotation[:Border].to_a if annotation.key?(:Border)
        if annotation.key?(:BS)
          dict[:BS] = HexaPDF::Importer.for(target).import(raw_entry(annotation, :BS),
                                                           source: @source)
        end
        dict[:H] = annotation[:H] if annotation.key?(:H)
        dict[:C] = annotation[:C].to_a if annotation.key?(:C)
        if annotation.key?(:QuadPoints)
          quad_points = []
          annotation[:QuadPoints].each_slice(2) {|x, y| quad_points.concat(m.evaluate(x, y)) }
          dict[:QuadPoints] = quad_points
        end
        if annotation.key?(:Dest)
          destination = remap_destination(target, annotation[:Dest], page_map)
          return nil unless destination
          dict[:Dest] = destination
        elsif annotation.key?(:A)
          action = raw_entry(annotation, :A)
          if action[:S] == :GoTo
            destination = remap_destination(target, resolve_reference(action[:D]), page_map)
            return nil unless destination
            dict[:A] = {S: :GoTo, D: destination}
          else
            dict[:A] = HexaPDF::Importer.for(target).import(action, source: @source)
          end
        else
          return nil
        end
        dict
      end

      # Remaps the given destination (an explicit destination array, a named destination or
      # a GoTo action's /D entry) of the source document to a destination array for the
      # imposed document.
      #
      # Returns +nil+ if the destination cannot be resolved or references a page that is not
      # part of the imposed document.
      def remap_destination(target, value, page_map)
        resolved = @source.destinations.resolve(value)
        return nil unless resolved && !resolved.remote?
        source_page = @source.deref(resolved.page)
        index = source_page && @page_indices[source_page.data.object_id]
        placement = index && page_map[index]
        return nil unless placement

        m = Content::TransformationMatrix.new(*placement[:matrix])
        target_page = placement[:page]
        swapped = m.b != 0 || m.c != 0
        case resolved.type
        when :xyz
          left, top = transform_optional_point(m, resolved.left, resolved.top, swapped)
          [target_page, :XYZ, left, top, resolved.zoom]
        when :fit_page
          [target_page, :Fit]
        when :fit_bounding_box
          [target_page, :FitB]
        when :fit_rectangle
          rect = transform_rect(m, [resolved.left, resolved.bottom, resolved.right,
                                    resolved.top])
          [target_page, :FitR, *rect]
        when :fit_page_horizontal, :fit_bounding_box_horizontal
          type = (resolved.type == :fit_page_horizontal ? :FitH : :FitBH)
          top = resolved.top
          if swapped
            [target_page, (type == :FitH ? :FitV : :FitBV), top && m.evaluate(0, top)[0]]
          else
            [target_page, type, top && m.evaluate(0, top)[1]]
          end
        when :fit_page_vertical, :fit_bounding_box_vertical
          type = (resolved.type == :fit_page_vertical ? :FitV : :FitBV)
          left = resolved.left
          if swapped
            [target_page, (type == :FitV ? :FitH : :FitBH), left && m.evaluate(left, 0)[1]]
          else
            [target_page, type, left && m.evaluate(left, 0)[0]]
          end
        end
      end

      # Transforms the point (x, y) with the given matrix, where either coordinate may be
      # +nil+ (meaning "unchanged" in a destination). For matrices that swap the coordinate
      # axes (i.e. 90/270 degree rotations) the roles of the coordinates are exchanged.
      def transform_optional_point(m, x, y, swapped)
        if swapped
          [y && m.evaluate(0, y)[0], x && m.evaluate(x, 0)[1]]
        else
          [x && m.evaluate(x, 0)[0], y && m.evaluate(0, y)[1]]
        end
      end

      # Copies the document outline of the source document to the imposed document,
      # remapping all destinations. Items whose destination cannot be remapped are kept
      # without a destination.
      def copy_outline(target, page_map)
        outline = @source.catalog[:Outlines]
        return unless outline && outline[:First]
        copy_outline_items(target, outline[:First], target.outline, page_map)
      end

      # Recursively copies the outline item chain starting at +item+ into +parent+ of the
      # imposed document.
      def copy_outline_items(target, item, parent, page_map)
        while item
          item = @source.deref(item)
          options = {open: item.open? ? true : false}
          if item[:Dest]
            destination = remap_destination(target, item[:Dest], page_map)
            options[:destination] = destination if destination
          elsif item.value[:A]
            action = raw_entry(item, :A)
            if action[:S] == :GoTo &&
                (destination = remap_destination(target, resolve_reference(action[:D]), page_map))
              options[:destination] = destination
            else
              options[:action] = HexaPDF::Importer.for(target).import(action, source: @source)
            end
          end
          options[:text_color] = item[:C].to_a if item.key?(:C)
          options[:flags] = item.flags unless item.flags.empty?
          new_item = parent.add_item(item.title, **options)
          copy_outline_items(target, item[:First], new_item, page_map) if item[:First]
          item = item[:Next]
        end
      end

    end

  end
end
