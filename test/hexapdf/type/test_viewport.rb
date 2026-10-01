# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/document'
require 'hexapdf/type/viewport'

describe HexaPDF::Type::Viewport do
  before do
    @doc = HexaPDF::Document.new
  end

  def viewport(data = {})
    @doc.wrap({Type: :Viewport, BBox: [0, 0, 100, 100]}.merge(data),
              type: HexaPDF::Type::Viewport)
  end

  it "wraps the measure dictionary according to its subtype" do
    vp = viewport(Measure: {Type: :Measure, Subtype: :GEO, LPTS: [0, 0, 1, 1],
                            GPTS: [0, 0, 1, 1]})
    assert_instance_of(HexaPDF::Type::Measure::Geo, vp[:Measure])
  end

  describe "#bounds" do
    it "returns the BBox corners when there is no Bounds polygon" do
      vp = viewport(Measure: {Subtype: :GEO})
      assert_equal([[0, 0], [100, 0], [100, 100], [0, 100]], vp.bounds)
    end

    it "returns the GEO measure's Bounds polygon" do
      vp = viewport(Measure: {Subtype: :GEO, Bounds: [0, 0, 80, 0, 80, 80, 0, 80]})
      assert_equal([[0, 0], [80, 0], [80, 80], [0, 80]], vp.bounds)
    end

    it "ignores Bounds of non-GEO measures" do
      vp = viewport(Measure: {Type: :Measure, Subtype: :RL,
                              Bounds: [1, 2, 3, 4, 5, 6]})
      assert_equal([[0, 0], [100, 0], [100, 100], [0, 100]], vp.bounds)
    end
  end

  describe "#geo_locator" do
    it "returns a locator for the viewport" do
      vp = viewport(Measure: {Subtype: :GEO, LPTS: [0, 0, 1, 0, 0, 1],
                             GPTS: [0, 0, 1, 0, 0, 1]})
      locator = vp.geo_locator
      assert_instance_of(HexaPDF::Geo::Locator, locator)
      assert(locator.valid?)
    end
  end
end
