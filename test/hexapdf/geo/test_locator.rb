# -*- encoding: utf-8 -*-

require 'test_helper'
require 'stringio'
require 'hexapdf/document'
require 'hexapdf/geo/locator'

describe HexaPDF::Geo::Locator do
  before do
    @doc = HexaPDF::Document.new
  end

  def viewport(measure, bbox: [0, 0, 100, 100])
    measure = {Subtype: :GEO}.merge(measure)
    @doc.wrap({BBox: bbox, Measure: measure}, type: HexaPDF::Type::Viewport)
  end

  def locator(page: nil, bbox: [0, 0, 100, 100], **measure)
    HexaPDF::Geo::Locator.new(viewport(measure, bbox: bbox), page: page)
  end

  def assert_close(expected, actual, delta = 1e-9)
    expected.each_with_index do |value, index|
      assert_in_delta(value, actual[index], delta)
    end
  end

  describe "status handling" do
    it "reports :no_measure when there is no GEO measure dictionary" do
      vp = @doc.wrap({BBox: [0, 0, 1, 1]}, type: HexaPDF::Type::Viewport)
      assert_equal(:no_measure, HexaPDF::Geo::Locator.new(vp).status)
      assert_equal(:no_measure, HexaPDF::Geo::Locator.new(nil).status)
    end

    it "reports :missing_points for missing or malformed point arrays" do
      assert_equal(:missing_points, locator(GPTS: [0, 0, 1, 1]).status)
      assert_equal(:missing_points, locator(LPTS: [0, 0, 1, 1]).status)
      assert_equal(:missing_points,
                   locator(LPTS: [0, 0, 1], GPTS: [0, 0, 1]).status)
      assert_equal(:missing_points,
                   locator(LPTS: [0, 0], GPTS: [0, 0]).status)
      assert_equal(:missing_points,
                   locator(LPTS: Array.new(22, 0), GPTS: Array.new(22, 0)).status)
    end

    it "reports :mismatched_points for differing point counts" do
      assert_equal(:mismatched_points,
                   locator(LPTS: [0, 0, 1, 0, 0, 1], GPTS: [0, 0, 1, 1]).status)
    end

    it "reports :collinear_points for collinear control points" do
      assert_equal(:collinear_points,
                   locator(LPTS: [0, 0, 50, 50, 100, 100],
                           GPTS: [0, 0, 1, 1, 2, 2]).status)
      assert_equal(:collinear_points,
                   locator(LPTS: [0, 0, 0, 0], GPTS: [0, 0, 1, 1]).status)
    end

    it "reports :singular_mapping when the geographic mapping is not invertible" do
      assert_equal(:singular_mapping,
                   locator(LPTS: [0, 0, 100, 0, 0, 100],
                           GPTS: [0, 0, 100, 100, 200, 200]).status)
      assert_equal(:singular_mapping,
                   locator(LPTS: [0, 0, 100, 0], GPTS: [5, 5, 5, 5]).status)
    end

    it "reports :invalid_bounds for malformed BBox or Bounds" do
      vp = viewport({LPTS: [0, 0, 1, 1], GPTS: [0, 0, 1, 1]}, bbox: [0, 0, 1])
      assert_equal(:invalid_bounds, HexaPDF::Geo::Locator.new(vp).status)

      assert_equal(:invalid_bounds, locator(LPTS: [0, 0, 1, 1], GPTS: [0, 0, 1, 1],
                                           bbox: nil).status)

      vp = viewport({LPTS: [0, 0, 1, 1], GPTS: [0, 0, 1, 1], Bounds: [1, 2, 3]})
      assert_equal(:invalid_bounds, HexaPDF::Geo::Locator.new(vp).status)
    end

    it "raises an error when transforming with an invalid locator" do
      loc = locator(GPTS: [0, 0, 1, 1])
      error = assert_raises(HexaPDF::Error) { loc.forward(0, 0) }
      assert_match(/missing_points/, error.message)
      assert_raises(HexaPDF::Error) { loc.inverse(0, 0) }
    end
  end

  describe "exact affine mapping" do
    before do
      @loc = locator(LPTS: [0, 0, 100, 0, 0, 100],
                     GPTS: [10, 50, 12, 50, 10, 52])
    end

    it "is valid and exposes the control points and coordinate systems" do
      assert(@loc.valid?)
      assert_equal(3, @loc.control_points.length)
      assert_equal(:GCS_WGS84, @loc.coordinate_system)
      assert_equal(:GCS_WGS84, @loc.geographic_coordinate_system)
    end

    it "maps page points forward" do
      result = @loc.forward(50, 50)
      assert_equal(:ok, result.status)
      assert(result.inside?)
      assert_close([11, 51], result.geo_point)
    end

    it "maps geographic coordinates back to page points" do
      result = @loc.inverse(11, 51)
      assert_equal(:ok, result.status)
      assert_close([50, 50], result.page_point)
    end

    it "maps the control points exactly" do
      @loc.control_points.each do |(linear, geographic)|
        assert_close(geographic, @loc.forward(*linear, display: false).geo_point)
        assert_close(linear, @loc.inverse(*geographic).page_point)
      end
    end

    it "reports zero residuals for an exact fit" do
      assert_equal(0.0, @loc.rmse)
      assert_equal(0.0, @loc.max_residual)
      assert_equal([[0, 0], [0, 0], [0, 0]], @loc.residuals)
    end

    it "reports :outside_bounds for points outside of the BBox" do
      result = @loc.forward(150, 150)
      assert_equal(:outside_bounds, result.status)
      refute(result.inside?)
      assert_close([13, 53], result.geo_point)

      result = @loc.inverse(13, 53)
      assert_equal(:outside_bounds, result.status)
      assert_close([150, 150], result.page_point)
    end

    it "treats boundary points as inside" do
      assert_equal(:ok, @loc.forward(0, 0).status)
      assert_equal(:ok, @loc.forward(100, 100).status)
    end
  end

  describe "two-point similarity mapping" do
    before do
      @loc = locator(LPTS: [0, 0, 100, 0], GPTS: [10, 20, 10, 120])
    end

    it "fits rotation, uniform scaling and translation" do
      assert(@loc.valid?)
      assert_close([0, 1, -1, 0, 10, 20], @loc.affine_matrix)
      assert_close([-40, 20], @loc.forward(0, 50).geo_point)
      assert_close([50, -40], @loc.inverse(50, 70).page_point)
    end

    it "reports zero residuals for the two control points" do
      assert_equal([[0, 0], [0, 0]], @loc.residuals)
      assert_equal(0.0, @loc.rmse)
      assert_equal(0.0, @loc.max_residual)
    end
  end

  describe "least-squares fitting" do
    it "fits more than three control points and reports residuals" do
      loc = locator(LPTS: [0, 0, 100, 0, 0, 100, 100, 100],
                    GPTS: [0, 0, 100, 0.2, 0, 100, 100.1, 100])
      assert(loc.valid?)
      assert_equal(4, loc.residuals.length)
      assert_in_delta(0.0559016994, loc.rmse, 1e-9)
      assert_in_delta(0.0559016994, loc.max_residual, 1e-9)
      assert_in_delta(50.025, loc.forward(50, 50).geo_point[0], 1e-9)
      assert_in_delta(50.05, loc.forward(50, 50).geo_point[1], 1e-9)
    end
  end

  describe "non-rectangular valid bounds" do
    before do
      bounds = [0, 0, 100, 0, 80, 80, 0, 100]
      measure = {Subtype: :GEO, LPTS: [0, 0, 1, 0, 0, 1],
                 GPTS: [0, 0, 1, 0, 0, 1], Bounds: bounds}
      @vp = @doc.wrap({BBox: [0, 0, 100, 100], Measure: measure},
                      type: HexaPDF::Type::Viewport)
      @loc = HexaPDF::Geo::Locator.new(@vp)
    end

    it "uses the Bounds polygon instead of the BBox" do
      assert_equal([[0, 0], [100, 0], [80, 80], [0, 100]], @loc.bounds)
      assert_equal(:ok, @loc.forward(10, 10).status)
      assert_equal(:ok, @loc.forward(50, 50).status)
      assert_equal(:outside_bounds, @loc.forward(95, 95).status)
      assert_equal(:ok, @loc.forward(80, 80).status)
    end

    it "works for inverse queries as well" do
      assert_equal(:outside_bounds, @loc.inverse(95, 95).status)
      assert_equal(:ok, @loc.inverse(50, 50).status)
    end
  end

  describe "page rotation" do
    before do
      @measure = {Subtype: :GEO, LPTS: [0, 0, 1, 0, 0, 1],
                  GPTS: [10, 20, 11, 20, 10, 21]}
      @vp = @doc.wrap({BBox: [0, 0, 100, 200], Measure: @measure},
                      type: HexaPDF::Type::Viewport)
    end

    [[90, [20, 90]], [180, [90, 180]], [270, [90, 20]]].each do |rotation, point|
      it "maps native point (10, 20) to #{point.inspect} on a #{rotation}-degree page" do
        page = @doc.add({Type: :Page, MediaBox: [0, 0, 100, 200], Rotate: rotation})
        loc = HexaPDF::Geo::Locator.new(@vp, page: page)
        assert_equal(rotation, loc.rotation)

        result = loc.inverse(20, 40)
        assert_equal(:ok, result.status)
        assert_close(point, result.page_point)
        assert_close([20, 40], loc.forward(*result.page_point).geo_point)

        assert_close([20, 40], loc.forward(10, 20, display: false).geo_point)
      end
    end
  end

  describe "UserUnit" do
    before do
      @page = @doc.add({Type: :Page, MediaBox: [0, 0, 50, 100], UserUnit: 2.0})
      measure = {Subtype: :GEO, LPTS: [0, 0, 100, 0, 0, 100],
                 GPTS: [10, 50, 12, 50, 10, 52]}
      @vp = @doc.wrap({BBox: [0, 0, 100, 100], Measure: measure},
                      type: HexaPDF::Type::Viewport)
      @loc = HexaPDF::Geo::Locator.new(@vp, page: @page)
    end

    it "exposes the UserUnit value and scales point input" do
      assert_in_delta(2.0, @loc.user_unit)
      assert_close([11, 51], @loc.forward(50, 50).geo_point)
      assert_close([50, 50], @loc.inverse(11, 51).page_point)
    end

    it "accepts PDF user units when requested" do
      result = @loc.forward(25, 25, units: :pdf)
      assert_close([11, 51], result.geo_point)
      assert_close([25, 25], result.page_point)
      assert_close([25, 25], @loc.inverse(11, 51, units: :pdf).page_point)
    end

    it "checks bounds in the units of the input coordinate space" do
      assert_equal(:outside_bounds, @loc.forward(110, 110, units: :pdf).status)
      assert_equal(:outside_bounds, @loc.forward(220, 220).status)
    end
  end

  describe "coordinate systems" do
    it "prefers the display coordinate system and never converts values" do
      loc = locator(LPTS: [0, 0, 1, 0, 0, 1], GPTS: [500000, 5000000, 500001, 5000000, 500000, 5000001],
                   GCS: 'EPSG:4326', DCS: 'EPSG:32633')
      assert_equal('EPSG:32633', loc.coordinate_system)
      assert_equal('EPSG:4326', loc.geographic_coordinate_system)
      assert_close([500000.5, 5000000.5], loc.forward(0.5, 0.5).geo_point)
    end
  end

  it "reads the geospatial information from a serialized document" do
    page = @doc.pages.add
    page[:MediaBox] = [0, 0, 612, 792]
    page[:Rotate] = 90
    measure = {Type: :Measure, Subtype: :GEO, GCS: :GCS_WGS84,
               LPTS: [72, 72, 144, 72, 72, 144],
               GPTS: [16.0, 48.0, 16.1, 48.0, 16.0, 48.1]}
    page[:VP] = [@doc.wrap({Type: :Viewport, Name: 'Vienna',
                            BBox: [72, 72, 540, 720], Measure: measure},
                           type: HexaPDF::Type::Viewport)]

    io = StringIO.new
    @doc.write(io)
    io.rewind
    loaded = HexaPDF::Document.new(io: io)
    locator = loaded.pages.first.geo_locator('Vienna')
    assert(locator.valid?)
    assert_instance_of(HexaPDF::Type::Measure::Geo, locator.measure)
    assert_equal(90, locator.rotation)

    result = locator.forward(200, 200)
    assert_close([16.4722222222, 48.1777777778], result.geo_point)
    assert_close([200, 200], locator.inverse(*result.geo_point).page_point)
  end
end
