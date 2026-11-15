-- Tests for page anchoring: on a paged document, ink follows its page when
-- the view zooms, pans or scrolls. The geometry is tested on its own; the
-- Pencil methods load the real main.lua with KOReader modules stubbed out,
-- like save_spec.

package.path = "pencil.koplugin/?.lua;" .. package.path

local Geometry = require("lib/geometry")

local function permissive()
    local stub = {}
    return setmetatable(stub, {
        __index = function() return permissive() end,
        __call = function() return permissive() end,
    })
end

local function loadPencil()
    local stubbed = {
        "ffi/blitbuffer", "ui/widget/container/centercontainer", "datastorage",
        "device", "dispatcher", "ui/widget/container/framecontainer", "ui/geometry",
        "ui/gesturerange", "ui/widget/horizontalgroup", "ui/widget/horizontalspan",
        "ui/widget/verticalgroup", "ui/widget/verticalspan", "ui/size",
        "ui/widget/infomessage", "ui/widget/container/widgetcontainer",
        "ui/time", "ffi/util", "ui/uimanager", "libs/libkoreader-lfs", "util", "dump",
    }
    for _, name in ipairs(stubbed) do
        package.loaded[name] = permissive()
    end
    package.loaded["ui/widget/container/inputcontainer"] = {
        extend = function(_, class) return class end,
    }
    package.loaded["logger"] = {
        dbg = function() end, info = function() end,
        warn = function() end, err = function() end,
    }
    package.loaded["gettext"] = setmetatable({}, { __call = function(_, s) return s end })
    return dofile("pencil.koplugin/main.lua")
end

local Pencil = loadPencil()

-- A single-page view: page 3 at zoom 2, panned so the page's (100, 50)
-- shows at the screen's top-left corner.
local function singleView(zoom, vx, vy)
    return {
        page_scroll = false,
        state = { page = 3, zoom = zoom or 2, offset = { x = 0, y = 0 }, rotation = 0 },
        visible_area = { x = vx or 200, y = vy or 100, w = 1264, h = 1680 },
    }
end

-- Continuous mode: page 4 (its lower part) above page 5, with a 20 px gap.
local function scrollView(shift)
    shift = shift or 0
    return {
        page_scroll = true,
        page_gap = { height = 20 },
        page_states = {
            { page = 4, zoom = 1.5, rotation = 0, offset = { x = 10, y = 0 },
              visible_area = { x = 0, y = 900 + shift, w = 1244, h = 600 - shift } },
            { page = 5, zoom = 1.5, rotation = 0, offset = { x = 10, y = 0 },
              visible_area = { x = 0, y = 0, w = 1244, h = 1060 + shift } },
        },
    }
end

local function makePencil(view, strokes)
    local p = setmetatable({
        ui = { paging = true },
        view = view,
        strokes = strokes or {},
        page_strokes = {},
        annotation_groups = {},
    }, { __index = Pencil })
    p:rebuildPageIndex()
    return p
end

