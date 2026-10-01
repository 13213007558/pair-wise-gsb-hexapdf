# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/document'
require 'hexapdf/geospatial'

describe HexaPDF::Geospatial::AffineLocator do
  before do
    @doc = HexaPDF::Document.new
  end

  def viewport(lpts:, gpts:, bbox: [0, 0, 400, 400], bounds: nil, pdu: nil,
               geocs: {Type: :GeoCS, EPSG: 4326})
    measure = {Type: :Measure, Subtype: :GEO, LPTS: lpts, GPTS: gpts}
    measure[:GeoCS] = geocs if geocs
    measure[:Bounds] = bounds if bounds
    measure[:PDU] = pdu if pdu
    @doc.wrap({Type: :Viewport, BBox: bbox, Measure: measure}, type: :Viewport)
  end

  def locator(**kwargs)
    HexaPDF::Geospatial::AffineLocator.new(viewport(**kwargs))
  end

  it "accepts three non-collinear control points with an exact affine mapping" do
    loc = locator(lpts: [0, 0, 100, 0, 0, 100],
                  gpts: [0, 0, 10, 0, 0, 20])
    assert_equal(:ok, loc.status)
    assert(loc.valid?)
    assert_equal(3, loc.point_count)
    assert_equal(0.0, loc.rmse)
    assert_equal(0.0, loc.max_residual)
    assert_equal([0, 0, 0], loc.residuals.map {|r| r[3].round(8) })
  end

  it "fits two control points as a similarity transformation" do
    loc = locator(lpts: [0, 0, 400, 0], gpts: [0, 0, 40, 0])
    assert_equal(:ok, loc.status)
    assert_equal(2, loc.point_count)
  end

  it "supports rotation and uniform scaling in the two-point case and round-trips" do
    loc = locator(bbox: [0, 0, 100, 100],
                  lpts: [0, 0, 100, 0], gpts: [0, 0, 0, 10],
                  geocs: {Type: :GeoCS, EPSG: 32633})
    assert_equal(:ok, loc.status)
    assert_equal([0.0, 0.1, -0.1, 0.0, 0.0, 0.0], loc.coefficients.map {|v| v.round(8) })
    assert_equal([-5.0, 5.0], loc.page_to_geo(50, 50).point)
    point = loc.geo_to_page(-5, 5).point
    assert_in_delta(50, point[0], 1e-9)
    assert_in_delta(50, point[1], 1e-9)
    assert_equal(0.0, loc.rmse)
  end

  it "fits more than three control points with least squares and reports residuals" do
    loc = locator(lpts: [0, 0, 100, 0, 0, 100, 100, 100],
                  gpts: [0, 0, 10, 0, 0, 20, 10, 20.3])
    assert_equal(:ok, loc.status)
    assert_equal(4, loc.point_count)
    assert_in_delta(0.075, loc.rmse, 1e-9)
    assert_in_delta(0.075, loc.max_residual, 1e-9)
    assert_equal(4, loc.residuals.length)
    assert_equal([0, 1, 2, 3], loc.residuals.map(&:first))
  end

  it "reports :insufficient_points for fewer than two control pairs" do
    loc = locator(lpts: [0, 0], gpts: [0, 0])
    assert_equal(:insufficient_points, loc.status)
    refute(loc.valid?)
  end

  it "reports :collinear_points for collinear local control points" do
    loc = locator(lpts: [0, 0, 100, 100, 200, 200],
                  gpts: [0, 0, 10, 20, 20, 0])
    assert_equal(:collinear_points, loc.status)
  end

  it "reports :collinear_points when the two local control points coincide" do
    loc = locator(lpts: [5, 5, 5, 5], gpts: [0, 0, 10, 10])
    assert_equal(:collinear_points, loc.status)
  end

  it "reports :non_invertible for a degenerate mapping with three local points" do
    loc = locator(lpts: [0, 0, 100, 0, 0, 100],
                  gpts: [0, 0, 0, 0, 0, 0])
    assert_equal(:non_invertible, loc.status)
  end

  it "reports :non_invertible for a degenerate two-point mapping" do
    loc = locator(lpts: [0, 0, 100, 0], gpts: [5, 5, 5, 5])
    assert_equal(:non_invertible, loc.status)
  end

  it "reports :invalid_viewport for non-GEO measures and malformed data" do
    vp = @doc.wrap({Type: :Viewport, BBox: [0, 0, 1, 1],
                     Measure: {Type: :Measure, Subtype: :RL}}, type: :Viewport)
    assert_equal(:invalid_viewport, HexaPDF::Geospatial::AffineLocator.new(vp).status)

    vp = viewport(lpts: [0, 0, 100, 0], gpts: [0, 0],
                  geocs: nil)
    assert_equal(:invalid_viewport, HexaPDF::Geospatial::AffineLocator.new(vp).status)
  end

  describe "forward and reverse" do
    before do
      @loc = locator(bbox: [100, 200, 300, 400], pdu: 2,
                     lpts: [0, 0, 100, 0, 0, 100],
                     gpts: [0, 0, 0, 10, 10, 0])
    end

    it "transforms page points to geographic coordinates (BBox origin, PDU, lat/lon)" do
      assert_equal(:geographic, @loc.coordinate_system_kind)
      assert(@loc.geographic?)
      # GPTS is stored lat/lon, the result is exposed lon/lat
      result = @loc.page_to_geo(100, 200)
      assert(result.success?)
      assert_equal([0, 0], result.point.map(&:round))
      assert_equal([10.0, 0.0], @loc.page_to_geo(300, 200).point)
      assert_equal([0.0, 10.0], @loc.page_to_geo(100, 400).point)
      assert_equal([5.0, 5.0], @loc.page_to_geo(200, 300).point)
    end

    it "accepts the point as an array" do
      assert_equal([5.0, 5.0], @loc.page_to_geo([200, 300]).point)
    end

    it "transforms geographic coordinates back to page points" do
      result = @loc.geo_to_page(10, 0)
      assert(result.success?)
      assert_in_delta(300, result.point[0], 1e-9)
      assert_in_delta(200, result.point[1], 1e-9)
      result = @loc.geo_to_page(5, 5)
      assert_in_delta(200, result.point[0], 1e-9)
      assert_in_delta(300, result.point[1], 1e-9)
    end

    it "round-trips arbitrary points" do
      point = @loc.geo_to_page(*@loc.page_to_geo(123, 345).point).point
      assert_in_delta(123, point[0], 1e-9)
      assert_in_delta(345, point[1], 1e-9)
    end

    it "returns :out_of_bounds for points outside the BBox" do
      result = @loc.page_to_geo(50, 200)
      assert_equal(:out_of_bounds, result.status)
      assert_nil(result.point)
      refute(result.inside)
      refute(result.success?)
    end

    it "still returns the mapped point for out-of-bounds queries with clamp" do
      result = @loc.page_to_geo(50, 200, clamp: true)
      assert_equal(:out_of_bounds, result.status)
      refute(result.inside)
      assert_equal([-2.5, 0.0], result.point)
    end

    it "returns :out_of_bounds for reverse points outside the BBox" do
      result = @loc.geo_to_page(20, 0)
      assert_equal(:out_of_bounds, result.status)
      assert_nil(result.point)
      result = @loc.geo_to_page(20, 0, clamp: true)
      assert_equal(:out_of_bounds, result.status)
      assert_in_delta(500, result.point[0], 1e-9)
    end

    it "does not transform points for invalid locators" do
      loc = locator(lpts: [0, 0], gpts: [0, 0])
      assert_equal(:insufficient_points, loc.page_to_geo(0, 0).status)
      assert_nil(loc.page_to_geo(0, 0).point)
      assert_equal(:insufficient_points, loc.geo_to_page(0, 0).status)
    end
  end

  describe "bounds polygon" do
    before do
      # Non-rectangular valid region (diamond) inside the 400x400 BBox.
      @loc = locator(bounds: [0, 100, 100, 0, 200, 100, 100, 200],
                     lpts: [0, 100, 100, 0, 100, 200],
                     gpts: [0, 0, 10, 0, 0, 20])
    end

    it "uses the Bounds polygon as the valid region" do
      assert_equal([[0, 100], [100, 0], [200, 100], [100, 200]],
                   @loc.bounds.map {|v| v.map(&:round) })
      assert_equal(:ok, @loc.page_to_geo(100, 100).status)
      # Corner of the BBox lies outside the diamond.
      assert_equal(:out_of_bounds, @loc.page_to_geo(10, 10).status)
      assert_equal(:out_of_bounds, @loc.page_to_geo(350, 350).status)
    end

    it "treats points on the polygon boundary as inside" do
      assert(@loc.page_point_inside?(100, 200))
      assert_equal(:ok, @loc.page_to_geo(100, 200).status)
    end

    it "applies the polygon to reverse queries as well" do
      assert_equal(:ok, @loc.geo_to_page(5, 10).status)
      assert_equal(:out_of_bounds, @loc.geo_to_page(10, 20).status)
    end
  end

  describe "coordinate systems" do
    it "detects geographic systems from WKT" do
      vp = viewport(lpts: [0, 0, 1, 0, 0, 1], gpts: [0, 0, 0, 1, 1, 0],
                    geocs: {Type: :GeoCS, WKT: 'GEOGCS["WGS 84"]'})
      loc = HexaPDF::Geospatial::AffineLocator.new(vp)
      assert_equal(:geographic, loc.coordinate_system_kind)
      assert_equal([1, 0], loc.page_to_geo(1, 0).point)
    end

    it "detects projected systems from WKT" do
      vp = viewport(lpts: [0, 0, 1, 0, 0, 1],
                    gpts: [500_000, 5_000_000, 500_100, 5_000_000, 500_000, 5_000_100],
                    geocs: {Type: :GeoCS, WKT: 'PROJCS["UTM"]'})
      loc = HexaPDF::Geospatial::AffineLocator.new(vp)
      assert_equal(:projected, loc.coordinate_system_kind)
      refute(loc.geographic?)
      assert_equal([500_100, 5_000_000], loc.page_to_geo(1, 0).point)
      assert_in_delta(1, loc.geo_to_page(500_100, 5_000_100).point[0], 1e-9)
    end

    it "does not guess the coordinate system from values when identifiers are missing" do
      vp = viewport(lpts: [0, 0, 1, 0, 0, 1], gpts: [48, 2, 49, 2, 48, 3],
                    geocs: {Type: :GeoCS})
      loc = HexaPDF::Geospatial::AffineLocator.new(vp)
      assert_equal(:unknown, loc.coordinate_system_kind)
      # Stored order is preserved verbatim; lat/lon values are not assumed.
      assert_equal([49.0, 2.0], loc.page_to_geo(1, 0).point)
    end

    it "exposes the coordinate system dictionary" do
      loc = locator(lpts: [0, 0, 1, 0], gpts: [0, 0, 1, 0])
      assert_kind_of(HexaPDF::Type::Measure::GeoCS, loc.coordinate_system_dictionary)
      assert_equal(4326, loc.coordinate_system_dictionary[:EPSG])
    end
  end

  describe "bare measure" do
    it "uses the given origin and defaults to [0, 0]" do
      doc = HexaPDF::Document.new
      measure = doc.wrap({Type: :Measure, Subtype: :GEO,
                          GeoCS: {Type: :GeoCS, EPSG: 4326},
                          LPTS: [0, 0, 100, 0, 0, 100],
                          GPTS: [0, 0, 0, 10, 10, 0]}, type: :Measure)
      loc = HexaPDF::Geospatial::AffineLocator.new(measure, origin: [50, 60])
      assert_equal(:ok, loc.status)
      assert_equal([50, 60], loc.origin)
      assert_equal([0, 0], loc.page_to_geo(50, 60).point)
    end
  end
end
