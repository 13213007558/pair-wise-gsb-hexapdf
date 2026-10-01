# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/document'

describe HexaPDF::Type::Measure do
  before do
    @doc = HexaPDF::Document.new
  end

  it "is identified as geospatial based on its subtype" do
    geo = @doc.wrap({Type: :Measure, Subtype: :GEO}, type: :Measure)
    rl = @doc.wrap({Type: :Measure, Subtype: :RL}, type: :Measure)
    assert(geo.geo?)
    refute(rl.geo?)
  end

  it "wraps the GeoCS entry and exposes the GEO fields" do
    measure = @doc.wrap({
      Type: :Measure, Subtype: :GEO,
      GeoCS: {Type: :GeoCS, EPSG: 4326, WKT: 'GEOGCS["WGS 84"]'},
      LPTS: [0, 0, 1, 1], GPTS: [0, 0, 0, 1], Bounds: [0, 0, 1, 1], PDU: 2
    }, type: :Measure)
    assert_kind_of(HexaPDF::Type::Measure::GeoCS, measure[:GeoCS])
    assert_kind_of(HexaPDF::PDFArray, measure[:LPTS])
    assert_kind_of(HexaPDF::PDFArray, measure[:GPTS])
    assert_kind_of(HexaPDF::PDFArray, measure[:Bounds])
    assert_equal(2, measure[:PDU])
    assert_equal(1, @doc.wrap({Type: :Measure, Subtype: :GEO}, type: :Measure)[:PDU])
  end
end

describe HexaPDF::Type::Measure::GeoCS do
  before do
    @doc = HexaPDF::Document.new
  end

  def geocs(**fields)
    @doc.wrap({Type: :GeoCS}.merge(fields), type: :GeoCS)
  end

  it "detects geographic systems from WKT" do
    assert_equal(:geographic, geocs(WKT: 'GEOGCS["WGS 84"]').coordinate_system_kind)
    assert_equal(:geographic, geocs(WKT: 'GEOGCRS["WGS 84"]').coordinate_system_kind)
  end

  it "detects projected systems from WKT" do
    assert_equal(:projected, geocs(WKT: 'PROJCS["UTM zone 33N"]').coordinate_system_kind)
    assert_equal(:projected, geocs(WKT: 'PROJCRS["UTM zone 33N"]').coordinate_system_kind)
  end

  it "uses well-known geographic EPSG codes when WKT is absent" do
    assert_equal(:geographic, geocs(EPSG: 4326).coordinate_system_kind)
    assert_equal(:geographic, geocs(EPSG: 4258).coordinate_system_kind)
  end

  it "does not guess the coordinate system for unknown or missing identifiers" do
    assert_equal(:unknown, geocs(EPSG: 32633).coordinate_system_kind)
    assert_equal(:unknown, geocs.coordinate_system_kind)
    assert_equal(:unknown, geocs(URI: 'urn:example:crs').coordinate_system_kind)
  end
end

describe HexaPDF::Type::Viewport do
  before do
    @doc = HexaPDF::Document.new
  end

  it "stores BBox and Measure entries" do
    viewport = @doc.wrap({
      Type: :Viewport, Name: "main", BBox: [0, 0, 100, 200],
      Measure: {Type: :Measure, Subtype: :GEO}
    }, type: :Viewport)
    assert_kind_of(HexaPDF::Rectangle, viewport[:BBox])
    assert_equal(100, viewport[:BBox].width)
    assert_kind_of(HexaPDF::Type::Measure, viewport[:Measure])
    assert_equal("main", viewport[:Name])
  end
end
