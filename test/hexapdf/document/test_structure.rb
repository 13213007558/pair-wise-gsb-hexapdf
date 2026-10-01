# -*- encoding: utf-8 -*-

require 'stringio'
require 'test_helper'
require 'hexapdf/document'

describe HexaPDF::Document::Structure do

  # Builds a tagged PDF with drawing order deliberately different from reading order and marked
  # content inside a Form XObject.
  def build_document
    doc = HexaPDF::Document.new
    page = doc.pages.add
    page[:StructParents] = 0
    font = doc.fonts.add("Helvetica")

    # Form XObject containing a marked content sequence (MCID 0 in the form's own stream).
    # Note: no explicit /Matrix, exercising the default-value read-only path.
    @form = doc.add({Type: :XObject, Subtype: :Form, BBox: [0, 0, 200, 50],
                     StructParents: 1}, stream: "")
    fcanvas = @form.canvas(translate: false)
    fcanvas.font(font, size: 12)
    fcanvas.marked_content_sequence(:P, property_list: {MCID: 0}) do
      fcanvas.text("FORM", at: [10, 30])
    end
    @form_name = page.resources.add_xobject(@form)

    # Drawing order: AAA (bottom), form, BBB (top) - the structure reads BBB, AAA, FORM.
    canvas = page.canvas
    canvas.font(font, size: 12)
    canvas.marked_content_sequence(:P, property_list: {MCID: 0}) do
      canvas.text("AAA", at: [100, 100])
    end
    canvas.marked_content_sequence(:P, property_list: {MCID: 2}) do
      canvas.xobject(@form, at: [200, 200], width: 200, height: 50)
    end
    canvas.marked_content_sequence(:P, property_list: {MCID: 1}) do
      canvas.text("BBB", at: [100, 700])
    end

    root = doc.add({Type: :StructTreeRoot})
    doc.catalog[:StructTreeRoot] = root
    doc.catalog[:MarkInfo] = {Marked: true}
    root[:RoleMap] = {Para: :P, Caption: :Para} # chain: Caption -> Para -> P
    root[:ParentTree] = doc.add({}, type: HexaPDF::NumberTreeNode)
    root[:ParentTreeNextKey] = 3

    @document_elem = doc.add({Type: :StructElem, S: :Document, P: root, Pg: page})
    @h1 = doc.add({Type: :StructElem, S: :H1, P: @document_elem, Pg: page,
                   Lang: 'en', Alt: 'heading alt'})
    @h1[:K] = 1 # integer MCID
    @para = doc.add({Type: :StructElem, S: :Caption, P: @document_elem, Pg: page, Lang: 'de'})
    @para[:K] = 0 # integer MCID
    @figure = doc.add({Type: :StructElem, S: :Figure, P: @document_elem, Pg: page,
                       Alt: 'a figure'})
    @figure[:K] = [{Type: :MCR, Pg: page, Stm: @form, MCID: 0}, # MCR in a Form XObject
                   {Type: :MCR, Pg: page, MCID: 2}] # MCR wrapping the Do call

    root[:K] = @document_elem
    @document_elem[:K] = [@h1, @para, @figure]

    root[:ParentTree].add_entry(0, [@para, @h1, @figure])
    root[:ParentTree].add_entry(1, [@figure])
    @root = root
    @page = page
    doc
  end

  def serialized(doc)
    io = StringIO.new
    HexaPDF::Writer.write(doc, io)
    io.string
  end

  def reread(doc)
    io = StringIO.new
    doc.write(io, validate: false)
    HexaPDF::Document.new(io: StringIO.new(io.string))
  end

  it "returns nil for documents without a structure tree" do
    doc = HexaPDF::Document.new
    assert_nil(doc.structure.struct_tree_root)
    assert_nil(doc.structure.root_element)
  end

  describe "structure elements" do
    before do
      @doc = build_document
      @structure = @doc.structure
      @element = @structure.root_element
    end

    it "reads the root element without problems" do
      assert(@structure.valid?)
      assert_equal([], @structure.problems)
      assert_equal(:Document, @element.role)
      assert_same(@document_elem, @element.source)
    end

    it "reads children in structure tree order, not drawing order" do
      roles = @element.children.map(&:role)
      assert_equal([:H1, :P, :Figure], roles) # Caption resolved through the RoleMap chain
      assert_equal([:H1, :Caption, :Figure], @element.children.map(&:original_role))
    end

    it "resolves roles transitively through the RoleMap" do
      assert_equal(:P, @element.children[1].role)
    end

    it "reads language and alternative text" do
      h1 = @element.children[0]
      assert_equal('en', h1.lang)
      assert_equal('heading alt', h1.alt)
      assert_equal('de', @element.children[1].lang)
      assert_equal('a figure', @element.children[2].alt)
    end

    it "provides the source dictionaries" do
      assert_same(@h1, @element.children[0].source)
    end
  end

  describe "marked content" do
    before do
      @doc = build_document
      @element = @doc.structure.root_element
    end

    it "handles integer MCIDs and extracts their text" do
      h1 = @element.children[0]
      assert_equal(1, h1.children.size)
      mc = h1.children[0]
      assert_kind_of(HexaPDF::Document::Structure::MarkedContent, mc)
      assert_equal(1, mc.mcid)
      refute(mc.in_form?)
      assert_equal("BBB", mc.text) # drawn last on the page but read first by the structure
      assert_equal(0, mc.page_index)
      assert_same(@page, mc.page)
    end

    it "extracts text in reading order regardless of the drawing order" do
      texts = @element.children.map(&:text)
      assert_equal(["BBB", "AAA", "FORMFORM"], texts)
    end

    it "handles MCRs pointing into Form XObjects" do
      figure = @element.children[2]
      form_mc = figure.children[0]
      assert_kind_of(HexaPDF::Document::Structure::MarkedContent, form_mc)
      assert_equal(0, form_mc.mcid)
      assert(form_mc.in_form?)
      assert_same(@form, form_mc.stream)
      assert_equal("FORM", form_mc.text)
      assert_equal(0, form_mc.page_index)

      wrapper_mc = figure.children[1]
      refute(wrapper_mc.in_form?)
      assert_equal(2, wrapper_mc.mcid)
      assert_equal("FORM", wrapper_mc.text)
    end

    it "collects the associated pages of an element" do
      assert_equal([@page], @element.pages)
      assert_same(@page, @element.children[0].page)
    end

    it "iterates descendants in tree order" do
      descendants = @element.each_descendant.to_a
      assert_equal([:H1, :P, :Figure], descendants.map(&:role))
    end

    it "uses ActualText instead of the marked content text when present" do
      @h1[:ActualText] = 'actual heading'
      elem = @doc.structure.root_element
      assert_equal('actual heading', elem.children[0].text)
    end
  end

  describe "object references" do
    before do
      @doc = build_document
      @annotation = @doc.add({Type: :Annot, Subtype: :Link, Rect: [0, 0, 10, 10],
                              StructParent: 5, P: @page})
      @page[:Annots] = [@annotation]
      @objr = @doc.add({Type: :OBJR, Pg: @page, Obj: @annotation})
      @link_elem = @doc.add({Type: :StructElem, S: :Link, P: @document_elem,
                             Pg: @page, K: @objr})
      @document_elem[:K] << @link_elem
      @root[:ParentTree].add_entry(5, @objr)
      @element = @doc.structure.root_element
    end

    it "handles OBJR kids" do
      assert(@doc.structure.valid?, @doc.structure.problems.map(&:message))
      link = @element.children[3]
      assert_equal(:Link, link.role)
      item = link.children[0]
      assert_kind_of(HexaPDF::Document::Structure::ObjectReference, item)
      assert_same(@annotation, item.object)
      assert_same(@objr, item.source)
      assert_equal(0, item.page_index)
    end
  end

  describe "ParentTree cross-checking" do
    it "accepts a consistent ParentTree after re-reading" do
      doc = reread(build_document)
      structure = doc.structure
      assert(structure.root_element)
      assert(structure.valid?, structure.problems.map(&:message))
    end

    it "reports a ParentTree entry that points to the wrong structure element" do
      doc = build_document
      other = doc.add({Type: :StructElem, S: :Span, P: @h1, Pg: @page})
      @root[:ParentTree].add_entry(0, [other, @h1, @figure]) # MCID 0 now points to 'other'
      problems = doc.structure.root_element && doc.structure.problems
      problem = problems.find {|p| p.code == :parent_tree_mismatch }
      refute_nil(problem)
      assert_match(/MCID 0/, problem.message)
      assert_match(/object/, problem.location)
    end

    it "reports a missing ParentTree entry for an MCID" do
      doc = build_document
      @root[:ParentTree].add_entry(0, [nil, @h1, @figure]) # MCID 0 entry missing
      doc.structure.root_element
      problem = doc.structure.problems.find {|p| p.code == :missing_parent_entry }
      refute_nil(problem)
      assert_match(/MCID 0/, problem.message)
    end

    it "reports a missing ParentTree altogether" do
      doc = build_document
      @root.delete(:ParentTree)
      doc.structure.root_element
      assert_equal(:missing_parent_tree, doc.structure.problems.first.code)
    end

    it "reports ParentTree entries that reference elements unreachable from the root" do
      doc = build_document
      orphan = doc.add({Type: :StructElem, S: :Span, P: @document_elem, Pg: @page})
      @root[:ParentTree].add_entry(7, orphan)
      doc.structure.root_element
      problem = doc.structure.problems.find {|p| p.code == :orphaned_parent_entry }
      refute_nil(problem)
      assert_match(/#{orphan.oid}/, problem.message)
    end
  end

  describe "diagnostics" do
    it "reports a structure element referenced twice in the tree" do
      doc = build_document
      @document_elem[:K] << @h1 # H1 already appears as the first kid
      doc.structure.root_element
      problem = doc.structure.problems.find {|p| p.code == :duplicate_reference }
      refute_nil(problem)
      assert_match(/object #{@h1.oid}/, problem.location)
      # the first occurrence and all still-readable parts are retained
      assert_equal([:H1, :P, :Figure], doc.structure.root_element.children.map(&:role))
    end

    it "reports the same content associated with two different elements" do
      doc = build_document
      @para[:K] = 1 # same integer MCID 1 as H1
      doc.structure.root_element
      problem = doc.structure.problems.find {|p| p.code == :content_conflict }
      refute_nil(problem)
      assert_match(/MCID 1/, problem.message)
    end

    it "reports the same content referenced twice by one element" do
      doc = build_document
      @h1[:K] = [1, 1]
      doc.structure.root_element
      problem = doc.structure.problems.find {|p| p.code == :duplicate_reference }
      refute_nil(problem)
    end

    it "reports an MCID that cannot be found in the content stream" do
      doc = build_document
      @para[:K] = 9
      doc.structure.root_element
      problem = doc.structure.problems.find {|p| p.code == :missing_mcid }
      refute_nil(problem)
      assert_match(/MCID 9/, problem.message)
    end

    it "reports an MCR pointing to a Form XObject that lacks the MCID" do
      doc = build_document
      @figure[:K] = [{Type: :MCR, Pg: @page, Stm: @form, MCID: 7}]
      doc.structure.root_element
      problem = doc.structure.problems.find {|p| p.code == :missing_mcid }
      refute_nil(problem)
      assert_match(/MCID 7/, problem.message)
      assert_match(/Form XObject/, problem.message)
    end

    it "reports a missing page for a marked content reference" do
      doc = build_document
      @document_elem.delete(:Pg)
      @h1.delete(:Pg)
      @h1[:K] = {Type: :MCR, MCID: 1} # no /Pg anywhere in the ancestor chain
      doc.structure.root_element
      problem = doc.structure.problems.find {|p| p.code == :missing_page }
      refute_nil(problem)
    end

    it "reports an invalid /Pg entry" do
      doc = build_document
      @h1[:Pg] = doc.add({Type: :Pages, Kids: [], Count: 0})
      doc.structure.root_element
      problem = doc.structure.problems.find {|p| p.code == :invalid_page }
      refute_nil(problem)
    end

    it "detects a circular role mapping and keeps the last resolvable role" do
      doc = build_document
      @root[:RoleMap] = {H1: :Foo, Foo: :Bar, Bar: :Foo, Caption: :Para, Para: :P}
      element = doc.structure.root_element
      problem = doc.structure.problems.find {|p| p.code == :circular_role_map }
      refute_nil(problem)
      assert_equal(:Bar, element.children[0].role)
      # non-circular mappings still work
      assert_equal(:P, element.children[1].role)
    end

    it "reports an invalid kid type" do
      doc = build_document
      @h1[:K] = [42.5]
      doc.structure.root_element
      problem = doc.structure.problems.find {|p| p.code == :invalid_kid }
      refute_nil(problem)
    end

    it "reports an OBJR with a missing object" do
      doc = build_document
      @h1[:K] = [{Type: :OBJR, Obj: HexaPDF::Reference.new(9999, 0)}]
      doc.structure.root_element
      problem = doc.structure.problems.find {|p| p.code == :missing_object }
      refute_nil(problem)
    end

    it "keeps readable parts when one element is invalid" do
      doc = build_document
      @h1[:S] = nil # invalid structure element
      element = doc.structure.root_element
      assert_equal([:P, :Figure], element.children.map(&:role))
      problem = doc.structure.problems.find {|p| p.code == :invalid_kid }
      refute_nil(problem)
    end

    it "works after re-reading the PDF from a serialized form" do
      doc = reread(build_document)
      element = doc.structure.root_element
      assert(doc.structure.valid?, doc.structure.problems.map(&:to_s))
      assert_equal([:H1, :P, :Figure], element.children.map(&:role))
      assert_equal(["BBB", "AAA", "FORMFORM"], element.children.map(&:text))
    end

    it "wraps multiple top-level kids in a synthetic element" do
      doc = build_document
      extra = doc.add({Type: :StructElem, S: :Div, P: @root, Pg: @page})
      @root[:K] = [@document_elem, extra]
      element = doc.structure.root_element
      assert_equal(:StructTreeRoot, element.role)
      assert_equal([:Document, :Div], element.children.map(&:role))
    end

    it "handles a structure tree root without kids" do
      doc = build_document
      @root.delete(:K)
      assert_nil(doc.structure.root_element)
    end

    it "reads expanded text and title" do
      doc = build_document
      @h1[:E] = 'expanded'
      @h1[:T] = 'title'
      h1 = doc.structure.root_element.children[0]
      assert_equal('expanded', h1.expanded)
      assert_equal('title', h1.title)
    end

    it "collects all content items recursively" do
      element = build_document.structure.root_element
      items = element.content_items
      assert_equal(4, items.size)
      assert_equal([1, 0, 0, 2], items.map(&:mcid))
    end
  end

  describe "edge cases and diagnostics coverage" do
    before do
      @doc = build_document
    end

    it "formats a problem with and without location" do
      with = HexaPDF::Document::Structure::Problem.new(:x, "msg", "loc", nil)
      without = HexaPDF::Document::Structure::Problem.new(:x, "msg", nil, nil)
      assert_equal("msg (loc)", with.to_s)
      assert_equal("msg", without.to_s)
    end

    it "reports a top-level kid that references a missing object" do
      @root[:K] = [HexaPDF::Reference.new(9999, 0)]
      assert_nil(@doc.structure.root_element)
      problem = @doc.structure.problems.find {|p| p.code == :invalid_kid }
      refute_nil(problem)
      assert_match(/nil/, problem.message)
    end

    it "reports an unknown kid dictionary type" do
      @h1[:K] = [{Foo: :Bar}]
      @doc.structure.root_element
      problem = @doc.structure.problems.find {|p| p.code == :unknown_kid }
      refute_nil(problem)
    end

    it "reports an MCR with an invalid MCID" do
      @h1[:K] = [{Type: :MCR, Pg: @page, MCID: "bad"}]
      @doc.structure.root_element
      problem = @doc.structure.problems.find {|p| p.code == :invalid_mcid }
      refute_nil(problem)
    end

    it "reports an MCR with a /Pg referencing a missing object and falls back" do
      @h1[:K] = [{Type: :MCR, Pg: HexaPDF::Reference.new(9998, 0), MCID: 1}]
      element = @doc.structure.root_element
      problem = element && @doc.structure.problems.find {|p| p.code == :missing_page }
      refute_nil(problem)
    end

    it "reports an MCR with a /Pg that is not a page" do
      @h1[:K] = [{Type: :MCR, Pg: @document_elem, MCID: 1}]
      @doc.structure.root_element
      problem = @doc.structure.problems.find {|p| p.code == :invalid_page }
      refute_nil(problem)
    end

    it "uses the stream's /Pg entry for an MCR that has no /Pg itself" do
      @form[:Pg] = @page
      @figure[:K] = [{Type: :MCR, Stm: @form, MCID: 0}]
      figure = @doc.structure.root_element.children[2]
      mc = figure.children[0]
      refute_nil(mc.page)
      assert_equal("FORM", mc.text)
    end

    it "reports a structure element with a missing /Pg reference" do
      @document_elem.delete(:Pg)
      @h1[:Pg] = HexaPDF::Reference.new(9997, 0)
      @doc.structure.root_element
      problem = @doc.structure.problems.find {|p| p.code == :missing_page }
      refute_nil(problem)
    end

    it "reports a structure element with a non-page /Pg" do
      @h1[:Pg] = @document_elem
      @doc.structure.root_element
      problem = @doc.structure.problems.find {|p| p.code == :invalid_page }
      refute_nil(problem)
    end

    it "resolves roles through a namespace role map" do
      ns = @doc.add({NS: "http://example.com", RoleMapNS: {Figure: :Formula}})
      @figure[:NS] = ns
      element = @doc.structure.root_element
      assert_equal(:Formula, element.children[2].role)
    end

    it "reports a page without a resources dictionary" do
      @page.delete(:Resources)
      @doc.structure.root_element
      problem = @doc.structure.problems.find {|p| p.code == :invalid_content }
      refute_nil(problem)
    end

    it "reports an unprocessable content stream" do
      @page.contents = "BT (unterminated string"
      @doc.structure.root_element
      problem = @doc.structure.problems.find {|p| p.code == :invalid_content }
      refute_nil(problem)
    end

    it "reports a ParentTree that cannot be read" do
      @root[:ParentTree] = {Nums: 5}
      @doc.structure.root_element
      problem = @doc.structure.problems.find {|p| p.code == :invalid_parent_tree }
      refute_nil(problem)
    end

    it "handles an OBJR conflict for the same object" do
      annot = @doc.add({Type: :Annot, Subtype: :Link, Rect: [0, 0, 1, 1], StructParent: 9,
                        P: @page})
      @page[:Annots] = [annot]
      objr1 = @doc.add({Type: :OBJR, Pg: @page, Obj: annot})
      objr2 = @doc.add({Type: :OBJR, Pg: @page, Obj: annot})
      l1 = @doc.add({Type: :StructElem, S: :Link, P: @document_elem, Pg: @page, K: objr1})
      l2 = @doc.add({Type: :StructElem, S: :Link, P: @document_elem, Pg: @page, K: objr2})
      @document_elem[:K] << l1 << l2
      @root[:ParentTree].add_entry(9, objr1)
      @doc.structure.root_element
      problem = @doc.structure.problems.find {|p| p.code == :content_conflict }
      refute_nil(problem)
      assert_match(/OBJR/, problem.message)
    end

    it "reports an invalid structure tree root" do
      @doc.catalog[:StructTreeRoot] = 42
      assert_nil(@doc.structure.struct_tree_root)
      refute_empty(@doc.structure.problems)
    end
  end

  describe "defensive branches" do
    before do
      @doc = build_document
    end

    # Appends an additional content stream to the page exercising DP points, inline property
    # dictionaries, missing property lists and references to missing resources.
    def append_extra_content
      extra = @doc.add({}, stream:
        "/DPnt << /MCID 5 >> DP\n/Tag << /MCID 3 >> BDC\nEMC\n" \
        "/Tag /Ghost BDC\nEMC\n/Missing Do\n")
      @page[:Contents] = Array(@page[:Contents]) << extra
    end

    it "renders locations for nil, direct and indirect objects" do
      assert_equal("here", HexaPDF::Document::Structure.const_get(:Location, false).new("here", nil).to_s)
      direct = @doc.wrap({S: :Span})
      assert_match(/direct object/,
                   HexaPDF::Document::Structure.const_get(:Location, false).new("here", direct).to_s)
      assert_match(/object #{@h1.oid}/,
                   HexaPDF::Document::Structure.const_get(:Location, false).new("here", @h1).to_s)
    end

    it "recovers when reading a structure element raises an unexpected error" do
      original = @h1.value.method(:[])
      @h1.value.define_singleton_method(:[]) do |name|
        raise "boom" if name == :K
        original.call(name)
      end
      @doc.structure.root_element
      problem = @doc.structure.problems.find {|p| p.code == :invalid_struct_elem }
      refute_nil(problem)
      # the siblings are still readable
      assert_equal([:P, :Figure], @doc.structure.root_element.children.map(&:role))
    end

    it "recovers when reading a structure kid raises an unexpected error" do
      mcr = @doc.add({Type: :MCR, Pg: @page, MCID: 1})
      mcr.define_singleton_method(:[]) do |name, *args|
        raise "boom" if name == :MCID
        super(name, *args)
      end
      @h1[:K] = mcr
      @doc.structure.root_element
      problem = @doc.structure.problems.find {|p| p.code == :invalid_kid }
      refute_nil(problem)
    end

    it "recovers when reading an MCR /Pg raises an unexpected error" do
      mcr = {Type: :MCR, Pg: @page, MCID: 1}
      mcr.define_singleton_method(:key?) { |*| raise "boom" }
      @h1[:K] = mcr
      @doc.structure.root_element
      problem = @doc.structure.problems.find {|p| p.code == :invalid_page }
      refute_nil(problem)
    end

    it "recovers when reading a structure element /Pg raises an unexpected error" do
      @h1.value.define_singleton_method(:key?) { |*| raise "boom" }
      @doc.structure.root_element
      problem = @doc.structure.problems.find {|p| p.code == :invalid_page }
      refute_nil(problem)
    end

    it "recovers from an invalid role map structure" do
      @root[:RoleMap] = [[:H1, :Foo]]
      @doc.structure.root_element
      problem = @doc.structure.problems.find {|p| p.code == :invalid_role_map }
      refute_nil(problem)
    end

    it "returns a nil page index when the page tree cannot be traversed" do
      @doc.pages.define_singleton_method(:each_with_index) { |*| raise "boom" }
      @doc.structure.root_element
      mc = @doc.structure.root_element.children[0].children[0]
      assert_nil(mc.page_index)
    end

    it "reports an unreadable page tree while indexing content" do
      @doc.pages.define_singleton_method(:each) { |*| raise "boom" }
      @doc.structure.root_element
      problem = @doc.structure.problems.find {|p| p.code == :invalid_page_tree }
      refute_nil(problem)
    end

    it "indexes marked-content points, inline properties and ignores missing resources" do
      append_extra_content
      @doc.structure.root_element
      assert(@doc.structure.valid?, @doc.structure.problems.map(&:to_s))
    end

    it "processes a nested form XObject carrying an explicit Matrix" do
      inner = @doc.add({Type: :XObject, Subtype: :Form, BBox: [0, 0, 10, 10],
                        Matrix: [1, 0, 0, 1, 5, 5]}, stream: "1 0 0 rg 0 0 10 10 re f\n")
      xname = @page.resources.add_xobject(inner)
      @page[:Contents] = Array(@page[:Contents]) <<
        @doc.add({}, stream: "q 1 0 0 1 0 0 cm /#{xname} Do Q\n")
      @doc.structure.root_element
      assert(@doc.structure.valid?, @doc.structure.problems.map(&:to_s))
    end

    it "resolves a named property list of a form from the page resources" do
      # The form has no own resources, so its named property list is resolved via the page.
      form = @doc.add({Type: :XObject, Subtype: :Form, BBox: [0, 0, 200, 50]},
                      stream: "/P1 BDC\nEMC\n")
      xname = @page.resources.add_xobject(form)
      @page[:Contents] = Array(@page[:Contents]) <<
        @doc.add({}, stream: "/P2 << /MCID 2 >> BDC\nq 1 0 0 1 0 0 cm /#{xname} Do Q\nEMC\n")
      @doc.structure.root_element
      assert(@doc.structure.valid?, @doc.structure.problems.map(&:to_s))
    end

    it "validates parent tree entries that are a direct MCR pointing back" do
      arr = @root[:ParentTree].find_entry(0)
      arr[1] = {Type: :MCR, P: @h1, MCID: 1}
      @doc.structure.root_element
      assert(@doc.structure.valid?, @doc.structure.problems.map(&:to_s))
    end

    it "reports a parent tree MCR entry without a /P reference" do
      arr = @root[:ParentTree].find_entry(0)
      arr[1] = {Type: :MCR, MCID: 1}
      @doc.structure.root_element
      problem = @doc.structure.problems.find {|p| p.code == :invalid_parent_entry }
      refute_nil(problem)
    end

    it "reports a parent tree MCR entry whose parent is not in the structure tree" do
      orphan = @doc.add({Type: :StructElem, S: :Span, P: @document_elem, Pg: @page})
      arr = @root[:ParentTree].find_entry(0)
      arr[1] = {Type: :MCR, P: orphan, MCID: 1}
      @doc.structure.root_element
      problem = @doc.structure.problems.find {|p| p.code == :orphaned_parent_entry }
      refute_nil(problem)
    end

    it "matches a direct structure element reachable through a direct parent tree entry" do
      direct = @doc.wrap({Type: :StructElem, S: :H1, P: @document_elem, Pg: @page, K: 1})
      @document_elem[:K][0] = direct
      arr = @root[:ParentTree].find_entry(0)
      arr[1] = direct
      element = @doc.structure.root_element
      assert_equal(:H1, element.children[0].role)
      assert(@doc.structure.valid?, @doc.structure.problems.map(&:to_s))
    end

    it "uses the /StmOwn object to look up the parent tree entry" do
      owner = @doc.add({Type: :Annot, Subtype: :Stamp, Rect: [0, 0, 1, 1], StructParent: 8,
                        P: @page})
      @root[:ParentTree].add_entry(8, @h1)
      @h1[:K] = [{Type: :MCR, Pg: @page, Stm: @form, StmOwn: owner, MCID: 0}]
      @doc.structure.root_element
      problem = @doc.structure.problems.find {|p| p.code == :parent_tree_mismatch }
      assert_nil(problem, @doc.structure.problems.map(&:to_s))
    end

    it "considers the parent field of an OBJR referenced widget" do
      field = @doc.add({FT: :Tx, StructParent: 9})
      widget = @doc.add({Type: :Annot, Subtype: :Widget, Rect: [0, 0, 1, 1], Parent: field})
      objr = @doc.add({Type: :OBJR, Pg: @page, Obj: widget})
      @root[:ParentTree].add_entry(9, objr)
      link = @doc.add({Type: :StructElem, S: :Link, P: @document_elem, Pg: @page, K: objr})
      @document_elem[:K] << link
      @doc.structure.root_element
      assert(@doc.structure.valid?, @doc.structure.problems.map(&:to_s))
    end

    it "handles an OBJR with multiple possible parent tree entries" do
      field = @doc.add({FT: :Tx, StructParent: 10})
      widget = @doc.add({Type: :Annot, Subtype: :Widget, Rect: [0, 0, 1, 1],
                         StructParent: 9, Parent: field})
      objr = @doc.add({Type: :OBJR, Pg: @page, Obj: widget})
      @root[:ParentTree].add_entry(9, objr)
      @root[:ParentTree].add_entry(10, objr)
      link = @doc.add({Type: :StructElem, S: :Link, P: @document_elem, Pg: @page, K: objr})
      @document_elem[:K] << link
      @doc.structure.root_element
      assert(@doc.structure.valid?, @doc.structure.problems.map(&:to_s))
    end
  end

  describe "read-only access" do
    it "does not modify a re-read PDF when reading the structure" do
      doc = reread(build_document)
      before = serialized(doc)
      structure = doc.structure
      structure.struct_tree_root
      root = structure.root_element
      root.children.each do |child|
        child.lang; child.alt; child.role; child.children; child.pages; child.content_items
      end
      root.each_descendant.to_a
      after = serialized(doc)
      assert_equal(before, after)
    end

    it "does not modify the document even when problems are found" do
      doc = reread(build_document)
      doc.catalog[:StructTreeRoot][:RoleMap] = {H1: :Foo, Foo: :H1} # circular mapping
      before = serialized(doc)
      doc.structure.root_element
      assert_equal(before, serialized(doc))
    end
  end

end
