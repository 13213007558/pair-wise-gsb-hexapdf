# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/document'
require 'hexapdf/task/clean_resources'

describe HexaPDF::Task::CleanResources do
  before do
    @doc = HexaPDF::Document.new
  end

  # Wraps a plain hash as a dictionary suitable for use as a resource sub-dictionary.
  def dict(hash)
    @doc.wrap(hash, type: HexaPDF::Dictionary)
  end

  # Returns the serializable PDF object of a font wrapper.
  def font(name)
    @doc.fonts.add(name).pdf_object
  end

  def form(stream:, **options)
    options[:BBox] ||= [0, 0, 100, 100]
    @doc.add(options.merge(Type: :XObject, Subtype: :Form), stream: stream)
  end

  def deleted_keys(report, category)
    report.deleted_entries.select {|e| e.category == category }.map(&:name)
  end

  it "handles two pages with the same resource name pointing to different fonts" do
    font1 = font('Helvetica')
    font2 = font('Courier')
    page1, page2 = @doc.pages.add, @doc.pages.add
    page1.resources[:Font] = dict(F1: font1, F2: font2)
    page2.resources[:Font] = dict(F1: font2)
    page1.contents = "BT /F1 12 Tf (a) Tj ET"
    page2.contents = "BT /F1 12 Tf (b) Tj ET"

    report = @doc.task(:clean_resources)

    assert_includes(page1.resources[:Font].each.map {|k, _| k }, :F1)
    refute_includes(page1.resources[:Font].each.map {|k, _| k }, :F2)
    assert_equal([:F1], page2.resources[:Font].each.map {|k, _| k })
    assert_equal([:F2], deleted_keys(report, :Font))
    kept = report.kept_entries.select {|e| e.entry.category == :Font }
    assert(kept.all? {|e| e.reason =~ /Tf/ })
    assert_same(font2, page2.resources[:Font][:F1])
    refute_same(font2, page1.resources[:Font][:F1])
  end

  it "recursively analyzes nested Form XObjects with overriding resources" do
    inner_unused_xobject = @doc.add({})
    inner = form(stream: "0 0 10 10 re f")
    inner[:Resources] = {XObject: dict(InnerUnused: inner_unused_xobject)}
    outer_unused = form(stream: "0 0 5 5 re f")
    outer = form(stream: "/Inner Do")
    outer[:Resources] = {XObject: dict(Inner: inner, OuterUnused: outer_unused)}

    page = @doc.pages.add
    page.resources[:XObject] = dict(Outer: outer, NotExecuted: form(stream: ""))
    page.contents = "/Outer Do"

    report = @doc.task(:clean_resources)

    assert_equal([:Outer], page.resources[:XObject].each.map {|k, _| k })
    assert_equal([:Inner], outer[:Resources][:XObject].each.map {|k, _| k })
    refute(inner[:Resources][:XObject].key?(:InnerUnused))
    names = report.deleted_entries.map(&:name)
    assert_includes(names, :NotExecuted)
    assert_includes(names, :OuterUnused)
    assert_includes(names, :InnerUnused)
  end

  it "lets Form XObjects without own resources inherit the enclosing resource context" do
    font = font('Helvetica')
    inherited_form = form(stream: "BT /F1 12 Tf (x) Tj ET")
    page = @doc.pages.add
    page.resources[:Font] = dict(F1: font, Unused: font('Courier'))
    page.resources[:XObject] = dict(Fm: inherited_form)
    page.contents = "/Fm Do"

    report = @doc.task(:clean_resources)

    assert_equal([:F1], page.resources[:Font].each.map {|k, _| k })
    assert(report.deleted_entries.any? {|e| e.name == :Unused })
  end

  it "resolves the same name in a shared, resource-less Form XObject per call context" do
    font_a = font('Helvetica')
    font_b = font('Courier')
    # Shared Form XObject without own resources; /F1 is resolved against the caller's context.
    shared = form(stream: "BT /F1 12 Tf (s) Tj ET")
    page1, page2 = @doc.pages.add, @doc.pages.add
    page1.resources[:Font] = dict(F1: font_a, Dead1: font('Helvetica'))
    page2.resources[:Font] = dict(F1: font_b, Dead2: font('Courier'))
    page1.resources[:XObject] = dict(S: shared)
    page2.resources[:XObject] = dict(S: shared)
    page1.contents = "/S Do"
    page2.contents = "/S Do"

    report = @doc.task(:clean_resources)

    assert_equal([:F1], page1.resources[:Font].each.map {|k, _| k })
    assert_equal([:F1], page2.resources[:Font].each.map {|k, _| k })
    assert_same(font_a, page1.resources[:Font][:F1])
    assert_same(font_b, page2.resources[:Font][:F1])
    names = report.deleted_entries.map(&:name)
    assert_includes(names, :Dead1)
    assert_includes(names, :Dead2)
  end

  it "follows ExtGState soft masks and image XObject soft masks" do
    smask_xobject = @doc.add({})
    smask = form(stream: "/SmInner Do")
    smask[:Resources] = {XObject: dict(SmInner: smask_xobject, SmUnused: @doc.add({}))}
    gs = @doc.add({Type: :ExtGState, SMask: {S: :Luminosity, G: smask}})

    page = @doc.pages.add
    page.resources[:ExtGState] = dict(G1: gs, GUnused: @doc.add({Type: :ExtGState}))
    page.contents = "/G1 gs 0 0 10 10 re f"

    report = @doc.task(:clean_resources)

    refute(page.resources[:ExtGState].key?(:GUnused))
    assert(page.resources[:ExtGState].key?(:G1))
    assert(smask[:Resources][:XObject].key?(:SmInner))
    refute(smask[:Resources][:XObject].key?(:SmUnused))
    assert(report.kept_entries.any? {|k| k.entry.name == :G1 && k.reason =~ /gs/ })
    assert(report.kept_entries.any? {|k| k.entry.name == :SmInner })
  end

  it "tracks shadings and marked content properties" do
    props = @doc.add({Type: :OCG, Name: 'Layer'})
    shading = @doc.add({ShadingType: 1, ColorSpace: :DeviceGray})
    page = @doc.pages.add
    page.resources[:Shading] = dict(Sh: shading, ShDead: @doc.add({}))
    page.resources[:Properties] = dict(Mc: props, McDead: @doc.add({}))
    page.contents = "/Mc BDC /Sh sh EMC"

    report = @doc.task(:clean_resources)

    assert(page.resources[:Shading].key?(:Sh))
    refute(page.resources[:Shading].key?(:ShDead))
    assert(page.resources[:Properties].key?(:Mc))
    refute(page.resources[:Properties].key?(:McDead))
    assert(report.kept_entries.any? {|k| k.entry.name == :Sh && k.reason =~ /sh/ })
    assert(report.kept_entries.any? {|k| k.entry.name == :Mc && k.reason =~ /BDC/ })
  end

  it "tracks named color spaces and pattern color space bases" do
    page = @doc.pages.add
    page.resources[:ColorSpace] = dict(Cs: [:CalRGB, {WhitePoint: [1, 1, 1]}],
                                      CsDead: [:CalRGB, {WhitePoint: [1, 1, 1]}])
    page.contents = "/Cs cs 0.5 sc 0 0 10 10 re f"

    report = @doc.task(:clean_resources)

    assert(page.resources[:ColorSpace].key?(:Cs))
    refute(page.resources[:ColorSpace].key?(:CsDead))
    assert(report.kept_entries.any? {|k| k.entry.name == :Cs && k.reason =~ /cs/ })
  end

  it "ignores dangling resource names without deleting anything else" do
    page = @doc.pages.add
    page.resources[:XObject] = dict(Used: form(stream: "0 0 1 1 re f"))
    page.contents = "/Used Do /Missing Do"

    report = @doc.task(:clean_resources)

    assert(page.resources[:XObject].key?(:Used))
    assert_empty(report.deleted_entries)
  end

  it "respects inherited page resources from the page tree" do
    font = font('Helvetica')
    resources = @doc.wrap({Font: dict(F1: font, FDead: font('Courier'))},
                          type: HexaPDF::Type::Resources)
    root = @doc.catalog.pages
    root[:Resources] = resources
    page = @doc.pages.add
    page.contents = "BT /F1 12 Tf (x) Tj ET"

    report = @doc.task(:clean_resources)

    assert(resources[:Font].key?(:F1))
    refute(resources[:Font].key?(:FDead))
    assert_includes(report.deleted_entries.first.location, "inherited resources of page 1")
  end

  it "ensures every resource reference in reopened content streams is resolvable" do
    helv = font('Helvetica')
    cour = font('Courier')
    page1, page2 = @doc.pages.add, @doc.pages.add
    page1.resources[:Font] = dict(F1: helv)
    page2.resources[:Font] = dict(F1: cour)
    page1.contents = "BT /F1 12 Tf (page1) Tj ET"
    page2.contents = "BT /F1 12 Tf (page2) Tj ET"
    @doc.task(:clean_resources)

    io = StringIO.new
    @doc.write(io)
    io.rewind
    reopened = HexaPDF::Document.new(io: io)

    reopened.pages.each do |page|
      refs = []
      HexaPDF::Content::Parser.parse(page.contents) do |op, operands|
        refs << [:Font, operands[0]] if op == :Tf
        refs << [:XObject, operands[0]] if op == :Do
        refs << [:ExtGState, operands[0]] if op == :gs
        refs << [:Shading, operands[0]] if op == :sh
      end
      refs.each do |category, name|
        assert(page.resources[category], "missing #{category} dict")
        assert(page.resources[category].key?(name),
               "unresolvable #{category}/#{name} on page #{page.index + 1}")
      end
    end
    assert_equal(helv.oid, reopened.pages[0].resources[:Font][:F1].oid)
    assert_equal(cour.oid, reopened.pages[1].resources[:Font][:F1].oid)
  end

  it "analyzes Type3 font char procedures in their resource context" do
    used_inner_form = form(stream: "0 0 1 1 re f")
    charproc = form(stream: "/GlyphInner Do 0 0 1 1 re f")
    charproc[:Resources] = {XObject: dict(GlyphInner: used_inner_form,
                                          GlyphUnused: @doc.add({}))}
    type3 = @doc.add({Type: :Font, Subtype: :Type3, FontBBox: [0, 0, 1, 1],
                      FontMatrix: [0.001, 0, 0, 0.001, 0, 0],
                      Encoding: {Differences: [0, :A]},
                      CharProcs: dict(A: charproc)})

    page = @doc.pages.add
    page.resources[:Font] = dict(F3: type3, FUnused: font('Courier'))
    page.contents = "BT /F3 12 Tf (A) Tj ET"

    report = @doc.task(:clean_resources)

    assert(page.resources[:Font].key?(:F3))
    refute(page.resources[:Font].key?(:FUnused))
    assert(charproc[:Resources][:XObject].key?(:GlyphInner))
    refute(charproc[:Resources][:XObject].key?(:GlyphUnused))
    assert(report.kept_entries.any? {|k| k.entry.name == :F3 && k.reason =~ /Tf/ })
  end

  it "analyzes tiling patterns and their own resource dictionaries" do
    inner = form(stream: "0 0 1 1 re f")
    pattern = @doc.add({Type: :Pattern, PatternType: 1, PaintType: 1, TilingType: 1,
                        BBox: [0, 0, 2, 2], XStep: 2, YStep: 2,
                        Resources: {XObject: dict(PInner: inner, PUnused: @doc.add({}))}},
                       stream: "/PInner Do 0 0 2 2 re f")
    page = @doc.pages.add
    page.resources[:Pattern] = dict(Pat: pattern, PatUnused:
      @doc.add({Type: :Pattern, PatternType: 1, PaintType: 1, TilingType: 1,
                BBox: [0, 0, 1, 1], XStep: 1, YStep: 1}, stream: "0 0 1 1 re f"))
    page.contents = "/Pattern cs /Pat scn 0 0 10 10 re f"

    report = @doc.task(:clean_resources)

    assert(page.resources[:Pattern].key?(:Pat))
    refute(page.resources[:Pattern].key?(:PatUnused))
    assert(pattern[:Resources][:XObject].key?(:PInner))
    refute(pattern[:Resources][:XObject].key?(:PUnused))
    assert(report.kept_entries.any? {|k| k.entry.name == :Pat && k.reason =~ /scn/ })
  end

  it "terminates circular Form XObject references and records the cycle" do
    page = @doc.pages.add
    cyclic = form(stream: "/Self Do")
    cyclic[:Resources] = {XObject: dict(Self: cyclic, Extra: @doc.add({}))}
    page.resources[:XObject] = dict(Cyc: cyclic)
    page.contents = "/Cyc Do"

    report = @doc.task(:clean_resources)

    assert_equal(1, report.cycles.size)
    assert_same(cyclic, report.cycles.first.object)
    assert(cyclic[:Resources][:XObject].key?(:Self))
    refute(cyclic[:Resources][:XObject].key?(:Extra))
  end

  it "conservatively retains all visible resources of uninterpretable content streams" do
    page = @doc.pages.add
    page.resources[:Font] = dict(F1: font('Helvetica'))
    page.resources[:XObject] = dict(Im: @doc.add({}))
    page.contents = "/Im Do BT /F1 12 Tf ("

    report = @doc.task(:clean_resources)

    assert(page.resources[:XObject].key?(:Im))
    assert(page.resources[:Font].key?(:F1))
    assert_equal(1, report.warnings.size)
    assert(report.kept_entries.any? {|k| k.reason =~ /uninterpretable/ })
  end

  it "produces a fully valid and resolvable document after write and reopen" do
    font1 = font('Helvetica')
    font2 = font('Courier')
    page1, page2 = @doc.pages.add, @doc.pages.add
    page1.resources[:Font] = dict(F1: font1)
    page2.resources[:Font] = dict(F1: font2)
    nested = form(stream: "BT /F1 12 Tf (n) Tj ET")
    main_form = form(stream: "/N Do")
    main_form[:Resources] = {Font: dict(F1: font2), XObject: dict(N: nested,
                                                                   Dead: @doc.add({}))}
    page1.resources[:XObject] = dict(M: main_form, Dead: @doc.add({}))
    page1.contents = "/M Do BT /F1 12 Tf (p) Tj ET"
    page2.contents = "BT /F1 12 Tf (q) Tj ET"

    @doc.task(:clean_resources)
    io = StringIO.new
    @doc.write(io)
    io.rewind

    reopened = HexaPDF::Document.new(io: io)
    problems = []
    reopened.validate(auto_correct: false) {|msg, *_| problems << msg; false }
    assert_empty(problems)
    reopened.pages.each_with_index do |page, _index|
      page.process_contents(HexaPDF::Content::Processor.new)
    end
  end

  it "is available as its own document task" do
    page = @doc.pages.add
    page.resources[:XObject] = dict(Dead: @doc.add({}))
    page.contents = "0 0 10 10 re f"
    @doc.task(:clean_resources)
    refute(page.resources[:XObject].key?(:Dead))
  end
end