describe("Geometry page placements", function()
    it("places the single page with the offset and zoom ReaderView uses", function()
        local pls = Geometry.pagePlacements(singleView())
        assert.equals(1, #pls)
        assert.equals(3, pls[1].page)
        assert.equals(-200, pls[1].ox)
        assert.equals(-100, pls[1].oy)
        -- ReaderView:getSinglePagePosition: (visible_area + screen - offset) / zoom
        local page = Geometry.screenToPage({ { x = 0, y = 0 }, { x = 64, y = 10 } }, pls[1])
        assert.same({ { x = 100, y = 50 }, { x = 132, y = 55 } }, page)
    end)

    it("stacks continuous pages with the gap, like getScrollPagePosition", function()
        local pls = Geometry.pagePlacements(scrollView())
        assert.equals(2, #pls)
        assert.equals(0, pls[1].top)
        assert.equals(600, pls[1].bottom)
        assert.equals(620, pls[2].top)
        -- Screen y 700 is 80 px into page 5: page y = 80 / 1.5
        local pl = Geometry.placementAt(pls, 700)
        assert.equals(5, pl.page)
        local p = Geometry.screenToPage({ { x = 160, y = 700 } }, pl)[1]
        assert.is_true(math.abs(p.x - 100) < 1e-9)
        assert.is_true(math.abs(p.y - 80 / 1.5) < 1e-9)
        assert.equals(4, Geometry.placementAt(pls, 599).page)
        assert.equals(5, Geometry.placementAt(pls, 5000).page)
    end)

    it("maps page points back to the same screen pixels", function()
        for _, view in ipairs({ singleView(), singleView(3.25, 17, 940), scrollView() }) do
            for _, pl in ipairs(Geometry.pagePlacements(view)) do
                local screen = { { x = 13, y = 400 }, { x = 640, y = 999 } }
                assert.same(screen, Geometry.pageToScreen(Geometry.screenToPage(screen, pl), pl))
            end
        end
    end)

    it("packs page points with two decimals", function()
        local packed = Geometry.packPagePoints({ { x = 1 / 3, y = 2 }, { x = -0.004, y = 10.5 } })
        assert.equals("0.33 2 0 10.5", packed)
        assert.same({ { x = 0.33, y = 2 }, { x = 0, y = 10.5 } }, Geometry.unpackPoints(packed))
    end)
end)

describe("Pencil page anchoring", function()
    it("moves the ink with the page when the view zooms and pans", function()
        local stroke = { page = 3, tool = "pen", points = { { x = 0, y = 0 }, { x = 64, y = 10 } } }
        local pencil = makePencil(singleView(), {})
        assert.is_true(pencil:anchorStroke(stroke))
        table.insert(pencil.strokes, stroke)
        pencil:rebuildPageIndex()

        -- Zoom out to 1 and pan back to the page's corner.
        pencil.view = singleView(1, 0, 0)
        pencil:refreshAnchoredStrokes(pencil:pagePlacements())
        assert.same({ { x = 100, y = 50 }, { x = 132, y = 55 } }, stroke.points)
    end)

    it("gives a stroke the page under it in continuous mode, and scrolls it", function()
        local view = scrollView()
        local stroke = { page = 4, tool = "pen", points = { { x = 160, y = 700 }, { x = 190, y = 760 } } }
        local pencil = makePencil(view, {})
        pencil:anchorStroke(stroke)
        assert.equals(5, stroke.page)
        table.insert(pencil.strokes, stroke)
        pencil:rebuildPageIndex()

        -- Scroll 300 px: page 4 shrinks on screen, so page 5 rises by 300.
        pencil.view = scrollView(300)
        pencil:refreshAnchoredStrokes(pencil:pagePlacements())
        assert.same({ { x = 160, y = 400 }, { x = 190, y = 460 } }, stroke.points)
    end)

    it("leaves a page shown with another rotation, and old ink, alone", function()
        local rotated = { page = 3, tool = "pen", points = { { x = 5, y = 5 } },
                          page_p = { { x = 1, y = 1 } }, page_rot = 90 }
        local old = { page = 3, tool = "pen", points = { { x = 7, y = 7 } } }
        local pencil = makePencil(singleView(), { rotated, old })
        pencil:refreshAnchoredStrokes(pencil:pagePlacements())
        assert.same({ { x = 5, y = 5 } }, rotated.points)
        assert.same({ { x = 7, y = 7 } }, old.points)
        assert.is_true(pencil:hasUnanchoredVisibleStrokes())
        -- (saveStrokes is a no-op stub here)
        pencil.saveStrokes = function() end
        assert.equals(1, pencil:anchorVisibleStrokes())
        assert.is_false(pencil:hasUnanchoredVisibleStrokes())
    end)

    it("erases on the page under the eraser in continuous mode", function()
        local pencil = makePencil(scrollView(), {
            { page = 4, tool = "pen", points = { { x = 100, y = 100 } } },
            { page = 5, tool = "pen", points = { { x = 100, y = 700 } } },
        })
        pencil.tool_settings = { eraser = { width = 10 } }
        pencil.rebuildAnnotationGroups = function() end
        -- The current page is 4, but the eraser is over page 5.
        local deleted = pencil:eraseAtPoint(100, 700, 4)
        assert.equals(1, #deleted)
        assert.equals(5, deleted[1].page)
    end)

    it("does nothing on reflowable documents", function()
        local pencil = makePencil(singleView(), {})
        pencil.ui.paging = false
        local stroke = { page = 3, points = { { x = 1, y = 1 } } }
        assert.is_false(pencil:anchorStroke(stroke))
        assert.is_nil(stroke.page_p)
        assert.is_nil(pencil:pageAtScreen(1, 1))
    end)

    it("saves and loads the page points, and loads files without them", function()
        local pencil = makePencil(singleView(), {})
        pencil.tool_settings = { pen = { width = 3 } }
        pencil.available_colors = {}
        local stroke = { page = 3, tool = "pen", width = 3, points = { { x = 0, y = 0 }, { x = 64, y = 10 } } }
        pencil:anchorStroke(stroke)
        local saved = pencil:strokeToSaveable(stroke)
        assert.equals("100 50 132 55", saved.page_p)
        assert.equals(0, saved.page_rot)
        local back = pencil:strokeFromSaved(saved)
        assert.same({ { x = 100, y = 50 }, { x = 132, y = 55 } }, back.page_p)
        assert.equals(0, back.page_rot)

        local legacy = pencil:strokeFromSaved({ page = 3, tool = "pen", p = "1 2 3 4" })
        assert.is_nil(legacy.page_p)
        assert.same({ { x = 1, y = 2 }, { x = 3, y = 4 } }, legacy.points)
        assert.is_nil(pencil:strokeToSaveable(legacy).page_p)
    end)
end)
