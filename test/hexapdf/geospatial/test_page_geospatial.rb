# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/document'
require 'hexapdf/geospatial'

describe "Page geospatial integration" do
  before do
    @doc = HexaPDF::Document.new
    @page = @doc.pages.add
    @viewport = @doc.add({
      Type: :Viewport, BBox: [100, 200, 300, 400],
      Measure: {
        Type: :Measure, Subtype: :GEO,
        GeoCS: {Type: :GeoCS, EPSG: 4326},
        PDU: 2,
        LPTS: [0, 0, 100, 0, 0, 100],
        GPTS: [0, 0, 0, 10, 10, 0]
      }
    })
  end

  describe "viewports" do
    it "enumerates direct viewport dictionaries" do
      @page[:VP] = [@viewport]
      assert_equal([HexaPDF::Type::Viewport], @page.each_viewport.map(&:class))
      assert_same(@viewport, @page.viewport)
    end

    it "resolves viewports referenced through annotations" do
      annotation = @doc.add({Type: :Annot, Subtype: :Square, Rect: [0, 0, 10, 10],
                             VP: @viewport})
      @page[:VP] = [annotation]
      viewports = @page.each_viewport.to_a
      assert_equal(1, viewports.length)
      assert_kind_of(HexaPDF::Type::Viewport, viewports.first)
    end

    it "finds a viewport by name" do
      other = @doc.add({Type: :Viewport, Name: "inset", BBox: [0, 0, 1, 1],
                        Measure: {Type: :Measure, Subtype: :RL}})
      @page[:VP] = [@viewport, other]
      assert_equal("inset", @page.viewport("inset")[:Name])
      assert_nil(@page.viewport("unknown"))
    end

    it "ignores malformed entries" do
      @page[:VP] = [42, {Type: :Page}, @viewport]
      assert_equal(1, @page.each_viewport.count)
    end
  end

  describe "locators" do
    before { @page[:VP] = [@viewport] }

    it "returns locators for GEO viewports only" do
      other = @doc.add({Type: :Viewport, BBox: [0, 0, 1, 1],
                        Measure: {Type: :Measure, Subtype: :RL}})
      @page[:VP] << other
      locators = @page.geospatial_locators
      assert_equal(1, locators.length)
      assert_equal(:ok, locators.first.status)
    end

    it "provides the named locator" do
      assert_equal(:ok, @page.geospatial_locator.status)
      assert_nil(@page.geospatial_locator("unknown"))
    end

    it "handles BBox origin and PDU through the page API" do
      locator = @page.geospatial_locator
      assert_equal([0, 0], locator.page_to_geo(100, 200).point)
      assert_equal([10, 0], locator.page_to_geo(300, 200).point)
      assert_in_delta(300, locator.geo_to_page(10, 0).point[0], 1e-9)
      assert_in_delta(200, locator.geo_to_page(10, 0).point[1], 1e-9)
    end

    it "exposes the page UserUnit" do
      @page[:UserUnit] = 2.5
      locator = @page.geospatial_locator
      assert_in_delta(2.5, locator.user_unit, 1e-12)
      # Relative mapping is independent of UserUnit since both BBox and LPTS are in page units.
      assert_equal([10, 0], locator.page_to_geo(300, 200).point)
    end
  end

  describe "rotation helpers" do
    before do
      @box = [0, 0, 100, 200]
    end

    it "converts display coordinates for 0 degree rotation" do
      page = HexaPDF::Geospatial.display_to_page_point(10, 20, 0, @box)
      assert_equal([10, 180], page)
      assert_equal([10, 20], HexaPDF::Geospatial.page_to_display_point(*page, 0, @box))
    end

    it "converts display coordinates for 90 degree rotation" do
      page = HexaPDF::Geospatial.display_to_page_point(10, 20, 90, @box)
      assert_equal([80, 10], page)
      assert_equal([10, 20], HexaPDF::Geospatial.page_to_display_point(*page, 90, @box))
    end

    it "converts display coordinates for 180 degree rotation" do
      page = HexaPDF::Geospatial.display_to_page_point(10, 20, 180, @box)
      assert_equal([90, 20], page)
      assert_equal([10, 20], HexaPDF::Geospatial.page_to_display_point(*page, 180, @box))
    end

    it "converts display coordinates for 270 degree rotation" do
      page = HexaPDF::Geospatial.display_to_page_point(10, 20, 270, @box)
      assert_equal([20, 190], page)
      assert_equal([10, 20], HexaPDF::Geospatial.page_to_display_point(*page, 270, @box))
    end

    it "works end-to-end with a rotated page" do
      @page[:VP] = [@viewport]
      @page[:Rotate] = 90
      box = @page.box
      locator = @page.geospatial_locator
      # Display point mapping to the page point (100, 200) = geographic (0, 0).
      page_point = HexaPDF::Geospatial.display_to_page_point(200, 495.275591, 90, box)
      assert_in_delta(100, page_point[0], 1e-6)
      assert_in_delta(200, page_point[1], 1e-6)
      geo = locator.page_to_geo(*page_point).point
      assert_in_delta(0, geo[0], 1e-9)
      assert_in_delta(0, geo[1], 1e-9)
    end

    it "raises for invalid rotations" do
      assert_raises(ArgumentError) do
        HexaPDF::Geospatial.display_to_page_point(0, 0, 45, @box)
      end
    end
  end
end
