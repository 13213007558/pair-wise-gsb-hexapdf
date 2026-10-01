# -*- encoding: utf-8 -*-

require 'test_helper'
require 'hexapdf/document'
require 'hexapdf/task/read_logical_structure'

describe HexaPDF::Task::ReadLogicalStructure do
  # Creates a tagged PDF with one page and a canvas where drawing is done in the opposite order
  # of reading. The block is used to set up the structure tree. The returned document is the
  # re-parsed (written and read back in) document, so all objects are indirect references.
  def create_tagged_pdf(validate: true)
    doc = HexaPDF::Document.new
    page = doc.pages.add
    canvas = page.canvas
    canvas.font("Helvetica", size: 12)

    form = doc.add({Type: :XObject, Subtype: :Form, BBox: [0, 0, 300, 60],
                    StructParents: 1})
    form_canvas = form.canvas
    form_canvas.font("Helvetica", size: 12)
    form_canvas.marked_content_sequence(:P, property_list: {MCID: 0}) do
      form_canvas.text("form", at: [5, 30])
    end

    # Drawing order is deliberately different from reading order: the heading text "title" is
    # drawn first (at the bottom), the paragraph text "body" afterwards (at the top).
    canvas.marked_content_sequence(:H1, property_list: {MCID: 0}) do
      canvas.text("title", at: [10, 100])
    end
    canvas.marked_content_sequence(:P, property_list: {MCID: 1}) do
      canvas.text("body", at: [10, 300])
      canvas.xobject(form, at: [10, 400])
    end

    root = doc.add({Type: :StructTreeRoot}, type: :StructTreeRoot)
    doc.catalog[:StructTreeRoot] = root
    doc.catalog[:MarkInfo] = {Marked: true}

    result = yield(doc, page, form, canvas, root)

    io = StringIO.new
    doc.write(io, validate: validate)
    read_doc = HexaPDF::Document.new(io: StringIO.new(io.string))
    [read_doc, result]
  end

  def struct_elem(doc, root, page, role:, k: nil, **attrs)
    value = {Type: :StructElem, S: role, P: root, Pg: page}
    value[:K] = k unless k.nil?
    value.update(attrs)
    doc.add(value, type: :StructElem)
  end

  def parent_tree(doc, nums)
    doc.add({Nums: nums}, type: HexaPDF::NumberTreeNode)
  end

  def read(doc)
    doc.task(:read_logical_structure)
  end

  it "returns an empty result for documents without a structure tree" do
    doc = HexaPDF::Document.new
    result = read(doc)
    assert(result.valid?)
    assert_equal([], result.elements)
    assert_equal([], result.diagnostics)
    assert_equal({}, result.elements_by_position)
  end

  it "reads roles, language, alternative/expansion/actual text and title" do
    doc, = create_tagged_pdf do |d, page, _form, _canvas, root|
      root[:RoleMap] = {MyH: :H1}
      h1 = struct_elem(d, root, page, role: :MyH, k: 0, Lang: 'en', Alt: 'alt',
                       E: 'expansion', T: 'heading title')
      actual = struct_elem(d, root, page, role: :P, k: 1, ActualText: 'ACTUAL')
      root[:K] = [h1, actual]
      root[:ParentTree] = parent_tree(d, [0, [h1, actual], 1, []])
      page[:StructParents] = 0
    end

    result = read(doc)
    assert(result.valid?, result.diagnostics.map(&:to_s).inspect)

    h1, actual = result.elements
    assert_equal(:H1, h1.role)
    assert_equal(:MyH, h1.original_role)
    assert_equal('en', h1.language)
    assert_equal('alt', h1.alternative_text)
    assert_equal('expansion', h1.expansion_text)
    assert_equal('heading title', h1.title)
    assert_nil(h1.actual_text)

    assert_equal(:P, actual.role)
    assert_equal('ACTUAL', actual.text) # ActualText overrides the page text
  end

  it "resolves roles through RoleMap chains and reports cyclic mappings" do
    doc, = create_tagged_pdf(validate: false) do |d, page, _form, _canvas, root|
      root[:RoleMap] = {A: :B, B: :H2, Cyc: :Back, Back: :Cyc}
      chained = struct_elem(d, root, page, role: :A, k: 0)
      cyc = struct_elem(d, root, page, role: :Cyc, k: 1)
      root[:K] = [chained, cyc]
      root[:ParentTree] = parent_tree(d, [0, [chained, cyc], 1, []])
      page[:StructParents] = 0
    end

    result = read(doc)
    assert_equal(:H2, result.elements[0].role)
    assert_equal(:Back, result.elements[1].role) # mapping stops at the cycle
    diag = result.diagnostics.find {|d| d.message =~ /Cyclic RoleMap/ }
    refute_nil(diag)
    assert_equal(:error, diag.severity)
    assert_equal(result.elements[1].oid, diag.oid)
  end

  it "returns content in structure-tree order, not in drawing order" do
    doc, = create_tagged_pdf do |d, page, form, _canvas, root|
      h1 = struct_elem(d, root, page, role: :H1, k: 0)
      para = struct_elem(d, root, page, role: :P,
                         k: [1, {Type: :MCR, Pg: page, Stm: form, MCID: 0}])
      root[:K] = [para, h1] # paragraph first in reading order though drawn second
      form_mcr = {Type: :MCR, Pg: page, Stm: form, MCID: 0}
      root[:ParentTree] = parent_tree(d, [0, [para, h1], 1, [form_mcr]])
      page[:StructParents] = 0
    end

    result = read(doc)
    assert(result.valid?, result.diagnostics.map(&:to_s).inspect)

    para, h1 = result.elements
    assert_equal("bodyform", para.text)
    assert_equal("title", h1.text)
    assert_equal("bodyformtitle", result.elements.map(&:text).join)

    # The structure-tree children are a page MCID (integer), a Form XObject MCR and the form's
    # MarkedContent exposes the associated page and stream.
    page_mark, form_mark = para.children
    assert_equal(1, page_mark.mcid)
    assert_nil(page_mark.stream)
    assert_equal("body", page_mark.text)
    assert_equal(0, form_mark.mcid)
    assert_equal(form_mark.page.oid, page_mark.page.oid)
    refute_nil(form_mark.stream)
    assert_equal("form", form_mark.text)

    assert_equal([page_mark.page], h1.pages | para.pages)
  end

  it "supports MCR dictionaries and OBJR dictionaries as children" do
    doc, result_data = create_tagged_pdf do |d, page, form, _canvas, root|
      annotation = d.add({Type: :Annot, Subtype: :Link, Rect: [0, 0, 20, 20]})
      page[:Annots] = [annotation]
      mcr = {Type: :MCR, Pg: page, MCID: 0}
      objr = d.add({Type: :OBJR, Pg: page, Obj: annotation}, type: :ObjectReference)
      elem = struct_elem(d, root, page, role: :P, k: [mcr, objr])
      root[:K] = [elem]
      root[:ParentTree] = parent_tree(d, [0, [elem, objr], 1, []])
      page[:StructParents] = 0
      [annotation]
    end

    result = read(doc)
    assert(result.valid?, result.diagnostics.map(&:to_s).inspect)
    elem = result.elements.first
    mcr_content, objr_content = elem.children
    assert_equal(0, mcr_content.mcid)
    assert_equal(:OBJR, objr_content.object[:Type])
    assert_equal(result_data.first.oid, objr_content.referenced_object.oid)
    refute_nil(objr_content.page)
  end

  it "handles nested structure elements and marks" do
    doc, = create_tagged_pdf do |d, page, form, _canvas, root|
      h1 = struct_elem(d, root, page, role: :H1, k: 0)
      form_mcr = {Type: :MCR, Pg: page, Stm: form, MCID: 0}
      nested = struct_elem(d, root, page, role: :Span, k: [1, form_mcr])
      outer = struct_elem(d, root, page, role: :Div)
      outer[:K] = [nested]
      root[:K] = [outer, h1]
      root[:ParentTree] = parent_tree(d, [0, [nested, h1], 1, [form_mcr]])
      page[:StructParents] = 0
    end

    result = read(doc)
    outer = result.elements.first
    assert_equal(:Div, outer.role)
    nested = outer.children.first
    assert_kind_of(HexaPDF::Task::ReadLogicalStructure::Element, nested)
    assert_equal(:Span, nested.role)
    assert_equal("bodyform", nested.text)
    assert_equal("bodyform", outer.text)

    descendants = outer.each_descendant.map(&:role)
    assert_equal([:Div, :Span], descendants)
    assert_equal("bodyformtitle", result.elements.map(&:text).join)
  end

  it "attributes text of nested marked-content sequences to the innermost MCID" do
    doc = HexaPDF::Document.new
    page = doc.pages.add
    canvas = page.canvas
    canvas.font("Helvetica", size: 12)
    canvas.marked_content_sequence(:Div, property_list: {MCID: 0}) do
      canvas.marked_content_sequence(:P, property_list: {MCID: 1}) do
        canvas.text("inner", at: [10, 200])
      end
    end
    root = doc.add({Type: :StructTreeRoot}, type: :StructTreeRoot)
    doc.catalog[:StructTreeRoot] = root
    outer = struct_elem(doc, root, page, role: :Div, k: 0)
    inner = struct_elem(doc, root, page, role: :P, k: 1)
    root[:K] = [outer, inner]
    root[:ParentTree] = parent_tree(doc, [0, [outer, inner]])
    page[:StructParents] = 0
    io = StringIO.new
    doc.write(io)
    read_doc = HexaPDF::Document.new(io: StringIO.new(io.string))

    result = read(read_doc)
    assert(result.valid?, result.diagnostics.map(&:to_s).inspect)
    assert_equal("", result.elements[0].text)
    assert_equal("inner", result.elements[1].text)
  end

  it "reports a content ownership conflict when the same MCID is referenced twice" do
    doc, = create_tagged_pdf(validate: false) do |d, page, _form, _canvas, root|
      first = struct_elem(d, root, page, role: :P, k: 0)
      second = struct_elem(d, root, page, role: :P, k: 0)
      also_same = struct_elem(d, root, page, role: :P, k: [1, 1])
      root[:K] = [first, second, also_same]
      root[:ParentTree] = parent_tree(d, [0, [first, second, also_same], 1, []])
      page[:StructParents] = 0
    end

    result = read(doc)
    assert_equal(2, result.diagnostics.count {|d| d.message =~ /more than one structure element/ })
    # All elements are still readable
    assert_equal(["title", "title", "bodybody"], result.elements.map(&:text))
  end

  it "reports references to pages missing from the page tree and keeps the rest" do
    doc, = create_tagged_pdf(validate: false) do |d, page, _form, _canvas, root|
      ghost = d.add({Type: :Page, MediaBox: [0, 0, 100, 100]}) # not added to the page tree
      valid = struct_elem(d, root, page, role: :H1, k: 0)
      broken = struct_elem(d, root, ghost, role: :P, k: 0)
      root[:K] = [valid, broken]
      root[:ParentTree] = parent_tree(d, [0, [valid], 1, []])
      page[:StructParents] = 0
    end

    result = read(doc)
    diag = result.diagnostics.find {|d| d.message =~ /not part of the page tree/ }
    refute_nil(diag)
    assert_equal(:error, diag.severity)
    assert_equal("title", result.elements[0].text)
    assert_equal([], result.elements[1].children)
  end

  it "reports MCIDs that cannot be found on the page or in a Form XObject" do
    doc, = create_tagged_pdf(validate: false) do |d, page, form, _canvas, root|
      no_page_mcid = struct_elem(d, root, page, role: :P, k: 9)
      no_form_mcid = struct_elem(d, root, page, role: :P,
                                 k: [{Type: :MCR, Pg: page, Stm: form, MCID: 7}])
      root[:K] = [no_page_mcid, no_form_mcid]
      root[:ParentTree] = parent_tree(d, [0, [], 1, []])
      page[:StructParents] = 0
    end

    result = read(doc)
    messages = result.diagnostics.map(&:message)
    assert(messages.any? {|m| m =~ /MCID 9 not found/ })
    assert(messages.any? {|m| m =~ /MCID 7 not found/ })
    assert(result.diagnostics.all? {|d| d.severity == :error })
  end

  it "reports missing pages and invalid MCR data with object positions" do
    doc, = create_tagged_pdf(validate: false) do |d, page, _form, _canvas, root|
      no_pg = struct_elem(d, root, nil, role: :P, k: 0)
      no_pg.delete(:Pg)
      bad_mcid = struct_elem(d, root, page, role: :P,
                             k: [{Type: :MCR, Pg: page}]) # MCID missing
      root[:K] = [no_pg, bad_mcid]
      root[:ParentTree] = parent_tree(d, [0, [], 1, []])
      page[:StructParents] = 0
    end

    result = read(doc)
    messages = result.diagnostics.map(&:message)
    assert(messages.any? {|m| m =~ /No page/ })
    assert(messages.any? {|m| m =~ /no valid MCID/ })
    assert(result.diagnostics.all? {|d| d.oid && d.gen == 0 })
    assert(result.diagnostics.all? {|d| d.position =~ /\A\d+,0\z/ })
  end

  it "reports cycles in the structure tree but retains readable parts" do
    doc, = create_tagged_pdf(validate: false) do |d, page, _form, _canvas, root|
      x = struct_elem(d, root, page, role: :Div)
      y = struct_elem(d, x, page, role: :P)
      x[:K] = [y]
      y[:K] = [x, 0] # y points back to its ancestor x and also to valid MCID 0
      root[:K] = [x]
      root[:ParentTree] = parent_tree(d, [0, [y], 1, []])
      page[:StructParents] = 0
    end

    result = read(doc)
    diag = result.diagnostics.find {|d| d.message =~ /cycle/ }
    refute_nil(diag)
    x = result.elements.first
    assert_equal(:Div, x.role)
    assert_equal("title", x.text) # valid content below the cycle is retained
  end

  it "warns when the ParentTree does not refer back to the structure element" do
    doc, other = create_tagged_pdf(validate: false) do |d, page, _form, _canvas, root|
      other = struct_elem(d, root, page, role: :P, k: 1)
      h1 = struct_elem(d, root, page, role: :H1, k: 0)
      root[:K] = [h1, other]
      # Wrong: the parent tree says MCID 0 belongs to +other+, not to +h1+
      root[:ParentTree] = parent_tree(d, [0, [other], 1, []])
      page[:StructParents] = 0
      [other]
    end

    result = read(doc)
    diag = result.diagnostics.find {|d| d.message =~ /does not refer back/ }
    refute_nil(diag)
    assert_equal(:warning, diag.severity)
    assert(result.valid?) # warnings don't invalidate the result
    assert(result.diagnostics.all?(&:warning?))
    assert_equal([], result.errors)
  end

  it "warns when an OBJR is not listed in the page's parent tree" do
    doc, _annotation = create_tagged_pdf(validate: false) do |d, page, _form, _canvas, root|
      annotation = d.add({Type: :Annot, Subtype: :Link, Rect: [0, 0, 20, 20]})
      page[:Annots] = [annotation]
      objr = d.add({Type: :OBJR, Pg: page, Obj: annotation}, type: :ObjectReference)
      elem = struct_elem(d, root, page, role: :P, k: [0, objr])
      root[:K] = [elem]
      root[:ParentTree] = parent_tree(d, [0, [elem], 1, []]) # OBJR missing
      page[:StructParents] = 0
      [annotation]
    end

    result = read(doc)
    assert(result.diagnostics.any? {|d| d.message =~ /does not contain the OBJR/ })
  end

  it "reports OBJR dictionaries referencing missing objects" do
    doc, = create_tagged_pdf(validate: false) do |d, page, _form, _canvas, root|
      objr = d.add({Type: :OBJR, Pg: page, Obj: HexaPDF::Reference.new(999, 0)},
                   type: :ObjectReference)
      elem = struct_elem(d, root, page, role: :P, k: [objr])
      root[:K] = [elem]
      root[:ParentTree] = parent_tree(d, [0, [elem, objr], 1, []])
      page[:StructParents] = 0
    end

    result = read(doc)
    diag = result.diagnostics.find {|d| d.message =~ /OBJR references a missing object/ }
    refute_nil(diag)
    objr_content = result.elements.first.children.first
    assert_nil(objr_content.referenced_object)
  end

  it "maps elements by object position" do
    doc, = create_tagged_pdf do |d, page, _form, _canvas, root|
      h1 = struct_elem(d, root, page, role: :H1, k: 0)
      root[:K] = [h1]
      root[:ParentTree] = parent_tree(d, [0, [h1], 1, []])
      page[:StructParents] = 0
    end

    result = read(doc)
    h1 = result.elements.first
    assert_equal(h1, result.elements_by_position[h1.position])
  end

  it "handles content spread over multiple pages" do
    doc = HexaPDF::Document.new
    pages = 2.times.map { doc.pages.add }
    pages.each_with_index do |page, index|
      canvas = page.canvas
      canvas.font("Helvetica", size: 12)
      canvas.marked_content_sequence(:P, property_list: {MCID: 0}) do
        canvas.text("page#{index}", at: [10, 200])
      end
    end
    root = doc.add({Type: :StructTreeRoot}, type: :StructTreeRoot)
    doc.catalog[:StructTreeRoot] = root
    elems = pages.map {|page| struct_elem(doc, root, page, role: :P, k: 0) }
    root[:K] = elems
    root[:ParentTree] = parent_tree(doc, [0, [elems[0]], 1, [elems[1]]])
    pages[0][:StructParents] = 0
    pages[1][:StructParents] = 1
    io = StringIO.new
    doc.write(io)
    read_doc = HexaPDF::Document.new(io: StringIO.new(io.string))

    result = read(read_doc)
    assert(result.valid?, result.diagnostics.map(&:to_s).inspect)
    assert_equal(%w[page0 page1], result.elements.map(&:text))
    assert_equal([0, 1], result.elements.map {|e| e.pages.first.index })
    assert_equal(2, result.elements.flat_map(&:pages).uniq.length)
  end

  it "does not modify the document" do
    doc, = create_tagged_pdf do |d, page, form, _canvas, root|
      h1 = struct_elem(d, root, page, role: :H1, k: 0)
      para = struct_elem(d, root, page, role: :P,
                         k: [1, {Type: :MCR, Pg: page, Stm: form, MCID: 0}])
      root[:K] = [para, h1]
      form_mcr = {Type: :MCR, Pg: page, Stm: form, MCID: 0}
      root[:ParentTree] = parent_tree(d, [0, [para, h1], 1, [form_mcr]])
      page[:StructParents] = 0
    end

    before = doc.write_to_string(update_fields: false, validate: false)
    read(doc)
    after = doc.write_to_string(update_fields: false, validate: false)
    assert_equal(before, after)
  end

  it "reports a structure element referenced more than once" do
    doc, = create_tagged_pdf(validate: false) do |d, page, _form, _canvas, root|
      shared = struct_elem(d, root, page, role: :P, k: 0)
      first = struct_elem(d, root, page, role: :Div)
      second = struct_elem(d, root, page, role: :Div)
      first[:K] = [shared]
      second[:K] = [shared] # same element used twice -> not a tree
      root[:K] = [first, second]
      root[:ParentTree] = parent_tree(d, [0, [shared], 1, []])
      page[:StructParents] = 0
    end

    result = read(doc)
    diag = result.diagnostics.find {|d| d.message =~ /referenced more than once/ }
    refute_nil(diag)
    # The element is still returned at its first occurrence
    assert_equal("title", result.elements[0].children.first.text)
    assert_equal("title", result.elements[1].children.first.text)
  end

  it "reports structure elements missing their role" do
    doc, = create_tagged_pdf(validate: false) do |d, page, _form, _canvas, root|
      bad = d.add({Type: :StructElem, P: root, Pg: page, K: 0}, type: :StructElem)
      good = struct_elem(d, root, page, role: :P, k: 1)
      root[:K] = [bad, good]
      root[:ParentTree] = parent_tree(d, [0, [good], 1, []])
      page[:StructParents] = 0
    end

    result = read(doc)
    refute_nil(result.diagnostics.find {|d| d.message =~ /missing its role/ })
    assert_equal(1, result.elements.length)
    assert_equal("body", result.elements[0].text)
  end

  it "reports invalid content items" do
    doc, = create_tagged_pdf(validate: false) do |d, page, _form, _canvas, root|
      elem = d.add({Type: :StructElem, S: :P, P: root, Pg: page,
                    K: ["not valid", {Foo: :Bar}]}, type: :StructElem)
      root[:K] = [elem]
      root[:ParentTree] = parent_tree(d, [0, [], 1, []])
      page[:StructParents] = 0
    end

    result = read(doc)
    messages = result.diagnostics.map(&:message)
    assert(messages.any? {|m| m =~ /Invalid structure element child of type String/ })
    assert(messages.any? {|m| m =~ /Unknown structure element child dictionary/ })
  end

  it "resolves MCIDs from property lists referenced through the /Properties resources" do
    doc = HexaPDF::Document.new
    page = doc.pages.add
    canvas = page.canvas
    canvas.font("Helvetica", size: 12) # registers the font dictionary as resource /F1
    properties = doc.add({MCID: 0})
    page.resources[:Properties] = {MP1: properties}
    page.contents = "/P /MP1 BDC BT /F1 12 Tf 10 200 Td (named) Tj ET EMC"
    root = doc.add({Type: :StructTreeRoot}, type: :StructTreeRoot)
    doc.catalog[:StructTreeRoot] = root
    elem = struct_elem(doc, root, page, role: :P, k: 0)
    root[:K] = [elem]
    root[:ParentTree] = parent_tree(doc, [0, [elem]])
    page[:StructParents] = 0
    io = StringIO.new
    doc.write(io)
    read_doc = HexaPDF::Document.new(io: StringIO.new(io.string))

    result = read(read_doc)
    assert(result.valid?, result.diagnostics.map(&:to_s).inspect)
    assert_equal("named", result.elements.first.text)
  end

  it "returns an error diagnostic when the StructTreeRoot is not a dictionary" do
    doc = HexaPDF::Document.new
    doc.pages.add
    doc.catalog[:StructTreeRoot] = 42
    result = read(doc)
    refute(result.valid?)
    assert(result.diagnostics.any? {|d| d.message =~ /StructTreeRoot is not a dictionary/ })
  end

  it "warns when a page has no /StructParents although a ParentTree exists" do
    doc, = create_tagged_pdf(validate: false) do |d, page, _form, _canvas, root|
      elem = struct_elem(d, root, page, role: :P, k: 0)
      root[:K] = [elem]
      root[:ParentTree] = parent_tree(d, [5, [elem]])
      # page /StructParents intentionally left unset
    end

    result = read(doc)
    assert(result.diagnostics.any? {|d| d.message =~ /no \/StructParents entry/ })
  end
end
