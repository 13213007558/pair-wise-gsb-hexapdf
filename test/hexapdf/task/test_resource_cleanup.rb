# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/document'
require 'hexapdf/task/resource_cleanup'

describe HexaPDF::Task::ResourceCleanup do
  before do
    @doc = HexaPDF::Document.new
  end

  def add_font(base_font = :Helvetica)
    @doc.add({Type: :Font, Subtype: :Type1, BaseFont: base_font, Encoding: :WinAnsiEncoding,
              FirstChar: 32, LastChar: 255, Widths: Array.new(224, 600)})
  end

  def add_type3_font(resources: {}, char_procs: {})
    @doc.add({Type: :Font, Subtype: :Type3, Encoding: :WinAnsiEncoding,
              FirstChar: 32, LastChar: 32, Widths: [600],
              FontBBox: [0, 0, 100, 100], FontMatrix: [0.001, 0, 0, 0.001, 0, 0],
              CharProcs: char_procs, Resources: resources})
  end

  def add_form(contents, resources: nil)
    dict = {Type: :XObject, Subtype: :Form, BBox: [0, 0, 10, 10]}
    dict[:Resources] = resources if resources
    @doc.add(dict, stream: contents)
  end

  def add_image(color_space = :DeviceGray)
    @doc.add({Type: :XObject, Subtype: :Image, Width: 1, Height: 1,
              ColorSpace: color_space, BitsPerComponent: 8}, stream: 'x')
  end

  def add_page(resources, contents)
    page = @doc.pages.add
    page[:Resources] = resources
    page.contents = contents
    page
  end

  def font_keys(resources)
    dict = resources[:Font]
    dict ? dict.to_hash.keys : []
  end

  def entry_for(report_list, category, name)
    report_list.find {|entry| entry.category == category && entry.name == name }
  end

  describe 'basic cleanup' do
    it 'removes unused entries and keeps used ones, distinguishing same-named fonts' do
      font_a = add_font(:Helvetica)
      font_b = add_font(:Courier)
      font_c = add_font(:'Times-Roman')
      page1 = add_page({Font: {F1: font_a, F2: font_b}}, 'BT /F1 12 Tf (one) Tj ET')
      page2 = add_page({Font: {F1: font_c}}, '0 0 m')

      report = @doc.task(:resource_cleanup)

      assert_kind_of(HexaPDF::Task::ResourceCleanup::Report, report)
      assert_equal([:F1], font_keys(page1[:Resources]))
      assert_equal([], font_keys(page2[:Resources]))
      refute(report.empty?)

      kept = entry_for(report.kept, :Font, :F1)
      assert_equal(page1[:Resources], kept.resources)
      assert_match(/Tf operator/, kept.reason)
      assert_match(%r{/Font /F1}, kept.to_s)
      assert_match(/kept: Tf operator/, kept.to_s)

      deleted = report.deleted.select {|entry| entry.category == :Font }
      assert_equal(2, deleted.size)
      assert_nil(entry_for(report.deleted, :Font, :F1).reason)
      assert_match(%r{/Font /F1}, entry_for(report.deleted, :Font, :F1).to_s)
      assert_equal(page2[:Resources], entry_for(report.deleted, :Font, :F1).resources)
      assert_equal(page1[:Resources], entry_for(report.deleted, :Font, :F2).resources)
      assert_match(/Deleted 2 unused resource entries/, report.to_s)
    end

    it 'returns an empty report when there is nothing to clean' do
      page = @doc.pages.add
      page.contents = '0 0 m'
      report = HexaPDF::Task::ResourceCleanup.call(@doc)
      assert(report.empty?)
      assert_match(/Deleted 0 unused resource entries/, report.to_s)
    end

    it 'only reports but does not modify the document when dry_run is set' do
      font_a = add_font
      font_b = add_font(:Courier)
      page = add_page({Font: {F1: font_a, F2: font_b}}, 'BT /F1 12 Tf (x) Tj ET')

      report = HexaPDF::Task::ResourceCleanup.call(@doc, dry_run: true)

      assert_equal([:F1, :F2], font_keys(page[:Resources]))
      assert_equal([:F2], report.deleted.map(&:name))
      assert_equal([:F1], report.kept.map(&:name))
    end
  end

  describe 'resource inheritance and contexts' do
    it 'respects resource inheritance through the page tree' do
      font_a = add_font
      font_b = add_font(:Courier)
      @doc.pages.root[:Resources] = {Font: {F1: font_a, F2: font_b}}
      page1 = @doc.pages.add
      page1.contents = 'BT /F1 12 Tf (x) Tj ET'
      page2 = @doc.pages.add
      page2.contents = '0 0 m'

      @doc.task(:resource_cleanup)

      assert_equal([:F1], font_keys(@doc.pages.root[:Resources]))
    end

    it 'follows nested form XObjects and honors local resource overrides' do
      inner_used = add_font
      inner_unused = add_font(:Courier)
      outer_unused = add_font(:'Times-Roman')
      page_unused = add_font(:Symbol)
      inner = add_form('BT /F1 10 Tf (i) Tj ET', resources: {Font: {F1: inner_used, F2: inner_unused}})
      outer = add_form('/Fm1 Do', resources: {XObject: {Fm1: inner}, Font: {F1: outer_unused}})
      page = add_page({XObject: {Fm0: outer}, Font: {F1: page_unused}}, '/Fm0 Do')

      @doc.task(:resource_cleanup)

      assert_equal([:F1], font_keys(inner[:Resources]))
      assert_equal([], font_keys(outer[:Resources]))
      assert_equal([:Fm1], outer[:Resources][:XObject].to_hash.keys)
      assert_equal([:Fm0], page[:Resources][:XObject].to_hash.keys)
      assert_equal([], font_keys(page[:Resources]))
    end

    it 'uses the page resources for form XObjects without their own resources' do
      font_a = add_font
      font_b = add_font(:Courier)
      form = add_form('BT /F1 10 Tf (x) Tj ET')
      page = add_page({XObject: {Fm: form}, Font: {F1: font_a, F2: font_b}}, '/Fm Do')

      @doc.task(:resource_cleanup)

      assert_equal([:F1], font_keys(page[:Resources]))
    end

    it 'does not mix up same-named references of different resource contexts' do
      font_a = add_font
      font_b = add_font(:Courier)
      form = add_form('BT /F1 10 Tf (x) Tj ET')
      page1 = add_page({XObject: {Fm: form}, Font: {F1: font_a}}, '/Fm Do')
      page2 = add_page({XObject: {Fm: form}, Font: {F1: font_b}}, '0 0 m')

      report = @doc.task(:resource_cleanup)

      assert_equal([:F1], font_keys(page1[:Resources]))
      assert_equal([], font_keys(page2[:Resources]))
      assert_equal([:Fm], page1[:Resources][:XObject].to_hash.keys)
      assert_empty(page2[:Resources][:XObject].to_hash)
      assert_equal(1, report.kept.count {|entry| entry.category == :Font })
    end

    it 'analyzes a shared form XObject only once even if used from several pages' do
      font = add_font
      form = add_form('BT /F1 10 Tf (x) Tj ET', resources: {Font: {F1: font}})
      add_page({XObject: {Fm: form}}, '/Fm Do')
      add_page({XObject: {Fm: form}}, '/Fm Do /Fm Do')

      report = @doc.task(:resource_cleanup)

      assert_equal([:F1], font_keys(form[:Resources]))
      assert_equal(1, report.kept.count {|entry| entry.category == :Font })
    end
  end

  describe 'cyclic references and unparsable content' do
    it 'terminates on cyclic references and records them' do
      form_a = nil
      form_b = add_form('/FmA Do', resources: {XObject: {}})
      form_a = add_form('/FmB Do', resources: {XObject: {FmB: form_b}})
      form_b[:Resources][:XObject][:FmA] = form_a
      self_ref = add_form('/FmS Do', resources: {XObject: {}})
      self_ref[:Resources][:XObject][:FmS] = self_ref
      add_page({XObject: {FmA: form_a, FmS: self_ref}}, '/FmA Do /FmS Do')

      report = @doc.task(:resource_cleanup)

      assert_equal(2, report.cycles.size)
      assert_match(/Cyclic reference/, report.cycles.first.message)
      assert_match(/Cyclic reference/, report.cycles.first.to_s)
      assert_match(/cycle: Cyclic/, report.to_s)
      assert_equal([:FmB], form_a[:Resources][:XObject].to_hash.keys)
      assert_equal([:FmA], form_b[:Resources][:XObject].to_hash.keys)
      assert_equal([:FmS], self_ref[:Resources][:XObject].to_hash.keys)
    end

    it 'conservatively keeps all entries if a content stream cannot be parsed' do
      font_a = add_font
      font_b = add_font(:Courier)
      page = add_page({Font: {F1: font_a, F2: font_b}}, '>')

      report = @doc.task(:resource_cleanup)

      assert_equal([:F1, :F2], font_keys(page[:Resources]))
      assert_equal(2, report.kept.size)
      assert_match(/conservatively kept/, report.kept.first.reason)
    end

    it 'conservatively keeps the entries of an unparsable form XObject' do
      font_a = add_font
      font_b = add_font(:Courier)
      font_c = add_font(:'Times-Roman')
      form = add_form('>', resources: {Font: {F1: font_a, F2: font_b}})
      page = add_page({XObject: {Fm: form}, Font: {F3: font_c}}, '/Fm Do')

      @doc.task(:resource_cleanup)

      assert_equal([:F1, :F2], font_keys(form[:Resources]))
      assert_equal([], font_keys(page[:Resources]))
    end
  end

  describe 'indirect resource users' do
    it 'follows Type3 fonts and cleans their resource dictionaries' do
      used = add_font
      unused = add_font(:Courier)
      page_unused = add_font(:'Times-Roman')
      char_proc = @doc.add({}, stream: 'BT /F2 1 Tf (x) Tj ET')
      type3 = add_type3_font(resources: {Font: {F2: used, F3: unused}},
                             char_procs: {A: char_proc})
      page = add_page({Font: {F1: type3, F4: page_unused}}, 'BT /F1 10 Tf (A) Tj ET')

      @doc.task(:resource_cleanup)

      assert_equal([:F1], font_keys(page[:Resources]))
      assert_equal([:F2], font_keys(type3[:Resources]))
    end

    it 'follows tiling patterns, shading patterns and shadings' do
      pattern_used = add_font
      pattern_unused = add_font(:Courier)
      tiling = @doc.add({Type: :Pattern, PatternType: 1, PaintType: 1, TilingType: 1,
                         BBox: [0, 0, 10, 10], XStep: 10, YStep: 10,
                         Resources: {Font: {F1: pattern_used, F2: pattern_unused}}},
                        stream: 'BT /F1 1 Tf (x) Tj ET')
      shading_dict = {ShadingType: 2, ColorSpace: :CS1, Coords: [0, 0, 10, 10], Function: {}}
      shading_pattern = @doc.add({Type: :Pattern, PatternType: 2, Shading: shading_dict})
      unused_pattern = @doc.add({Type: :Pattern, PatternType: 2, Shading: shading_dict})
      resources = {Pattern: {P1: tiling, P2: shading_pattern, P3: unused_pattern},
                   Shading: {Sh1: shading_dict, Sh2: {ShadingType: 2, ColorSpace: :DeviceRGB}},
                   ColorSpace: {CS1: [:Indexed, :DeviceRGB, 1, "\x00".b]}}
      page = add_page(resources, '/Pattern cs /P1 scn /Pattern CS /P2 SCN /Sh1 sh')

      @doc.task(:resource_cleanup)

      assert_equal([:P1, :P2], page[:Resources][:Pattern].to_hash.keys)
      assert_equal([:Sh1], page[:Resources][:Shading].to_hash.keys)
      assert_equal([:CS1], page[:Resources][:ColorSpace].to_hash.keys)
      assert_equal([:F1], font_keys(tiling[:Resources]))
    end

    it 'follows soft masks and font entries of graphics state parameter dictionaries' do
      group_used = add_font
      type3_used = add_font(:Courier)
      type3_unused = add_font(:'Times-Roman')
      char_proc = @doc.add({}, stream: 'BT /F3 1 Tf (x) Tj ET')
      type3 = add_type3_font(resources: {Font: {F3: type3_used, F4: type3_unused}},
                             char_procs: {A: char_proc})
      group = add_form('BT /F1 1 Tf (x) Tj ET', resources: {Font: {F1: group_used}})
      gstate1 = @doc.add({SMask: {S: :Luminosity, G: group}})
      gstate2 = @doc.add({Font: [type3, 10]})
      gstate3 = @doc.add({SMask: :None})
      gstate_unused = @doc.add({CA: 0.5})
      resources = {ExtGState: {GS1: gstate1, GS2: gstate2, GS3: gstate3, GS4: gstate_unused}}
      add_page(resources, '/GS1 gs /GS2 gs /GS3 gs')

      @doc.task(:resource_cleanup)

      assert_equal([:F1], font_keys(group[:Resources]))
      assert_equal([:F3], font_keys(type3[:Resources]))
    end

    it 'follows color space definitions, images and inline images' do
      icc = @doc.add({N: 3, Alternate: :DeviceRGB}, stream: 'icc')
      func = @doc.add({FunctionType: 2, Domain: [0, 1], C0: [0], C1: [1], N: 1})
      image1 = add_image(:CS3)
      image2 = add_image(icc)
      unused_xobject = add_image
      resources = {
        ColorSpace: {CS1: [:Indexed, :CS2, 1, "\x00".b],
                     CS2: [:Separation, :Spot, :DeviceCMYK, func],
                     CS3: [:ICCBased, icc],
                     CS4: [:DeviceN, [:Spot], :CS2, func],
                     CS5: :DeviceGray,
                     CS6: :DeviceGray},
        XObject: {Im1: image1, Im2: image2, Im3: unused_xobject},
      }
      content = '/CS1 cs /CS4 CS /Im1 Do /Im2 Do [/Pattern /DeviceRGB] cs /DeviceRGB CS ' \
        'BI /W 1 /H 1 /BPC 8 /CS /CS3 ID xEI '
      page = add_page(resources, content)

      @doc.task(:resource_cleanup)

      assert_equal(%i[CS1 CS2 CS3 CS4], page[:Resources][:ColorSpace].to_hash.keys)
      assert_equal(%i[Im1 Im2], page[:Resources][:XObject].to_hash.keys)
    end

    it 'follows marked content property lists' do
      resources = {Properties: {P1: {}, P2: {}, P3: {}}}
      page = add_page(resources, '/Span /P1 BDC EMC /Span /P2 DP /Span << /K 1 >> BDC EMC')

      @doc.task(:resource_cleanup)

      assert_equal(%i[P1 P2], page[:Resources][:Properties].to_hash.keys)
    end

    it 'takes annotation appearance streams into account' do
      font_a = add_font
      font_b = add_font(:Courier)
      appearance_font = add_font(:'Times-Roman')
      appearance1 = add_form('BT /F1 10 Tf (x) Tj ET')
      appearance2 = add_form('BT /F3 1 Tf (y) Tj ET', resources: {Font: {F3: appearance_font}})
      annot1 = @doc.add({Type: :Annot, Subtype: :Widget, Rect: [0, 0, 10, 10],
                         AP: {N: appearance1}})
      annot2 = @doc.add({Type: :Annot, Subtype: :Widget, Rect: [0, 0, 10, 10],
                         AP: {N: {On: appearance2, Off: appearance2}}})
      annot3 = @doc.add({Type: :Annot, Subtype: :Text, Rect: [0, 0, 1, 1]})
      page = add_page({Font: {F1: font_a, F2: font_b}}, '0 0 m')
      page[:Annots] = [annot1, annot2, annot3]

      @doc.task(:resource_cleanup)

      assert_equal([:F1], font_keys(page[:Resources]))
      assert_equal([:F3], font_keys(appearance2[:Resources]))
    end
  end

  describe 'robustness' do
    it 'handles broken or unresolvable references gracefully' do
      used = add_font
      char_proc = @doc.add({}, stream: '0 0 0 0 0 0 d0')
      type3 = add_type3_font(resources: {}, char_procs: {A: char_proc, B: 5})
      resources = {
        Font: {F1: used, F5: 5, F6: type3},
        XObject: {X1: {}, X2: 5},
        ExtGState: {GS5: 5},
        Pattern: {P4: :Foo},
        Shading: {Sh3: :Foo},
        ColorSpace: {CS9: 5},
      }
      content = 'BT /F1 12 Tf /F5 12 Tf /F6 12 Tf /F9 12 Tf 5 12 Tf (x) Tj ET ' \
        '/X1 Do /X2 Do /X9 Do /GS5 gs /P4 scn /Sh3 sh /CS9 cs'
      page = add_page(resources, content)

      @doc.task(:resource_cleanup)

      assert_equal(%i[F1 F5 F6], font_keys(page[:Resources]))
      assert_equal(%i[X1 X2], page[:Resources][:XObject].to_hash.keys)
      assert_equal([:GS5], page[:Resources][:ExtGState].to_hash.keys)
      assert_equal([:P4], page[:Resources][:Pattern].to_hash.keys)
      assert_equal([:Sh3], page[:Resources][:Shading].to_hash.keys)
      assert_equal([:CS9], page[:Resources][:ColorSpace].to_hash.keys)
    end
  end

  describe 'round-trip' do
    it 'leaves all content references resolvable after writing and reopening' do
      font_a = add_font(:Helvetica)
      font_b = add_font(:Courier)
      font_c = add_font(:'Times-Roman')
      inner = add_form('BT /F1 10 Tf (i) Tj ET')
      outer = add_form('/Fm1 Do BT /F2 8 Tf (o) Tj ET',
                       resources: {XObject: {Fm1: inner}, Font: {F2: font_b, F3: font_c}})
      page1 = add_page({XObject: {Fm0: outer}, Font: {F1: font_a}},
                       'BT /F1 12 Tf (p1) Tj ET /Fm0 Do')
      add_page({Font: {F1: font_b}}, '0 0 m')

      @doc.task(:resource_cleanup)

      io = StringIO.new
      @doc.write(io)
      io.rewind
      doc = HexaPDF::Document.new(io: io)
      doc.pages.each do |page|
        page.process_contents(HexaPDF::Content::Processor.new)
      end
      assert_equal([:F1], doc.pages[0][:Resources][:Font].to_hash.keys)
      assert_empty(doc.pages[1][:Resources][:Font].to_hash)
      assert_equal([:F2], doc.pages[0][:Resources][:XObject][:Fm0][:Resources][:Font].to_hash.keys)
    end
  end
end
